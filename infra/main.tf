#---------------------------------------------------------------
# Providers
#---------------------------------------------------------------

provider "aws" {
  region = local.region
}

# Used for Karpenter Helm chart
provider "aws" {
  region = "us-east-1"
  alias  = "ecr_public_region"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 5
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

#---------------------------------------------------------------
# Data Sources
#---------------------------------------------------------------
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_availability_zones" "available" {}

# Used for Karpenter Helm chart
data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr_public_region
}

#---------------------------------------------------------------
# Locals
#---------------------------------------------------------------

locals {
  name   = var.name
  region = var.region

  vpc_cidr           = "10.12.0.0/16"
  secondary_vpc_cidr = "100.64.0.0/16"
  azs                = slice(data.aws_availability_zones.available.names, 0, 3)

  cluster_version = var.eks_cluster_version
  additional_iam_policies = [
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  ]

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/awslabs/data-on-eks"
  }
}

#---------------------------------------------------------------
# EKS Cluster
#---------------------------------------------------------------

#tfsec:ignore:aws-eks-enable-control-plane-logging
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = local.cluster_version
  #WARNING: Avoid using this option (cluster_endpoint_public_access = true) in preprod or prod accounts. This feature is designed for sandbox accounts, simplifying cluster deployment and testing.
  cluster_endpoint_public_access = true

  vpc_id = module.vpc.vpc_id
  # We only want to assign the 10.0.* range subnets to the data plane
  subnet_ids               = slice(module.vpc.private_subnets, 0, 3)
  control_plane_subnet_ids = module.vpc.private_subnets

  enable_cluster_creator_admin_permissions = true

  cluster_compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }
}

#---------------------------------------------------------------
# Operational Add-Ons using EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.19"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_kube_prometheus_stack = true

  helm_releases = {

    kuberay-operator = {
      namespace        = "kuberay-operator"
      create_namespace = true
      chart            = "kuberay-operator"
      chart_version    = "1.2.2"
      repository       = "https://ray-project.github.io/kuberay-helm/"
    }
  }
}


resource "kubectl_manifest" "karpenter_gpu_node_class" {
  yaml_body = <<-YAML
    apiVersion: eks.amazonaws.com/v1
    kind: NodeClass
    metadata:
      name: gpu
    spec:
      role: ${module.eks.node_iam_role_name}
      securityGroupSelectorTerms:
      - id: ${module.eks.cluster_primary_security_group_id} 
      subnetSelectorTerms:
      - tags:
          kubernetes.io/role/internal-elb: "1"
      ephemeralStorage:
        size: "150Gi"    # Range: 1-59000Gi or 1-64000G or 1-58Ti or 1-64T
        iops: 3000      # Range: 3000-16000
        throughput: 125 # Range: 125-1000
  YAML
}

resource "kubectl_manifest" "karpenter_gpu_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: gpu
    spec:
      disruption:
        consolidateAfter: 60m
        consolidationPolicy: WhenEmpty
      limits:
        cpu: 1k
        memory: 1000Gi
        nvidia.com/gpu: 50
      template:
        spec:
          nodeClassRef:
            group: eks.amazonaws.com
            name: default
            kind: NodeClass
          requirements:
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64"]
          - key: eks.amazonaws.com/instance-category
            operator: In
            values: ["g"]
          - key: eks.amazonaws.com/instance-generation
            operator: Gt
            values: ["4"]
          - key: "eks.amazonaws.com/instance-cpu"
            operator: In
            values: ["4", "8", "16"]
          - key: kubernetes.io/os
            operator: In
            values: ["linux"]
          - key: "topology.kubernetes.io/zone"
            operator: In
            values: ${jsonencode(local.azs)}
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand"]
          taints:
          - effect: NoSchedule
            key: ray.io/node-type
            value: worker
  YAML
}


resource "kubernetes_secret" "pyannote_auth_token" {
  metadata {
    name      = "hf-token"
    namespace = "default" # replace with your desired namespace
  }

  data = {
    token = var.pyannote_auth_token
  }

  type = "Opaque"

  depends_on = [module.eks.eks_cluster_id]
}

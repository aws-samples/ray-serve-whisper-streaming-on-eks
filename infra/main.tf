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

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
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
  version = "~> 19.15"

  cluster_name    = local.name
  cluster_version = local.cluster_version
  #WARNING: Avoid using this option (cluster_endpoint_public_access = true) in preprod or prod accounts. This feature is designed for sandbox accounts, simplifying cluster deployment and testing.
  cluster_endpoint_public_access = true

  vpc_id = module.vpc.vpc_id
  # We only want to assign the 10.0.* range subnets to the data plane
  subnet_ids               = slice(module.vpc.private_subnets, 0, 3)
  control_plane_subnet_ids = module.vpc.intra_subnets

  # Update aws-auth configmap with Karpenter node role so they
  # can join the cluster
  manage_aws_auth_configmap = true
  aws_auth_roles = [
    {
      rolearn  = module.eks_blueprints_addons.karpenter.node_iam_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups = [
        "system:bootstrappers",
        "system:nodes",
      ]
    },
  ]

  # EKS Addons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      # The VPC CNI addon should be deployed before compute to ensure
      # the addon is configured before data plane compute resources are created
      # See README for further details
      before_compute = true
      most_recent    = true # To ensure access to the latest settings provided
      preserve       = true
      configuration_values = jsonencode({
        env = {
          # Reference https://aws.github.io/aws-eks-best-practices/reliability/docs/networkmanagement/#cni-custom-networking
          AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
          ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"

          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
  }

  # This MNG will be used to host infrastructure add-ons for
  # logging, monitoring, ingress controllers, kuberay-operator,
  # etc.
  eks_managed_node_groups = {
    infra = {
      instance_types = ["m5.large"]
      min_size       = 1
      max_size       = 3
      desired_size   = 3
    }
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })
}

#---------------------------------------------------------------
# VPC-CNI Custom Networking ENIConfig
#---------------------------------------------------------------

resource "kubectl_manifest" "eni_config" {
  for_each = zipmap(local.azs, slice(module.vpc.private_subnets, 3, 6))

  yaml_body = yamlencode({
    apiVersion = "crd.k8s.amazonaws.com/v1alpha1"
    kind       = "ENIConfig"
    metadata = {
      name = each.key
    }
    spec = {
      securityGroups = [
        module.eks.cluster_primary_security_group_id,
        module.eks.node_security_group_id,
      ]
      subnet = each.value
    }
  })
}


#---------------------------------------------------------------
# Operational Add-Ons using EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  enable_karpenter = true
  karpenter = {
    chart_version       = "0.35.0"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
    max_history         = 10
  }
  karpenter_node = {
    create_instance_profile = true
    iam_role_additional_policies = [
      "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
      module.karpenter_policy.arn
    ]
  }

  helm_releases = {
    #---------------------------------------
    # NVIDIA Device Plugin Add-on
    #---------------------------------------
    nvidia-device-plugin = {
      description      = "A Helm chart for NVIDIA Device Plugin"
      namespace        = "nvidia-device-plugin"
      create_namespace = true
      chart            = "nvidia-device-plugin"
      chart_version    = "0.14.0"
      repository       = "https://nvidia.github.io/k8s-device-plugin"
      values           = [file("${path.module}/helm-values/nvidia-values.yaml")]
    }

    kuberay-operator = {
      namespace        = "kuberay-operator"
      create_namespace = true
      chart            = "kuberay-operator"
      chart_version    = "1.0.0"
      repository       = "https://ray-project.github.io/kuberay-helm/"
    }
  }
}


#---------------------------------------------------------------
# Karpenter Infrastructure
#---------------------------------------------------------------
# We have to augment default the karpenter node IAM policy with
# permissions we need for Ray Jobs to run until IRSA is added
# upstream in kuberay-operator. See issue
# https://github.com/ray-project/kuberay/issues/746
module "karpenter_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 5.20"

  name        = "KarpenterS3ReadOnlyPolicy"
  description = "IAM Policy to allow read from an S3 bucket for karpenter nodes"

  policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ListObjectsInBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = ["arn:aws:s3:::air-example-data-2"]
        },
        {
          Sid      = "AllObjectActions"
          Effect   = "Allow"
          Action   = "s3:Get*"
          Resource = ["arn:aws:s3:::air-example-data-2/*"]
        }
      ]
    }
  )
}

resource "kubectl_manifest" "karpenter_controller_security_group_policy" {
  yaml_body = <<-YAML
    apiVersion: vpcresources.k8s.aws/v1beta1
    kind: SecurityGroupPolicy
    metadata:
      name: karpenter-controller-sgp
      namespace: karpenter
    spec:
      podSelector:
        matchLabels:
          app.kubernetes.io/name: karpenter
          eks.amazonaws.com/fargate-profile: karpenter
      securityGroups:
        groupIds:
        - ${module.eks.cluster_primary_security_group_id}
        - ${module.eks.node_security_group_id}
  YAML
}

resource "kubectl_manifest" "karpenter_gpu_node_class" {
  yaml_body  = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: bottlerocket-nvidia
    spec:
      amiFamily: Bottlerocket
      role: ${module.eks_blueprints_addons.karpenter.node_iam_role_name}
      securityGroupSelectorTerms:
      - tags:
          Name: ${local.name}-node
      subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${local.name}
      tags:
        karpenter.sh/discovery: ${local.name}
  YAML
  depends_on = [module.eks_blueprints_addons]
}

resource "kubectl_manifest" "karpenter_gpu_node_pool" {
  yaml_body  = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: gpu
    spec:
      disruption:
        consolidateAfter: 600s
        consolidationPolicy: WhenEmpty
        expireAfter: 720h
      limits:
        cpu: 1k
        memory: 1000Gi
        nvidia.com/gpu: 50
      template:
        spec:
          nodeClassRef:
            name: bottlerocket-nvidia
          requirements:
          - key: kubernetes.io/arch
            operator: In
            values: ["amd64"]
          - key: karpenter.k8s.aws/instance-category
            operator: In
            values: ["g"]
          - key: karpenter.k8s.aws/instance-generation
            operator: Gt
            values: ["4"]
          - key: "karpenter.k8s.aws/instance-cpu"
            operator: In
            values: ["4", "8", "16"]
          - key: kubernetes.io/os
            operator: In
            values: ["linux"]
          - key: "karpenter.k8s.aws/instance-hypervisor"
            operator: In
            values: ["nitro"]
          - key: "topology.kubernetes.io/zone"
            operator: In
            values: ${jsonencode(local.azs)}
          - key: karpenter.sh/capacity-type
            operator: In
            values: ["on-demand", "spot"]
  YAML
  depends_on = [module.eks_blueprints_addons]
}


resource "kubectl_manifest" "karpenter_ec2_node_class" {
  yaml_body  = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: AL2023
      role: ${module.eks_blueprints_addons.karpenter.node_iam_role_name}
      securityGroupSelectorTerms:
      - tags:
          Name: ${local.name}-node
      subnetSelectorTerms:
      - tags:
          karpenter.sh/discovery: ${local.name}
      tags:
        karpenter.sh/discovery: ${local.name}
  YAML
  depends_on = [module.eks_blueprints_addons]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  yaml_body  = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: default
    spec:
      disruption:
        consolidationPolicy: WhenUnderutilized
        expireAfter: 72h0m0s
      limits:
        cpu: 1k
      template:
        spec:
          kubelet:
            maxPods: 110
          nodeClassRef:
            name: default
          requirements:
          - key: "karpenter.k8s.aws/instance-category"
            operator: In
            values: ["c", "m", "r"]
          - key: "karpenter.k8s.aws/instance-cpu"
            operator: In
            values: ["4", "8", "16"]
          - key: "karpenter.k8s.aws/instance-hypervisor"
            operator: In
            values: ["nitro"]
          - key: "topology.kubernetes.io/zone"
            operator: In
            values: ${jsonencode(local.azs)}
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["spot", "on-demand"]
  YAML
  depends_on = [module.eks_blueprints_addons]
}

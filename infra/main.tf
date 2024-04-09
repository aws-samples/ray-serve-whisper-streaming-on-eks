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

  # This MNG will be used to host infrastructure add-ons for
  # logging, monitoring, ingress controllers, kuberay-operator,
  # etc.
  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    disk_size      = 100
    instance_types = ["m5.large"]
    iam_role_additional_policies = {
      for k, v in local.additional_iam_policies : k => v
    }
  }
  eks_managed_node_groups = {
    infra = {
      min_size     = 1
      max_size     = 3
      desired_size = 3
    }
  }

  node_security_group_additional_rules = {
    ingress_elb = {
      description              = "Allow ELB access to worker nodes"
      protocol                 = "-1"
      from_port                = 0
      to_port                  = 0
      type                     = "ingress"
      source_security_group_id = module.elb_security_group.security_group_id
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

  eks_addons = {
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
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
  }

  enable_karpenter = true
  karpenter = {
    chart_version       = "0.35.0"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
    max_history         = 10
    set = [
      {
        name  = "settings.featureGates.drift"
        value = true
      },
      {
        name  = "settings.featureGates.spotToSpotConsolidation"
        value = true
      }
    ]
  }
  karpenter_node = {
    create_instance_profile = true
    iam_role_additional_policies = [
      "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
    ]
  }

  enable_aws_load_balancer_controller = true

  enable_kube_prometheus_stack = true
  kube_prometheus_stack = {
    values = [
      templatefile("${path.module}/helm-values/kube-prometheus-stack-values.yaml", {
        grafana_ingress_enabled = var.grafana_ingress_enabled
        ingressClassName        = var.ingress_class_name
        grafana_host            = var.grafana_host
        acm_cert_arn            = var.acm_cert_arn
        elb_security_group_id   = module.elb_security_group.security_group_id
      })
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
# Security Group for ELBs
#---------------------------------------------------------------
# We have to create dedicated Security Group for ELBs
module "elb_security_group" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~>5.1"

  name        = "elb-sg"
  description = "Security group for user-service with custom ports open within VPC, and PostgreSQL publicly open"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["https-443-tcp", "http-80-tcp"]
  egress_rules        = ["all-all"]
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
      name: default
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
      blockDeviceMappings:
        # Root device
        - deviceName: /dev/xvda
          ebs:
            volumeSize: 50Gi
            volumeType: gp3
            encrypted: true
        # Data device: Container resources such as images and logs
        - deviceName: /dev/xvdb
          ebs:
            volumeSize: 100Gi
            volumeType: gp3
            encrypted: true
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
            name: default
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
            values: ["on-demand"]
          taints:
          - effect: NoSchedule
            key: ray.io/node-type
            value: worker
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
        consolidateAfter: 600s
        consolidationPolicy: WhenEmpty
        expireAfter: 720h
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
            values: ["on-demand"]
  YAML
  depends_on = [module.eks_blueprints_addons]
}

module "ebs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"

  role_name_prefix = "${module.eks.cluster_name}-ebs-csi-driver-"

  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Disable default GP2 Storage Class
#---------------------------------------------------------------
resource "kubernetes_annotations" "disable_gp2" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  force = true

  depends_on = [module.eks.eks_cluster_id]
}
#---------------------------------------------------------------
# GP3 Storage Class - Set as default
#---------------------------------------------------------------
resource "kubernetes_storage_class" "default_gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    type = "gp3"
  }

  depends_on = [kubernetes_annotations.disable_gp2]
}


resource "kubernetes_secret" "pyannote_auth_token" {
  metadata {
    name      = "my-secret"
    namespace = "default" # replace with your desired namespace
  }

  data = {
    token = var.pyannote_auth_token
  }

  type = "Opaque"

  depends_on = [module.eks.eks_cluster_id]
}

variable "region" {
  description = "Region"
  type        = string
  default     = "ap-northeast-1"
}

variable "name" {
  description = "Name of the VPC, EKS Cluster and Ray cluster"
  default     = "kuberay-cluster"
  type        = string
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  default     = "1.30"
  type        = string
}

variable "pyannote_auth_token" {
  description = "The PYANNOTE_AUTH_TOKEN used for Ray worker, and it's essentially a HuggingFace auth token"
  type        = string
  sensitive   = true
}

variable "grafana_ingress_enabled" {
  description = "Enable Grafana Ingress or not"
  type        = bool
  default     = false
}

variable "grafana_host" {
  description = "Grafana Dashboard URL"
  default     = "grafana.domain.com"
  type        = string
}

variable "acm_cert_arn" {
  description = "Your ACM Cert ARN"
  default     = ""
  type        = string
}

variable "ingress_class_name" {
  description = "Ingress class name of your ingress controller"
  default     = "alb"
  type        = string
}

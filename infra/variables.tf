variable "region" {
  description = "Region"
  type        = string
  default     = "ap-northeast-1"
}

variable "name" {
  description = "Name of the VPC, EKS Cluster and Ray cluster"
  default     = "ray-cluster"
  type        = string
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  default     = "1.29"
  type        = string
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

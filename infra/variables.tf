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

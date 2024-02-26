#---------------------------------------------------------------
# Ray Cluster
#---------------------------------------------------------------

resource "helm_release" "ray_cluster" {
  namespace        = var.namespace
  create_namespace = true
  name             = var.ray_cluster_name
  repository       = "https://ray-project.github.io/kuberay-helm/"
  chart            = "ray-cluster"
  version          = var.ray_cluster_version

  values = var.helm_values

  depends_on = [
    # kubectl_manifest.karpenter_node_template,
    # kubectl_manifest.karpenter_provisioner
  ]
}

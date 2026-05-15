provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Os providers Kubernetes/Helm precisam autenticar contra o cluster EKS criado.
# Usamos a função `exec` chamando `aws eks get-token` em vez do data source
# (que avaliaria no plan e quebraria quando o cluster ainda não existe).
# ─────────────────────────────────────────────────────────────────────────────

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_certificate)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

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

provider "kubectl" {
  host = module.eks.cluster_endpoint
  # ALINHAMENTO AQUI: Use o mesmo nome de output que usou acima (cluster_ca_certificate)
  cluster_ca_certificate = module.eks.cluster_ca_certificate != null ? base64decode(module.eks.cluster_ca_certificate) : ""
  load_config_file       = false

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

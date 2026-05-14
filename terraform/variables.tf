variable "aws_region" {
  description = "Região AWS onde tudo será provisionado."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo usado em todos os recursos."
  type        = string
  default     = "togglemaster"
}

variable "cluster_name" {
  description = "Nome do cluster EKS."
  type        = string
  default     = "togglemaster-eks-prod"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "services" {
  description = "Lista de microsserviços (também usada para ECR, namespaces e Apps ArgoCD)."
  type        = list(string)
  default     = ["auth", "flag", "targeting", "evaluation", "analytics"]
}

variable "db_services" {
  description = "Serviços que precisam de RDS."
  type        = list(string)
  default     = ["auth", "flag", "targeting"]
}

variable "gitops_repo_url" {
  description = "URL HTTPS do repositório Git que o ArgoCD monitora."
  type        = string
  # Ex.: "https://github.com/SEU-USUARIO/togglemaster-tc3.git"
}

variable "gitops_revision" {
  type    = string
  default = "HEAD"
}

variable "expose_argocd_lb" {
  description = "Expor argocd-server via LoadBalancer? (false = port-forward, recomendado em Academy)."
  type        = bool
  default     = false
}

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


variable "infra_images" {
  description = "Imagens auxiliares (Fase 4) que precisam de ECR mas NÃO geram namespace nem Application ArgoCD via módulo de serviço."
  type        = list(string)
  default     = ["self-healing-webhook"]
}

variable "db_services" {
  description = "Serviços que precisam de RDS."
  type        = list(string)
  default     = ["auth", "flag", "targeting"]
}

variable "db_names" {
  description = "Nomes dos DBs."
  type        = list(string)
  default     = ["authdb", "flagdb", "targetingdb"]
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

variable "aws_access_key_id" {
  type        = string
  description = "AWS Access Key ID"
  sensitive   = true
}

variable "aws_secret_access_key" {
  type        = string
  description = "AWS Secret Access Key"
  sensitive   = true
}

variable "aws_session_token" {
  type        = string
  description = "AWS Session Token (Obrigatório em ambientes de Lab/AWS Academy)"
  default     = ""
  sensitive   = true
}

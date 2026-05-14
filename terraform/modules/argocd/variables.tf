variable "namespace" {
  type    = string
  default = "argocd"
}

variable "chart_version" {
  description = "Versão do chart Helm argo-cd."
  type        = string
  default     = "7.6.12"
}

variable "expose_lb" {
  description = "Se true, expõe o argocd-server via LoadBalancer (ELB). Em Academy, deixe false e use port-forward."
  type        = bool
  default     = false
}

variable "services" {
  description = "Lista de microsserviços que viram Application CRDs no ArgoCD."
  type        = list(string)
  default     = ["auth", "flag", "targeting", "evaluation", "analytics"]
}

variable "gitops_repo_url" {
  description = "URL do repositório Git que o ArgoCD vai monitorar."
  type        = string
}

variable "gitops_revision" {
  description = "Branch/tag/commit alvo dentro do repo (HEAD por padrão = sempre a main)."
  type        = string
  default     = "HEAD"
}

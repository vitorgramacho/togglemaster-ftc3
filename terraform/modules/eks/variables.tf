variable "cluster_name" {
  description = "Nome do cluster EKS."
  type        = string
}

variable "kubernetes_version" {
  description = "Versão do Kubernetes para o control plane."
  type        = string
  default     = "1.30"
}

variable "vpc_id" {
  description = "ID da VPC onde o cluster será provisionado."
  type        = string
}

variable "subnet_ids" {
  description = "IDs das subnets (privadas) onde o cluster e nodes vão rodar."
  type        = list(string)
}

variable "labrole_arn" {
  description = "ARN da LabRole (AWS Academy). Usada tanto para cluster quanto para node group."
  type        = string
}

variable "instance_types" {
  description = "Tipos de instância dos worker nodes."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "desired_size" {
  description = "Quantidade desejada de nodes. Padrão 3: a stack completa da Fase 4 (sistema + ArgoCD + observability + 5 microsserviços) não cabe confortavelmente em 2 nós t3.medium (17 pods/nó = 34 vagas), causando pods em 'Pending' (Too many pods)."
  type        = number
  default     = 3
}

variable "min_size" {
  description = "Mínimo de nodes."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Máximo de nodes."
  type        = number
  default     = 3
}

variable "tags" {
  description = "Tags comuns."
  type        = map(string)
  default     = {}
}

variable "project" {
  description = "Prefixo de nomenclatura do projeto."
  type        = string
}

variable "vpc_id" {
  description = "ID da VPC."
  type        = string
}

variable "vpc_cidr_block" {
  description = "CIDR block da VPC (usado para liberar tráfego no SG)."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets privadas para o DB Subnet Group."
  type        = list(string)
}

variable "databases" {
  description = "Lista lógica de bancos a serem criados (cada um vira uma instância RDS separada)."
  type        = list(string)
  default     = ["auth", "flag", "targeting"]
}

variable "master_username" {
  description = "Usuário master de cada instância RDS."
  type        = string
  default     = "masteruser"
}

variable "engine_version" {
  description = "Versão do PostgreSQL."
  type        = string
  default     = "15"
}

variable "instance_class" {
  description = "Tipo de instância RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Storage em GB."
  type        = number
  default     = 20
}

variable "tags" {
  description = "Tags comuns."
  type        = map(string)
  default     = {}
}

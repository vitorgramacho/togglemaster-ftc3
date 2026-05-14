variable "services" {
  description = "Todos os microsserviços (vira 1 namespace por serviço)."
  type        = list(string)
  default     = ["auth", "flag", "targeting", "evaluation", "analytics"]
}

variable "db_services" {
  description = "Subconjunto de serviços que precisam de DATABASE_URL (têm RDS dedicado)."
  type        = list(string)
  default     = ["auth", "flag", "targeting"]
}

variable "db_connection_urls" {
  description = "Map serviço -> DATABASE_URL completa (vem do módulo rds)."
  type        = map(string)
  sensitive   = true
}

variable "db_endpoints" {
  description = "Map serviço -> host RDS (vem do módulo rds)."
  type        = map(string)
}

variable "db_passwords" {
  description = "Map serviço -> senha RDS (vem do módulo rds)."
  type        = map(string)
  sensitive   = true
}

variable "db_master_username" {
  description = "Usuário master comum das instâncias RDS."
  type        = string
}

variable "redis_url" {
  description = "URL completa do Redis no formato redis://host:port."
  type        = string
}

variable "sqs_queue_url" {
  description = "URL da fila SQS."
  type        = string
}

variable "dynamodb_table_name" {
  description = "Nome da tabela DynamoDB."
  type        = string
  default     = "ToggleMasterAnalytics"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

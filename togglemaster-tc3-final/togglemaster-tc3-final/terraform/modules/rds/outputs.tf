output "endpoints" {
  description = "Endpoints (host) de cada instância, indexados pelo nome do banco."
  value       = { for k, v in aws_db_instance.this : k => v.address }
}

output "ports" {
  description = "Porta de cada instância."
  value       = { for k, v in aws_db_instance.this : k => v.port }
}

output "connection_urls" {
  description = "Connection strings prontas (sensíveis) — usadas pelo módulo k8s-bootstrap."
  value       = { for k, v in aws_db_instance.this : k => "postgres://${var.master_username}:${random_password.db[k].result}@${v.address}:${v.port}/${k}?sslmode=require" }
  sensitive   = true
}

output "passwords" {
  description = "Senhas geradas (sensíveis)."
  value       = { for k, v in random_password.db : k => v.result }
  sensitive   = true
}

output "secret_arns" {
  description = "ARNs dos Secrets criados no Secrets Manager."
  value       = { for k, v in aws_secretsmanager_secret.db : k => v.arn }
}

output "master_username" {
  description = "Usuário master usado em todas as instâncias."
  value       = var.master_username
}

output "security_group_id" {
  description = "Security Group dos bancos."
  value       = aws_security_group.rds.id
}

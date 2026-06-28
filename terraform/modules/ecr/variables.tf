variable "project" {
  type = string
}

variable "services" {
  type    = list(string)
  default = ["auth", "flag", "targeting", "evaluation", "analytics"]
}

variable "tags" {
  type    = map(string)
  default = {}
}

output "repository_urls" {
  description = "URLs dos repositórios ECR, indexados pelo nome do microsserviço."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  value = { for k, v in aws_ecr_repository.this : k => v.arn }
}

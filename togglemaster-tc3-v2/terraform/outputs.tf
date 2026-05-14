output "cluster_name" {
  description = "Use em: aws eks update-kubeconfig --name <output> --region us-east-1"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_urls" {
  description = "URLs dos repositórios ECR (mapa serviço -> URL)."
  value       = module.ecr.repository_urls
}

output "rds_endpoints" {
  description = "Endpoints dos bancos RDS."
  value       = module.rds.endpoints
}

output "redis_url" {
  description = "URL do Redis ElastiCache."
  value       = module.elasticache.redis_url
}

output "sqs_queue_url" {
  value = module.sqs.queue_url
}

output "dynamodb_table" {
  value = module.dynamodb.table_name
}

output "argocd_initial_admin_password_command" {
  description = "Comando para obter a senha inicial do admin do ArgoCD."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
}

output "argocd_port_forward_command" {
  description = "Comando para acessar a UI do ArgoCD localmente."
  value       = "kubectl -n argocd port-forward svc/argocd-server 8080:443"
}

output "cluster_name" {
  description = "Nome do cluster EKS."
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "Endpoint do API server do cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Certificate authority (base64) do cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group do control plane."
  value       = aws_security_group.cluster.id
}

output "cluster_arn" {
  description = "ARN do cluster EKS."
  value       = aws_eks_cluster.this.arn
}

output "node_group_arn" {
  description = "ARN do node group gerenciado."
  value       = aws_eks_node_group.this.arn
}

output "cluster_token" {
  description = "Token de autenticação para o cluster."
  value       = data.aws_eks_cluster_auth.this.token
  sensitive   = true
}

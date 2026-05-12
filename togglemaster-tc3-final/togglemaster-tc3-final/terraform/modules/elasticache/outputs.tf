output "endpoint_address" {
  description = "Hostname do node Redis."
  value       = aws_elasticache_cluster.this.cache_nodes[0].address
}

output "endpoint_port" {
  description = "Porta do Redis."
  value       = aws_elasticache_cluster.this.cache_nodes[0].port
}

output "redis_url" {
  description = "URL completa do Redis (formato redis://host:port) — pronta para uso pelo cliente Go."
  value       = "redis://${aws_elasticache_cluster.this.cache_nodes[0].address}:${aws_elasticache_cluster.this.cache_nodes[0].port}"
}

output "security_group_id" {
  value = aws_security_group.redis.id
}

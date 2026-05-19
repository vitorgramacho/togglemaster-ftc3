output "vpc_id" {
  description = "ID da VPC criada."
  value       = aws_vpc.main.id
}

output "vpc_cidr_block" {
  description = "CIDR da VPC."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas."
  value       = aws_subnet.private[*].id
}

output "internet_gateway_id" {
  description = "ID do Internet Gateway."
  value       = aws_internet_gateway.main.id
}

output "nat_gateway_id" {
  description = "ID do NAT Gateway."
  value       = aws_nat_gateway.main.id
}

output "alb_dns_name" {
  description = "URL publica do Load Balancer"
  value       = aws_lb.main.dns_name
}

output "alb_security_group_id" {
  description = "ID do Security Group do ALB para liberar entrada nos Workers"
  value       = aws_security_group.alb.id
}
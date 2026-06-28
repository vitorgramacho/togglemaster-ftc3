# =============================================================================
# Módulo: ElastiCache (Redis)
# Cluster Redis simples (1 nó) — suficiente para o evaluation-service usar
# como cache de avaliação de flags. NÃO habilitamos transit_encryption
# (TLS) propositalmente para manter compatibilidade com o cliente Go
# atual do evaluation-service, que abre conexão simples (redis://).
# =============================================================================

resource "aws_security_group" "redis" {
  name        = "${var.project}-redis-sg"
  description = "Permite trafego Redis (6379) apenas de dentro da VPC."
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.project}-redis-sg"
  })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.project}-redis-subnets"
  subnet_ids = var.subnet_ids

  tags = var.tags
}

resource "aws_elasticache_cluster" "this" {
  cluster_id           = "${var.project}-redis"
  engine               = "redis"
  engine_version       = var.engine_version
  node_type            = var.node_type
  num_cache_nodes      = 1
  parameter_group_name = var.parameter_group_name
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  tags = merge(var.tags, {
    Name = "${var.project}-redis"
  })
}

# =============================================================================
# Módulo: EKS
# Cria o cluster Kubernetes gerenciado e o Node Group.
#
# IMPORTANTE — AWS Academy:
# Este projeto NÃO cria roles IAM. Usamos a LabRole existente, conforme
# exigência da Opção A do enunciado. A role é importada via data source no
# módulo raiz e injetada aqui como variável "labrole_arn".
# =============================================================================

# -----------------------------------------------------------------------------
# Security Group do Cluster (control plane <-> nodes)
# -----------------------------------------------------------------------------
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "Security group do EKS control plane."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-cluster-sg"
  })
}

# -----------------------------------------------------------------------------
# Cluster EKS
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.labrole_arn

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
    security_group_ids      = [aws_security_group.cluster.id]
  }

  # Logs do control plane (útil para auditoria DevSecOps)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Node Group gerenciado
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = var.labrole_arn
  subnet_ids      = var.subnet_ids
  instance_types  = var.instance_types
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = var.desired_size
    max_size     = var.max_size
    min_size     = var.min_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = var.tags

  # O cluster precisa estar ATIVO antes do node group.
  depends_on = [aws_eks_cluster.this]

  # Mudanças de scaling externas (HPA, cluster-autoscaler) não devem causar drift.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# -----------------------------------------------------------------------------
# Data source para o token de autenticação do cluster
# -----------------------------------------------------------------------------
data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

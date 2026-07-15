

# Data source obrigatório no AWS Academy:
data "aws_iam_role" "labrole" {
  name = "LabRole"
}

locals {
  common_tags = {
    Project       = var.project
    Environment   = "production"
    ManagedBy     = "terraform"
    TechChallenge = "fase3"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1) Networking
# ─────────────────────────────────────────────────────────────────────────────
module "networking" {
  source = "./modules/networking"

  project      = var.project
  cluster_name = var.cluster_name
  tags         = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 2) ECR
# ─────────────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "./modules/ecr"

  project  = var.project
  # Fase 4: junta `services` e `infra_images` numa lista única
  # para o módulo ECR criar 1 repo para cada (5 microsserviços + 1 webhook).
  services = concat(var.services, var.infra_images)
  tags     = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 3) EKS (LabRole)
# ─────────────────────────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id             = module.networking.vpc_id
  subnet_ids         = module.networking.private_subnet_ids
  labrole_arn        = data.aws_iam_role.labrole.arn
  tags               = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 4) Bancos / cache / mensageria
# ─────────────────────────────────────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  project        = var.project
  vpc_id         = module.networking.vpc_id
  vpc_cidr_block = module.networking.vpc_cidr_block
  subnet_ids     = module.networking.private_subnet_ids
  databases      = var.db_names
  tags           = local.common_tags
}

module "elasticache" {
  source = "./modules/elasticache"

  project        = var.project
  vpc_id         = module.networking.vpc_id
  vpc_cidr_block = module.networking.vpc_cidr_block
  subnet_ids     = module.networking.private_subnet_ids
  tags           = local.common_tags
}

module "dynamodb" {
  source = "./modules/dynamodb"
  tags   = local.common_tags
}

module "sqs" {
  source = "./modules/sqs"
  tags   = local.common_tags
}

# ─────────────────────────────────────────────────────────────────────────────
# 5) Bootstrap de objetos K8s
# ─────────────────────────────────────────────────────────────────────────────
module "k8s_bootstrap" {
  source = "./modules/k8s-bootstrap"

  services            = var.services
  db_names            = var.db_names
  db_connection_urls  = module.rds.connection_urls
  db_endpoints        = module.rds.endpoints
  db_passwords        = module.rds.passwords
  db_master_username  = module.rds.master_username
  redis_url           = module.elasticache.redis_url
  sqs_queue_url       = module.sqs.queue_url
  dynamodb_table_name = module.dynamodb.table_name
  aws_region          = var.aws_region

  depends_on = [module.eks]
}

# ─────────────────────────────────────────────────────────────────────────────
# 6) ArgoCD (GitOps)
# ─────────────────────────────────────────────────────────────────────────────
module "argocd" {
  source = "./modules/argocd"

  services        = var.services
  gitops_repo_url = var.gitops_repo_url
  gitops_revision = var.gitops_revision
  expose_lb       = var.expose_argocd_lb

  depends_on = [module.eks]
}

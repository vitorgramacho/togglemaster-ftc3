# =============================================================================
# Backend remoto S3 (requisito de IaC do desafio).
#
# IMPORTANTE — crie o bucket antes do primeiro `terraform init`:
#   aws s3api create-bucket --bucket togglemaster-tfstate-<seu-id> --region us-east-1
#   aws s3api put-bucket-versioning --bucket togglemaster-tfstate-<seu-id> \
#       --versioning-configuration Status=Enabled
#
# A flag `use_lockfile = true` (Terraform >= 1.10) cria um arquivo de lock
# no próprio S3 e dispensa o DynamoDB para state locking (que em alguns
# AWS Academy é restrito).
# =============================================================================

terraform {
  backend "s3" {
    bucket       = "togglemaster-tfstate"        # ALTERE para um nome único globalmente
    key          = "togglemaster/fase3/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

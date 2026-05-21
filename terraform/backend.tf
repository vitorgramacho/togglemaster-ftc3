# =============================================================================
# Backend remoto S3 (requisito de IaC do desafio).
#
# O bucket NÃO é definido aqui para evitar conflito entre ambientes.
# Ele é injetado em runtime pelo workflow (ou pelo operador local) via:
#
#   terraform init \
#     -backend-config="bucket=SEU-BUCKET-UNICO" \
#     -backend-config="key=togglemaster/fase3/terraform.tfstate" \
#     -backend-config="region=us-east-1" \
#     -backend-config="encrypt=true" \
#     -backend-config="use_lockfile=true"
#
# A flag `use_lockfile = true` (Terraform >= 1.10) cria um arquivo de lock
# no próprio S3 e dispensa DynamoDB para state locking — compatível com
# AWS Academy onde DynamoDB pode ter restrições.
# =============================================================================

terraform {
  backend "s3" {
    # Todos os valores são fornecidos via -backend-config no `terraform init`.
    # Não deixar nada hardcoded aqui evita que um `terraform init` local
    # sem flags acidentalmente aponte para o bucket errado.
  }
}

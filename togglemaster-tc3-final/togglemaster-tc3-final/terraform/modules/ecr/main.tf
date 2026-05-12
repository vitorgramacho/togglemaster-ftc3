# =============================================================================
# Módulo: ECR
# Cria 1 repositório por microsserviço com scan habilitado e regra
# de retenção (apaga imagens não-tagueadas com mais de 7 dias).
# =============================================================================

resource "aws_ecr_repository" "this" {
  for_each = toset(var.services)

  name                 = "${var.project}-${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, {
    Name    = "${var.project}-${each.key}"
    Service = each.key
  })
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Manter apenas as 10 imagens mais recentes."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

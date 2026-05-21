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
        # Regra 1: apaga imagens sem tag em até 1 dia.
        # Evita acúmulo de camadas de builds cancelados/quebrados.
        rulePriority = 1
        description  = "Expirar imagens não-tageadas após 1 dia."
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        # Regra 2: manter apenas as 10 imagens tageadas mais recentes.
        rulePriority = 2
        description  = "Manter apenas as 10 imagens tageadas mais recentes."
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v"]
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}

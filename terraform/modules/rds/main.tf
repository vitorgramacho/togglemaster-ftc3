
resource "aws_security_group" "rds" {
  name        = "${var.project}-rds-sg"
  description = "Permite acesso ao PostgreSQL apenas de dentro da VPC."
  vpc_id      = var.vpc_id

  ingress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
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
    Name = "${var.project}-rds-sg"
  })
}

# -----------------------------------------------------------------------------
# DB Subnet Group (subnets privadas — bancos não ficam expostos à Internet)
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-rds-subnets"
  subnet_ids = var.subnet_ids

  tags = merge(var.tags, {
    Name = "${var.project}-rds-subnets"
  })
}

# -----------------------------------------------------------------------------
# Senhas — geradas aleatoriamente (1 por instância)
# -----------------------------------------------------------------------------
resource "random_password" "db" {
  for_each = toset(var.databases)
  length   = 20
  special  = true

  override_special = "_-."
}

# -----------------------------------------------------------------------------
# Instâncias RDS
# -----------------------------------------------------------------------------
resource "aws_db_instance" "this" {
  for_each = toset(var.databases)

  identifier        = "${var.project}-${each.key}"
  engine            = "postgres"
  engine_version    = var.engine_version
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = each.key
  username = var.master_username
  password = random_password.db[each.key].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false

  skip_final_snapshot          = true
  deletion_protection          = false
  backup_retention_period      = 1
  performance_insights_enabled = false

  tags = merge(var.tags, {
    Name    = "${var.project}-${each.key}"
    Service = each.key
  })
}


resource "aws_secretsmanager_secret" "db" {
  for_each                = toset(var.databases)
  name                    = "${var.project}/${each.key}/db-credentials"
  description             = "Credenciais do banco ${each.key} (${var.project})."
  recovery_window_in_days = 0 # sem janela de retenção -> permite recriar rápido em dev

  tags = merge(var.tags, {
    Service = each.key
  })
}

resource "aws_secretsmanager_secret_version" "db" {
  for_each  = toset(var.databases)
  secret_id = aws_secretsmanager_secret.db[each.key].id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.db[each.key].result
    host     = aws_db_instance.this[each.key].address
    port     = aws_db_instance.this[each.key].port
    dbname   = each.key
    # connection string pronta para uso pelos serviços (libpq URL)
    url = "postgres://${var.master_username}:${random_password.db[each.key].result}@${aws_db_instance.this[each.key].address}:${aws_db_instance.this[each.key].port}/${each.key}?sslmode=require"
  })
}

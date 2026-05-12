# =============================================================================
# Módulo: DynamoDB
# Tabela ToggleMasterAnalytics (requisito 3.3 do Tech Challenge Fase 3).
# Modelo: PAY_PER_REQUEST (sem capacidade provisionada) — barato e
# adequado para a carga esperada de PoC/Academy.
# =============================================================================

resource "aws_dynamodb_table" "analytics" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  # GSI para consultar eventos por flag (uso futuro do analytics-service)
  attribute {
    name = "flag_name"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  global_secondary_index {
    name            = "flag-timestamp-index"
    hash_key        = "flag_name"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = false # off em Academy para economizar
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.tags, {
    Name = var.table_name
  })
}

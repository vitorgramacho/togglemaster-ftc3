# =============================================================================
# Módulo: SQS
# Fila usada para desacoplar o evaluation-service do analytics-service.
# O evaluation publica eventos de avaliação; o analytics consome e
# persiste no DynamoDB.
# =============================================================================

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.queue_name}-dlq"
  message_retention_seconds = 1209600 # 14 dias (máximo)

  tags = merge(var.tags, {
    Name = "${var.queue_name}-dlq"
  })
}

resource "aws_sqs_queue" "main" {
  name                       = var.queue_name
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 dias
  receive_wait_time_seconds  = 20     # long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })

  tags = merge(var.tags, {
    Name = var.queue_name
  })
}

variable "table_name" {
  type    = string
  default = "ToggleMasterAnalytics"
}

variable "tags" {
  type    = map(string)
  default = {}
}

output "table_name" {
  value = aws_dynamodb_table.analytics.name
}

output "table_arn" {
  value = aws_dynamodb_table.analytics.arn
}

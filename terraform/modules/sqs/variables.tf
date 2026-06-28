variable "queue_name" {
  type    = string
  default = "togglemaster-queue"
}

variable "tags" {
  type    = map(string)
  default = {}
}

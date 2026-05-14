variable "project" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "vpc_cidr_block" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "engine_version" {
  type    = string
  default = "7.0"
}

variable "parameter_group_name" {
  type    = string
  default = "default.redis7"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "frontend_private_subnet_cidrs" {
  type = list(string)
}

variable "postgres_database_name" {
  type = string
}

variable "postgres_username" {
  type = string
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "instance_type" {
  type = string
}

variable "ami_id" {
  type    = string
  default = null
}

variable "volume_size" {
  type = number
}

variable "volume_type" {
  type = string
}

variable "volume_iops" {
  type = number
}

variable "volume_throughput" {
  type = number
}

variable "tags" {
  type = map(string)
}

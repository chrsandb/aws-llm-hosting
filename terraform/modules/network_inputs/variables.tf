variable "frontend_vpc_id" {
  type = string
}

variable "frontend_public_subnet_ids" {
  type = list(string)
}

variable "frontend_private_subnet_ids" {
  type = list(string)
}

variable "backend_vpc_id" {
  type = string
}

variable "backend_private_subnet_ids" {
  type = list(string)
}

variable "frontend_route_table_ids" {
  type = list(string)
}

variable "backend_route_table_ids" {
  type = list(string)
}

variable "assume_existing_vpc_routing" {
  type = bool
}

variable "frontend_idle_timeout_seconds" {
  type = number
}

variable "backend_idle_timeout_seconds" {
  type = number
}

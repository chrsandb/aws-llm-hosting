variable "name_prefix" {
  type = string
}

variable "frontend_vpc_id" {
  type = string
}

variable "backend_vpc_id" {
  type = string
}

variable "frontend_private_subnet_cidrs" {
  type = list(string)
}

variable "litellm_container_port" {
  type = number
}

variable "backend_server_port" {
  type = number
}

variable "admin_allowed_cidrs" {
  type = list(string)
}

variable "enable_ssh_access" {
  type = bool
}

variable "ssh_allowed_cidrs" {
  type = list(string)
}

variable "name_prefix" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "create_route53_zone" {
  type = bool
}

variable "route53_zone_id" {
  type    = string
  default = null
}

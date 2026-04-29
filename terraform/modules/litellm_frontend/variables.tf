variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "ecs_service_security_group_id" {
  type = string
}

variable "public_alb_security_group_id" {
  type = string
}

variable "internal_admin_alb_security_group_id" {
  type = string
}

variable "acm_certificate_arn" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "public_zone_id" {
  type = string
}

variable "litellm_image" {
  type = string
}

variable "litellm_container_port" {
  type = number
}

variable "frontend_task_cpu" {
  type = number
}

variable "frontend_task_memory" {
  type = number
}

variable "desired_count" {
  type = number
}

variable "postgres_security_group_id" {
  type = string
}

variable "postgres_instance_class" {
  type = string
}

variable "postgres_allocated_storage" {
  type = number
}

variable "postgres_database_name" {
  type = string
}

variable "postgres_username" {
  type = string
}

variable "create_litellm_master_key_secret" {
  type = bool
}

variable "existing_litellm_master_key_secret_arn" {
  type    = string
  default = null
}

variable "ecs_task_execution_role_arn" {
  type = string
}

variable "ecs_task_role_arn" {
  type = string
}

variable "litellm_admin_internal_only" {
  type = bool
}

variable "backend_base_url" {
  type = string
}

variable "backend_model_alias" {
  type = string
}

variable "admin_allowed_cidrs" {
  type = list(string)
}

variable "idle_timeout_seconds" {
  type = number
}

variable "enable_redis" {
  type = bool
}

variable "redis_node_type" {
  type = string
}

variable "redis_security_group_id" {
  type = string
}

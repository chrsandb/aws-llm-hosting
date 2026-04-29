variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cloudwatch_alarm_sns_topic_arn" {
  type    = string
  default = null
}

variable "public_alb_arn_suffix" {
  type = string
}

variable "backend_alb_arn_suffix" {
  type = string
}

variable "ecs_cluster_name" {
  type = string
}

variable "ecs_service_name" {
  type = string
}

variable "asg_name" {
  type = string
}

variable "asg_min_size" {
  type = number
}

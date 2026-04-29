variable "name_prefix" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "target_group_arn" {
  type = string
}

variable "backend_security_group_id" {
  type = string
}

variable "instance_profile_name" {
  type = string
}

variable "backend_ami_id" {
  type = string
}

variable "backend_instance_type" {
  type = string
}

variable "asg_min_size" {
  type = number
}

variable "asg_desired_capacity" {
  type = number
}

variable "asg_max_size" {
  type = number
}

variable "enable_ssh_access" {
  type = bool
}

variable "ssh_key_name" {
  type    = string
  default = null
}

variable "model_source" {
  type = string
}

variable "model_repo" {
  type = string
}

variable "model_filename" {
  type = string
}

variable "model_alias" {
  type = string
}

variable "model_path" {
  type = string
}

variable "model_ebs_snapshot_id" {
  type    = string
  default = null
}

variable "llama_cpp_image" {
  type = string
}

variable "llama_cpp_image_tag" {
  type = string
}

variable "llama_cpp_settings" {
  type = any
}

variable "backend_alb_arn_suffix" {
  type = string
}

variable "backend_target_group_arn_suffix" {
  type = string
}

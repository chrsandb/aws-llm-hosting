variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Short project identifier."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project_name))
    error_message = "project_name must be 3-24 chars of lowercase letters, numbers, or hyphens."
  }
}

variable "environment" {
  description = "Environment name such as dev, stage, or prod."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]{2,16}$", var.environment))
    error_message = "environment must be 2-16 chars of lowercase letters, numbers, or hyphens."
  }
}

variable "domain_name" {
  description = "Public FQDN for the LiteLLM endpoint."
  type        = string
}

variable "create_route53_zone" {
  description = "Create a public Route53 hosted zone for domain_name."
  type        = bool
  default     = false
}

variable "route53_zone_id" {
  description = "Existing Route53 public hosted zone ID. Leave null when create_route53_zone is true."
  type        = string
  default     = null
}

variable "frontend_vpc_id" {
  description = "VPC ID where frontend resources are deployed."
  type        = string
}

variable "frontend_public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB."
  type        = list(string)
}

variable "frontend_private_subnet_ids" {
  description = "Private subnet IDs for ECS tasks, RDS, and the internal admin ALB."
  type        = list(string)
}

variable "backend_vpc_id" {
  description = "VPC ID where backend resources are deployed."
  type        = string
}

variable "backend_private_subnet_ids" {
  description = "Private subnet IDs for the GPU instances and internal backend ALB."
  type        = list(string)
}

variable "backend_route_table_ids" {
  description = "Route table IDs associated with backend private subnets."
  type        = list(string)
  default     = []
}

variable "frontend_route_table_ids" {
  description = "Route table IDs associated with frontend public/private subnets."
  type        = list(string)
  default     = []
}

variable "assume_existing_vpc_routing" {
  description = "Skip route table assertions and assume private/public routing is already correct."
  type        = bool
  default     = true
}

variable "backend_instance_type" {
  description = "GPU instance type for llama.cpp workers."
  type        = string
  default     = "g6e.2xlarge"
}

variable "asg_min_size" {
  description = "Minimum backend ASG size."
  type        = number
  default     = 1
}

variable "asg_desired_capacity" {
  description = "Desired backend ASG capacity."
  type        = number
  default     = 1
}

variable "asg_max_size" {
  description = "Maximum backend ASG size."
  type        = number
  default     = 3
}

variable "backend_ami_id" {
  description = "AMI ID for the backend GPU image built by Packer or provided externally."
  type        = string
}

variable "model_repo" {
  description = "Model repository identifier."
  type        = string
  default     = "unsloth/Qwen3.6-35B-A3B-GGUF"
}

variable "model_filename" {
  description = "Model GGUF file name."
  type        = string
  default     = "UD-Q6_K_XL.gguf"
}

variable "model_alias" {
  description = "Friendly model alias exposed through LiteLLM."
  type        = string
  default     = "qwen3.6-35b-a3b"
}

variable "model_path" {
  description = "Absolute path to the GGUF file on backend instances."
  type        = string
  default     = "/models/UD-Q6_K_XL.gguf"
}

variable "model_source" {
  description = "How the model is provided to backend instances. Supported values: ebs_snapshot, ami, download."
  type        = string
  default     = "ebs_snapshot"

  validation {
    condition     = contains(["ebs_snapshot", "ami", "download"], var.model_source)
    error_message = "model_source must be one of ebs_snapshot, ami, or download."
  }
}

variable "model_ebs_snapshot_id" {
  description = "Snapshot ID used to create the attached model volume when model_source is ebs_snapshot."
  type        = string
  default     = null
}

variable "llama_cpp_image" {
  description = "Container image repository for llama.cpp."
  type        = string
  default     = "ghcr.io/ggerganov/llama.cpp"
}

variable "llama_cpp_image_tag" {
  description = "Container image tag for llama.cpp."
  type        = string
  default     = "server-cuda"
}

variable "llama_cpp_settings" {
  description = "Runtime settings passed to /etc/default/llama-server."
  type = object({
    ctx_size      = optional(number, 262144)
    n_parallel    = optional(number, 1)
    n_gpu_layers  = optional(number, 99)
    temp          = optional(number, 0.6)
    top_p         = optional(number, 0.95)
    top_k         = optional(number, 20)
    min_p         = optional(number, 0.00)
    think_budget  = optional(number, 2048)
    host          = optional(string, "0.0.0.0")
    port          = optional(number, 8080)
    batch_size    = optional(number, 1024)
    ubatch_size   = optional(number, 512)
    threads       = optional(number, 8)
    no_mmap       = optional(bool, false)
    metrics       = optional(bool, true)
    flash_attn    = optional(bool, true)
    cont_batching = optional(bool, true)
    jinja         = optional(bool, true)
  })
  default = {}
}

variable "enable_ssh_access" {
  description = "Open SSH to backend instances."
  type        = bool
  default     = false
}

variable "ssh_key_name" {
  description = "EC2 key pair name for optional SSH."
  type        = string
  default     = null
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach TCP/22 when SSH is enabled."
  type        = list(string)
  default     = []
}

variable "admin_allowed_cidrs" {
  description = "CIDRs allowed to reach the internal admin ALB if connected into the VPC."
  type        = list(string)
  default     = []
}

variable "litellm_admin_internal_only" {
  description = "When true, only expose the admin UI on the internal ALB."
  type        = bool
  default     = true
}

variable "litellm_image" {
  description = "LiteLLM container image."
  type        = string
  default     = "ghcr.io/berriai/litellm:main-latest"
}

variable "litellm_container_port" {
  description = "LiteLLM container port."
  type        = number
  default     = 4000
}

variable "frontend_task_cpu" {
  description = "Fargate CPU units for LiteLLM tasks."
  type        = number
  default     = 1024
}

variable "frontend_task_memory" {
  description = "Fargate memory in MiB for LiteLLM tasks."
  type        = number
  default     = 2048
}

variable "frontend_desired_count" {
  description = "Desired ECS task count for LiteLLM."
  type        = number
  default     = 2
}

variable "postgres_instance_class" {
  description = "RDS instance class for LiteLLM metadata database."
  type        = string
  default     = "db.t4g.medium"
}

variable "postgres_allocated_storage" {
  description = "Initial RDS storage in GiB."
  type        = number
  default     = 100
}

variable "postgres_database_name" {
  description = "LiteLLM PostgreSQL database name."
  type        = string
  default     = "litellm"
}

variable "postgres_username" {
  description = "LiteLLM PostgreSQL admin username."
  type        = string
  default     = "litellm"
}

variable "create_litellm_master_key_secret" {
  description = "Create a random LiteLLM master key secret in Secrets Manager."
  type        = bool
  default     = true
}

variable "existing_litellm_master_key_secret_arn" {
  description = "Existing secret ARN holding the LiteLLM master key."
  type        = string
  default     = null
}

variable "enable_redis" {
  description = "Deploy ElastiCache Redis for LiteLLM caching and coordination."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache node type if Redis is enabled."
  type        = string
  default     = "cache.t4g.small"
}

variable "frontend_idle_timeout_seconds" {
  description = "Idle timeout for the public ALB."
  type        = number
  default     = 300
}

variable "backend_idle_timeout_seconds" {
  description = "Idle timeout for the backend ALB."
  type        = number
  default     = 300
}

variable "cloudwatch_alarm_sns_topic_arn" {
  description = "Optional SNS topic ARN for alarm notifications."
  type        = string
  default     = null
}

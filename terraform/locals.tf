locals {
  name_prefix = "${var.project_name}-${var.environment}"

  model_volume_enabled = var.model_source == "ebs_snapshot"

  merged_llama_settings = merge(
    {
      ctx_size         = 12288
      parallel         = 2
      n_gpu_layers     = 99
      temp             = 0.5
      top_p            = 0.90
      top_k            = 40
      min_p            = 0.03
      reasoning_budget = 3072
      host             = "0.0.0.0"
      port             = 8080
      batch_size       = 1024
      ubatch_size      = 512
      threads          = 8
      no_mmap          = false
      metrics          = true
      flash_attn       = true
      cont_batching    = true
    },
    var.llama_cpp_settings,
  )

  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = "aws-llm-hosting"
  }
}

resource "terraform_data" "root_validations" {
  lifecycle {
    precondition {
      condition     = var.asg_min_size <= var.asg_desired_capacity && var.asg_desired_capacity <= var.asg_max_size
      error_message = "ASG sizes must satisfy min_size <= desired_capacity <= max_size."
    }

    precondition {
      condition     = var.enable_ssh_access ? var.ssh_key_name != null && length(var.ssh_allowed_cidrs) > 0 : true
      error_message = "When enable_ssh_access is true, ssh_key_name and ssh_allowed_cidrs must be provided."
    }

    precondition {
      condition     = var.model_source != "ebs_snapshot" || var.model_ebs_snapshot_id != null
      error_message = "model_ebs_snapshot_id must be provided when model_source is ebs_snapshot."
    }
  }

  input = local.name_prefix
}

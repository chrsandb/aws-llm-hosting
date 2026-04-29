output "api_base_url" {
  description = "Public LiteLLM endpoint."
  value       = "https://${var.domain_name}/v1"
}

output "anthropic_base_url" {
  description = "Anthropic-compatible path routed to LiteLLM."
  value       = "https://${var.domain_name}/anthropic"
}

output "frontend_public_alb_dns_name" {
  description = "Public ALB DNS name."
  value       = module.litellm_frontend.public_alb_dns_name
}

output "frontend_admin_alb_dns_name" {
  description = "Internal admin ALB DNS name."
  value       = module.litellm_frontend.admin_alb_dns_name
}

output "backend_internal_alb_dns_name" {
  description = "Internal backend ALB DNS name."
  value       = module.backend_alb.alb_dns_name
}

output "backend_asg_name" {
  description = "Backend Auto Scaling Group name."
  value       = module.backend_asg.asg_name
}

output "litellm_master_key_secret_arn" {
  description = "Secrets Manager ARN containing the LiteLLM master key."
  value       = module.litellm_frontend.litellm_master_key_secret_arn
}

output "postgres_secret_arn" {
  description = "Secrets Manager ARN containing the PostgreSQL admin password."
  value       = module.litellm_frontend.postgres_secret_arn
}

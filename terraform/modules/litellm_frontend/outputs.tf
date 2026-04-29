output "public_alb_dns_name" {
  value = aws_lb.public.dns_name
}

output "admin_alb_dns_name" {
  value = aws_lb.admin.dns_name
}

output "public_alb_arn_suffix" {
  value = aws_lb.public.arn_suffix
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_name" {
  value = aws_ecs_service.this.name
}

output "litellm_master_key_secret_arn" {
  value = local.master_key_secret_arn
}

output "postgres_secret_arn" {
  value = aws_secretsmanager_secret.postgres.arn
}

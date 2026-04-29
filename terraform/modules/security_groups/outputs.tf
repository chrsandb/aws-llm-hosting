output "frontend_public_alb_security_group_id" {
  value = aws_security_group.frontend_public_alb.id
}

output "frontend_admin_alb_security_group_id" {
  value = aws_security_group.frontend_admin_alb.id
}

output "litellm_service_security_group_id" {
  value = aws_security_group.litellm_service.id
}

output "backend_alb_security_group_id" {
  value = aws_security_group.backend_alb.id
}

output "backend_instance_security_group_id" {
  value = aws_security_group.backend_instance.id
}

output "postgres_security_group_id" {
  value = aws_security_group.postgres.id
}

output "redis_security_group_id" {
  value = aws_security_group.redis.id
}

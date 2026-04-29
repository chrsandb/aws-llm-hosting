resource "aws_security_group" "frontend_public_alb" {
  name        = "${var.name_prefix}-frontend-public-alb"
  description = "Public ALB access."
  vpc_id      = var.frontend_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "frontend_public_https" {
  security_group_id = aws_security_group.frontend_public_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Public HTTPS"
}

resource "aws_vpc_security_group_egress_rule" "frontend_public_all" {
  security_group_id = aws_security_group.frontend_public_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "frontend_admin_alb" {
  name        = "${var.name_prefix}-frontend-admin-alb"
  description = "Internal admin ALB access."
  vpc_id      = var.frontend_vpc_id
}

resource "aws_vpc_security_group_egress_rule" "frontend_admin_all" {
  security_group_id = aws_security_group.frontend_admin_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "frontend_admin_https" {
  for_each          = toset(var.admin_allowed_cidrs)
  security_group_id = aws_security_group.frontend_admin_alb.id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "Restricted admin HTTPS"
}

resource "aws_security_group" "litellm_service" {
  name        = "${var.name_prefix}-litellm-service"
  description = "LiteLLM ECS service."
  vpc_id      = var.frontend_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "litellm_from_public_alb" {
  security_group_id            = aws_security_group.litellm_service.id
  referenced_security_group_id = aws_security_group.frontend_public_alb.id
  from_port                    = var.litellm_container_port
  to_port                      = var.litellm_container_port
  ip_protocol                  = "tcp"
  description                  = "Public ALB to LiteLLM"
}

resource "aws_vpc_security_group_ingress_rule" "litellm_from_admin_alb" {
  security_group_id            = aws_security_group.litellm_service.id
  referenced_security_group_id = aws_security_group.frontend_admin_alb.id
  from_port                    = var.litellm_container_port
  to_port                      = var.litellm_container_port
  ip_protocol                  = "tcp"
  description                  = "Admin ALB to LiteLLM"
}

resource "aws_vpc_security_group_egress_rule" "litellm_service_all" {
  security_group_id = aws_security_group.litellm_service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "backend_alb" {
  name        = "${var.name_prefix}-backend-alb"
  description = "Internal backend ALB."
  vpc_id      = var.backend_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "backend_alb_from_litellm" {
  for_each          = toset(var.frontend_private_subnet_cidrs)
  security_group_id = aws_security_group.backend_alb.id
  cidr_ipv4         = each.value
  from_port         = var.backend_server_port
  to_port           = var.backend_server_port
  ip_protocol       = "tcp"
  description       = "Frontend private subnet access to backend ALB"
}

resource "aws_vpc_security_group_egress_rule" "backend_alb_all" {
  security_group_id = aws_security_group.backend_alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "backend_instance" {
  name        = "${var.name_prefix}-backend-instance"
  description = "Private GPU backend instances."
  vpc_id      = var.backend_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_backend_alb" {
  security_group_id            = aws_security_group.backend_instance.id
  referenced_security_group_id = aws_security_group.backend_alb.id
  from_port                    = var.backend_server_port
  to_port                      = var.backend_server_port
  ip_protocol                  = "tcp"
  description                  = "Internal backend ALB to llama.cpp"
}

resource "aws_vpc_security_group_egress_rule" "backend_instance_all" {
  security_group_id = aws_security_group.backend_instance.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "backend_ssh" {
  for_each          = var.enable_ssh_access ? toset(var.ssh_allowed_cidrs) : toset([])
  security_group_id = aws_security_group.backend_instance.id
  cidr_ipv4         = each.value
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  description       = "Optional SSH"
}

resource "aws_security_group" "postgres" {
  name        = "${var.name_prefix}-postgres"
  description = "LiteLLM PostgreSQL."
  vpc_id      = var.frontend_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "postgres_from_litellm" {
  security_group_id            = aws_security_group.postgres.id
  referenced_security_group_id = aws_security_group.litellm_service.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "postgres_all" {
  security_group_id = aws_security_group.postgres.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Optional LiteLLM Redis."
  vpc_id      = var.frontend_vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_litellm" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.litellm_service.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "redis_all" {
  security_group_id = aws_security_group.redis.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

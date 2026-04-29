resource "random_password" "postgres" {
  length  = 32
  special = false
}

resource "random_password" "master_key" {
  count   = var.create_litellm_master_key_secret ? 1 : 0
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "postgres" {
  name = "${var.name_prefix}/litellm/postgres"
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id
  secret_string = jsonencode({
    username = var.postgres_username
    password = random_password.postgres.result
    dbname   = var.postgres_database_name
    url      = "postgresql://${var.postgres_username}:${random_password.postgres.result}@${aws_db_instance.this.address}:5432/${var.postgres_database_name}"
  })
}

resource "aws_secretsmanager_secret" "master_key" {
  count = var.create_litellm_master_key_secret ? 1 : 0
  name  = "${var.name_prefix}/litellm/master-key"
}

resource "aws_secretsmanager_secret_version" "master_key" {
  count         = var.create_litellm_master_key_secret ? 1 : 0
  secret_id     = aws_secretsmanager_secret.master_key[0].id
  secret_string = random_password.master_key[0].result
}

locals {
  master_key_secret_arn = var.create_litellm_master_key_secret ? aws_secretsmanager_secret.master_key[0].arn : var.existing_litellm_master_key_secret_arn
}

resource "terraform_data" "master_key_validation" {
  lifecycle {
    precondition {
      condition     = local.master_key_secret_arn != null
      error_message = "Provide existing_litellm_master_key_secret_arn when create_litellm_master_key_secret is false."
    }
  }

  input = local.master_key_secret_arn
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name_prefix}-litellm"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "this" {
  identifier              = "${var.name_prefix}-litellm"
  engine                  = "postgres"
  engine_version          = "16.3"
  instance_class          = var.postgres_instance_class
  allocated_storage       = var.postgres_allocated_storage
  storage_type            = "gp3"
  username                = var.postgres_username
  password                = random_password.postgres.result
  db_name                 = var.postgres_database_name
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [var.postgres_security_group_id]
  multi_az                = false
  publicly_accessible     = false
  skip_final_snapshot     = true
  deletion_protection     = false
  backup_retention_period = 7
  apply_immediately       = true
}

resource "aws_elasticache_subnet_group" "this" {
  count      = var.enable_redis ? 1 : 0
  name       = "${var.name_prefix}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_elasticache_replication_group" "this" {
  count                      = var.enable_redis ? 1 : 0
  replication_group_id       = replace("${var.name_prefix}-redis", "-", "")
  description                = "LiteLLM Redis cache"
  node_type                  = var.redis_node_type
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.this[0].name
  security_group_ids         = [var.redis_security_group_id]
  automatic_failover_enabled = false
  num_cache_clusters         = 1
  parameter_group_name       = "default.redis7"
  engine_version             = "7.1"
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/${var.name_prefix}/frontend/ecs"
  retention_in_days = 30
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-litellm"
}

resource "aws_lb" "public" {
  name               = substr("${var.name_prefix}-public", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.public_alb_security_group_id]
  subnets            = var.public_subnet_ids
  idle_timeout       = var.idle_timeout_seconds
}

resource "aws_lb" "admin" {
  name               = substr("${var.name_prefix}-admin", 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.internal_admin_alb_security_group_id]
  subnets            = var.private_subnet_ids
  idle_timeout       = var.idle_timeout_seconds
}

resource "aws_lb_target_group" "public" {
  name        = substr("${var.name_prefix}-proxy-pub", 0, 32)
  port        = var.litellm_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "admin" {
  name        = substr("${var.name_prefix}-proxy-admin", 0, 32)
  port        = var.litellm_container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "public_https" {
  load_balancer_arn = aws_lb.public.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "public_v1" {
  listener_arn = aws_lb_listener.public_https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.public.arn
  }

  condition {
    path_pattern {
      values = ["/v1/*", "/health*"]
    }
  }
}

resource "aws_lb_listener" "admin_https" {
  load_balancer_arn = aws_lb.admin.arn
  port              = 443
  protocol          = "HTTPS"
  certificate_arn   = var.acm_certificate_arn
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin.arn
  }
}

resource "aws_route53_record" "public_alias" {
  zone_id = var.public_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.public.dns_name
    zone_id                = aws_lb.public.zone_id
    evaluate_target_health = true
  }
}

locals {
  redis_url = var.enable_redis ? "redis://${aws_elasticache_replication_group.this[0].primary_endpoint_address}:6379/0" : ""

  litellm_bootstrap = <<-EOT
    cat >/tmp/config.yaml <<'CFG'
    model_list:
      - model_name: ${var.backend_model_alias}
        litellm_params:
          model: openai/${var.backend_model_alias}
          api_base: ${var.backend_base_url}
    litellm_settings:
      master_key: os.environ/LITELLM_MASTER_KEY
      database_url: os.environ/DATABASE_URL
      store_model_in_db: true
      ui_access_mode: "admin_only"
      background_health_checks: true
      infer_model_from_keys: true
      disable_spend_logs: false
    router_settings:
      routing_strategy: "simple-shuffle"
      num_retries: 2
      timeout: 300
    CFG
    exec litellm --config /tmp/config.yaml --port ${var.litellm_container_port} --host 0.0.0.0
  EOT
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-litellm"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.frontend_task_cpu
  memory                   = var.frontend_task_memory
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  container_definitions = jsonencode([
    {
      name      = "litellm"
      image     = var.litellm_image
      essential = true
      command   = ["/bin/sh", "-lc", local.litellm_bootstrap]
      portMappings = [
        {
          containerPort = var.litellm_container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "LITELLM_LOG", value = "INFO" },
        { name = "UI_USERNAME", value = "admin" },
        { name = "REDIS_URL", value = local.redis_url }
      ]
      secrets = [
        {
          name      = "LITELLM_MASTER_KEY"
          valueFrom = local.master_key_secret_arn
        },
        {
          name      = "DATABASE_URL"
          valueFrom = "${aws_secretsmanager_secret.postgres.arn}:url::"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "litellm"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-litellm"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    assign_public_ip = false
    security_groups  = [var.ecs_service_security_group_id]
    subnets          = var.private_subnet_ids
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.public.arn
    container_name   = "litellm"
    container_port   = var.litellm_container_port
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.admin.arn
    container_name   = "litellm"
    container_port   = var.litellm_container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    aws_lb_listener.public_https,
    aws_lb_listener.admin_https
  ]
}

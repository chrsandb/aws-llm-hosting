module "network_inputs" {
  source = "./modules/network_inputs"

  frontend_vpc_id               = var.frontend_vpc_id
  frontend_public_subnet_ids    = var.frontend_public_subnet_ids
  frontend_private_subnet_ids   = var.frontend_private_subnet_ids
  backend_vpc_id                = var.backend_vpc_id
  backend_private_subnet_ids    = var.backend_private_subnet_ids
  frontend_route_table_ids      = var.frontend_route_table_ids
  backend_route_table_ids       = var.backend_route_table_ids
  assume_existing_vpc_routing   = var.assume_existing_vpc_routing
  frontend_idle_timeout_seconds = var.frontend_idle_timeout_seconds
  backend_idle_timeout_seconds  = var.backend_idle_timeout_seconds
}

module "dns_acm" {
  source = "./modules/dns_acm"

  name_prefix         = local.name_prefix
  domain_name         = var.domain_name
  create_route53_zone = var.create_route53_zone
  route53_zone_id     = var.route53_zone_id
}

module "iam" {
  source = "./modules/iam"

  name_prefix    = local.name_prefix
  aws_region     = var.aws_region
  aws_partition  = data.aws_partition.current.partition
  aws_account_id = data.aws_caller_identity.current.account_id
}

module "security_groups" {
  source = "./modules/security_groups"

  name_prefix                   = local.name_prefix
  frontend_vpc_id               = module.network_inputs.frontend_vpc_id
  backend_vpc_id                = module.network_inputs.backend_vpc_id
  frontend_private_subnet_cidrs = [for subnet in data.aws_subnet.frontend_private : subnet.cidr_block]
  litellm_container_port        = var.litellm_container_port
  backend_server_port           = local.merged_llama_settings.port
  admin_allowed_cidrs           = var.admin_allowed_cidrs
  enable_ssh_access             = var.enable_ssh_access
  ssh_allowed_cidrs             = var.ssh_allowed_cidrs
}

module "backend_alb" {
  source = "./modules/backend_alb"

  name_prefix           = local.name_prefix
  vpc_id                = module.network_inputs.backend_vpc_id
  private_subnet_ids    = module.network_inputs.backend_private_subnet_ids
  alb_security_group_id = module.security_groups.backend_alb_security_group_id
  target_port           = local.merged_llama_settings.port
  idle_timeout_seconds  = var.backend_idle_timeout_seconds
}

module "litellm_frontend" {
  source = "./modules/litellm_frontend"

  name_prefix                            = local.name_prefix
  aws_region                             = var.aws_region
  vpc_id                                 = module.network_inputs.frontend_vpc_id
  private_subnet_ids                     = module.network_inputs.frontend_private_subnet_ids
  public_subnet_ids                      = module.network_inputs.frontend_public_subnet_ids
  ecs_service_security_group_id          = module.security_groups.litellm_service_security_group_id
  public_alb_security_group_id           = module.security_groups.frontend_public_alb_security_group_id
  internal_admin_alb_security_group_id   = module.security_groups.frontend_admin_alb_security_group_id
  acm_certificate_arn                    = module.dns_acm.certificate_arn
  domain_name                            = var.domain_name
  public_zone_id                         = module.dns_acm.zone_id
  litellm_image                          = var.litellm_image
  litellm_container_port                 = var.litellm_container_port
  frontend_task_cpu                      = var.frontend_task_cpu
  frontend_task_memory                   = var.frontend_task_memory
  desired_count                          = var.frontend_desired_count
  postgres_security_group_id             = module.security_groups.postgres_security_group_id
  postgres_instance_class                = var.postgres_instance_class
  postgres_allocated_storage             = var.postgres_allocated_storage
  postgres_database_name                 = var.postgres_database_name
  postgres_username                      = var.postgres_username
  create_litellm_master_key_secret       = var.create_litellm_master_key_secret
  existing_litellm_master_key_secret_arn = var.existing_litellm_master_key_secret_arn
  ecs_task_execution_role_arn            = module.iam.ecs_task_execution_role_arn
  ecs_task_role_arn                      = module.iam.ecs_task_role_arn
  litellm_admin_internal_only            = var.litellm_admin_internal_only
  backend_base_url                       = "http://${module.backend_alb.alb_dns_name}:${local.merged_llama_settings.port}"
  backend_model_alias                    = var.model_alias
  admin_allowed_cidrs                    = var.admin_allowed_cidrs
  idle_timeout_seconds                   = var.frontend_idle_timeout_seconds
  enable_redis                           = var.enable_redis
  redis_node_type                        = var.redis_node_type
  redis_security_group_id                = module.security_groups.redis_security_group_id
}

module "backend_asg" {
  source = "./modules/backend_asg"

  name_prefix                     = local.name_prefix
  aws_region                      = var.aws_region
  vpc_id                          = module.network_inputs.backend_vpc_id
  subnet_ids                      = module.network_inputs.backend_private_subnet_ids
  target_group_arn                = module.backend_alb.target_group_arn
  backend_security_group_id       = module.security_groups.backend_instance_security_group_id
  instance_profile_name           = module.iam.backend_instance_profile_name
  backend_ami_id                  = var.backend_ami_id
  backend_instance_type           = var.backend_instance_type
  asg_min_size                    = var.asg_min_size
  asg_desired_capacity            = var.asg_desired_capacity
  asg_max_size                    = var.asg_max_size
  enable_ssh_access               = var.enable_ssh_access
  ssh_key_name                    = var.ssh_key_name
  model_source                    = var.model_source
  model_repo                      = var.model_repo
  model_filename                  = var.model_filename
  model_alias                     = var.model_alias
  model_path                      = var.model_path
  model_ebs_snapshot_id           = var.model_ebs_snapshot_id
  llama_cpp_image                 = var.llama_cpp_image
  llama_cpp_image_tag             = var.llama_cpp_image_tag
  llama_cpp_settings              = local.merged_llama_settings
  backend_alb_arn_suffix          = module.backend_alb.alb_arn_suffix
  backend_target_group_arn_suffix = module.backend_alb.target_group_arn_suffix
}

module "observability" {
  source = "./modules/observability"

  name_prefix                    = local.name_prefix
  aws_region                     = var.aws_region
  cloudwatch_alarm_sns_topic_arn = var.cloudwatch_alarm_sns_topic_arn
  public_alb_arn_suffix          = module.litellm_frontend.public_alb_arn_suffix
  backend_alb_arn_suffix         = module.backend_alb.alb_arn_suffix
  ecs_cluster_name               = module.litellm_frontend.ecs_cluster_name
  ecs_service_name               = module.litellm_frontend.ecs_service_name
  asg_name                       = module.backend_asg.asg_name
  asg_min_size                   = var.asg_min_size
}

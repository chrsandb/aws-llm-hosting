locals {
  attach_model_volume = var.model_source == "ebs_snapshot"

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region          = var.aws_region
    model_source        = var.model_source
    model_repo          = var.model_repo
    model_filename      = var.model_filename
    model_alias         = var.model_alias
    model_path          = var.model_path
    llama_cpp_image     = var.llama_cpp_image
    llama_cpp_image_tag = var.llama_cpp_image_tag
    llama_settings      = var.llama_cpp_settings
  })
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name_prefix}-backend-"
  image_id      = var.backend_ami_id
  instance_type = var.backend_instance_type
  key_name      = var.enable_ssh_access ? var.ssh_key_name : null

  iam_instance_profile {
    name = var.instance_profile_name
  }

  update_default_version = true

  vpc_security_group_ids = [var.backend_security_group_id]

  user_data = base64encode(local.user_data)

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
    http_put_response_hop_limit = 2
  }

  dynamic "block_device_mappings" {
    for_each = local.attach_model_volume ? [1] : []
    content {
      device_name = "/dev/sdf"

      ebs {
        snapshot_id           = var.model_ebs_snapshot_id
        volume_size           = 300
        volume_type           = "gp3"
        delete_on_termination = true
        encrypted             = true
      }
    }
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${var.name_prefix}-backend"
      Role = "llama-backend"
    }
  }
}

resource "aws_autoscaling_group" "this" {
  name                      = "${var.name_prefix}-backend"
  min_size                  = var.asg_min_size
  desired_capacity          = var.asg_desired_capacity
  max_size                  = var.asg_max_size
  health_check_type         = "ELB"
  health_check_grace_period = 600
  vpc_zone_identifier       = var.subnet_ids
  target_group_arns         = [var.target_group_arn]

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Default"
  }

  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 600
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-backend"
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_policy" "target_requests" {
  name                   = "${var.name_prefix}-alb-requests"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.backend_alb_arn_suffix}/${var.backend_target_group_arn_suffix}"
    }

    target_value = 4
  }
}

resource "aws_autoscaling_policy" "target_cpu" {
  name                   = "${var.name_prefix}-cpu"
  autoscaling_group_name = aws_autoscaling_group.this.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 70
  }
}

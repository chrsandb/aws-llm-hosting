resource "aws_cloudwatch_log_group" "backend" {
  name              = "/${var.name_prefix}/backend"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/${var.name_prefix}/frontend"
  retention_in_days = 30
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-llm"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Public ALB Requests and Latency"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.public_alb_arn_suffix],
            [".", "TargetResponseTime", ".", "."]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Backend ALB Latency"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.backend_alb_arn_suffix]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ASG CPU"
          view   = "timeSeries"
          region = var.aws_region
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name]
          ]
        }
      }
    ]
  })
}

resource "aws_cloudwatch_metric_alarm" "public_5xx" {
  alarm_name          = "${var.name_prefix}-public-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5
  alarm_actions       = var.cloudwatch_alarm_sns_topic_arn == null ? [] : [var.cloudwatch_alarm_sns_topic_arn]
  dimensions = {
    LoadBalancer = var.public_alb_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "backend_unhealthy" {
  alarm_name          = "${var.name_prefix}-backend-unhealthy"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_actions       = var.cloudwatch_alarm_sns_topic_arn == null ? [] : [var.cloudwatch_alarm_sns_topic_arn]
  dimensions = {
    LoadBalancer = var.backend_alb_arn_suffix
  }
}

resource "aws_cloudwatch_metric_alarm" "asg_in_service" {
  alarm_name          = "${var.name_prefix}-asg-low-capacity"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "GroupInServiceInstances"
  namespace           = "AWS/AutoScaling"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_actions       = var.cloudwatch_alarm_sns_topic_arn == null ? [] : [var.cloudwatch_alarm_sns_topic_arn]
  dimensions = {
    AutoScalingGroupName = var.asg_name
  }
}

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ecs_task_inline" {
  statement {
    sid     = "AllowSecretsRead"
    actions = ["secretsmanager:GetSecretValue", "ssm:GetParameter", "ssm:GetParameters"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_task_execution_inline" {
  name   = "${var.name_prefix}-ecs-exec-inline"
  role   = aws_iam_role.ecs_task_execution.id
  policy = data.aws_iam_policy_document.ecs_task_inline.json
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy" "ecs_task" {
  name   = "${var.name_prefix}-ecs-task"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task_inline.json
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backend_instance" {
  name               = "${var.name_prefix}-backend-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "backend_ssm" {
  role       = aws_iam_role.backend_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "backend_cloudwatch_agent" {
  role       = aws_iam_role.backend_instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "backend_inline" {
  statement {
    sid       = "AllowDescribe"
    actions   = ["ec2:DescribeVolumes", "ec2:DescribeTags", "autoscaling:CompleteLifecycleAction"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "backend_inline" {
  name   = "${var.name_prefix}-backend-inline"
  role   = aws_iam_role.backend_instance.id
  policy = data.aws_iam_policy_document.backend_inline.json
}

resource "aws_iam_instance_profile" "backend" {
  name = "${var.name_prefix}-backend"
  role = aws_iam_role.backend_instance.name
}

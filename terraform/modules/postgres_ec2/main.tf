locals {
  merged_tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-postgres"
      Role = "postgres"
    }
  )

  allowed_cidrs_literal = join(" ", var.frontend_private_subnet_cidrs)
}

data "aws_ssm_parameter" "ubuntu_ami" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
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

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-postgres-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name_prefix}-postgres-ec2"
  role = aws_iam_role.this.name
  tags = var.tags
}

resource "aws_instance" "this" {
  ami                         = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.ubuntu_ami[0].value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = aws_iam_instance_profile.this.name
  associate_public_ip_address = false
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    allowed_cidrs          = local.allowed_cidrs_literal
    postgres_database_name = var.postgres_database_name
    postgres_username      = var.postgres_username
    postgres_password      = var.postgres_password
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 20
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_size           = var.volume_size
    volume_type           = var.volume_type
    encrypted             = true
    delete_on_termination = true
    iops                  = var.volume_iops
    throughput            = var.volume_throughput
  }

  tags = local.merged_tags
}

packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.2.8"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "subnet_id" {
  type = string
}

variable "security_group_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "g6e.2xlarge"
}

variable "ssh_username" {
  type    = string
  default = "ubuntu"
}

variable "ami_name_prefix" {
  type    = string
  default = "llm-backend"
}

variable "source_ami_id" {
  type    = string
  default = null
}

variable "source_ami_name_pattern" {
  type    = string
  default = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"
}

variable "llama_cpp_image_tag" {
  type    = string
  default = "server-cuda"
}

variable "model_source" {
  type    = string
  default = "ebs_snapshot"
}

variable "copy_model_into_ami" {
  type    = bool
  default = false
}

variable "model_local_path" {
  type    = string
  default = "model.gguf"
}

source "amazon-ebs" "backend" {
  ami_name      = "${var.ami_name_prefix}-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  instance_type = var.instance_type
  region        = var.aws_region
  ssh_username  = var.ssh_username
  subnet_id     = var.subnet_id
  security_group_id = var.security_group_id

  source_ami = var.source_ami_id

  source_ami_filter {
    filters = {
      name                = var.source_ami_name_pattern
      architecture        = "x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name       = "${var.ami_name_prefix}-backend"
    ImageRole  = "llama-backend"
    ManagedBy  = "packer"
    ModelMode  = var.model_source
    LlamaTag   = var.llama_cpp_image_tag
  }
}

build {
  sources = ["source.amazon-ebs.backend"]

  provisioner "shell" {
    script = "${path.root}/scripts/install-backend-deps.sh"
    environment_vars = [
      "LLAMA_CPP_IMAGE_TAG=${var.llama_cpp_image_tag}"
    ]
  }

  provisioner "file" {
    source      = "${path.root}/../docker/run-llama-server.sh"
    destination = "/tmp/run-llama-server.sh"
  }

  provisioner "file" {
    source      = "${path.root}/../docker/llama-server.service"
    destination = "/tmp/llama-server.service"
  }

  provisioner "file" {
    source      = "${path.root}/cloudwatch-agent-config.json"
    destination = "/tmp/cloudwatch-agent-config.json"
  }

  provisioner "shell" {
    inline = [
      "sudo install -m 0755 /tmp/run-llama-server.sh /usr/local/bin/run-llama-server.sh",
      "sudo install -m 0644 /tmp/llama-server.service /etc/systemd/system/llama-server.service",
      "sudo install -m 0644 /tmp/cloudwatch-agent-config.json /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json",
      "sudo mkdir -p /etc/default /models",
      "sudo touch /etc/default/llama-server",
      "sudo systemctl enable docker",
      "sudo systemctl enable amazon-cloudwatch-agent"
    ]
  }

  provisioner "file" {
    source      = var.copy_model_into_ami ? var.model_local_path : "${path.root}/placeholder-model.txt"
    destination = "/tmp/model.gguf"
  }

  provisioner "shell" {
    inline = var.copy_model_into_ami ? [
      "sudo mkdir -p /models",
      "sudo mv /tmp/model.gguf /models/model.gguf",
      "sudo chmod 0644 /models/model.gguf"
    ] : ["echo model copy skipped"]
  }

  post-processor "manifest" {
    output = "${path.root}/manifest.json"
  }
}

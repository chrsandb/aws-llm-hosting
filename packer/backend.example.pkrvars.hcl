aws_region        = "eu-north-1"
subnet_id         = "subnet-0123456789abcdef0"
security_group_id = "sg-0123456789abcdef0"
instance_type     = "g6e.2xlarge"
ssh_username      = "ubuntu"
ami_name_prefix   = "llm-backend"

# Leave source_ami_id unset to use source_ami_name_pattern.
# Set this explicitly if you want to pin a known AMI.
# source_ami_id = "ami-0123456789abcdef0"

source_ami_name_pattern = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"
llama_cpp_image_tag     = "server-cuda"
model_source            = "ebs_snapshot"
copy_model_into_ami     = false

# Enable only when copy_model_into_ami = true.
model_local_path = "model.gguf"

aws_region        = "eu-north-1"
# This should be one of your backend private subnets.
# The easiest path is to generate this file with:
# ./scripts/prepare-packer-build.sh --region eu-north-1 --tfvars examples/generated.prod.tfvars --pkrvars-out packer/backend.auto.pkrvars.hcl
subnet_id         = "subnet-0123456789abcdef0"
# This temporary security group does not need inbound SSH because the Packer
# template uses AWS Session Manager for provisioning.
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

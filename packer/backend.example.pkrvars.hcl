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

# Default pinned base AMI.
source_ami_id = "ami-00e2c2ccdcd58e2ba"

# Optional fallback search pattern. Use this only if you intentionally remove
# source_ami_id and want Packer to resolve a base AMI by name instead.
# source_ami_name_pattern = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)*"

# Optional: pre-created instance profile for locked-down AWS accounts. When set,
# Packer uses this instead of creating a temporary role and instance profile.
# packer_instance_profile_name = "llm-packer-builder"

root_volume_encrypted = true

# Optional: set this if your organization requires a customer-managed KMS key
# for EBS encryption during the Packer build.
# root_volume_kms_key_id = "arn:aws:kms:eu-north-1:123456789012:key/00000000-0000-0000-0000-000000000000"

# Optional: extend or shorten how long Packer waits for a slow AMI snapshot to
# finish. The defaults below allow roughly 90 minutes of waiter time.
# aws_poll_delay_seconds = 20
# aws_max_attempts       = 270

llama_cpp_image_tag     = "server-cuda"
model_source            = "ebs_snapshot"
copy_model_into_ami     = false

# Enable only when copy_model_into_ami = true.
model_local_path = "model.gguf"

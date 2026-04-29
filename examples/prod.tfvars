project_name = "llm-hosting"
environment  = "prod"
domain_name  = "llm.example.com"

create_route53_zone = false
route53_zone_id     = "Z1234567890EXAMPLE"

frontend_vpc_id             = "vpc-frontend123"
frontend_public_subnet_ids  = ["subnet-public-a", "subnet-public-b", "subnet-public-c"]
frontend_private_subnet_ids = ["subnet-private-a", "subnet-private-b", "subnet-private-c"]

backend_vpc_id             = "vpc-backend123"
backend_private_subnet_ids = ["subnet-backend-a", "subnet-backend-b", "subnet-backend-c"]

backend_route_table_ids  = ["rtb-backend-a", "rtb-backend-b", "rtb-backend-c"]
frontend_route_table_ids = ["rtb-front-public-a", "rtb-front-public-b", "rtb-front-public-c", "rtb-front-private-a", "rtb-front-private-b", "rtb-front-private-c"]

assume_existing_vpc_routing = true

backend_instance_type = "g6e.2xlarge"
asg_min_size          = 1
asg_desired_capacity  = 1
asg_max_size          = 3

backend_ami_id         = "ami-0123456789abcdef0"
model_ebs_snapshot_id  = "snap-0123456789abcdef0"
model_source           = "ebs_snapshot"
model_repo             = "unsloth/Qwen3.6-27B-GGUF"
model_filename         = "UD-Q6_K_XL.gguf"
model_alias            = "qwen3.6-27b"
model_path             = "/models/UD-Q6_K_XL.gguf"
llama_cpp_image        = "ghcr.io/ggerganov/llama.cpp"
llama_cpp_image_tag    = "server-cuda"

admin_allowed_cidrs = ["10.40.0.0/16", "10.41.0.0/16"]

llama_cpp_settings = {
  ctx_size         = 12288
  parallel         = 2
  n_gpu_layers     = 99
  temp             = 0.5
  top_p            = 0.9
  top_k            = 40
  min_p            = 0.03
  reasoning_budget = 3072
  host             = "0.0.0.0"
  port             = 8080
}

project_name = "llm-hosting"
environment  = "dev"
domain_name  = "llm-dev.example.com"

create_route53_zone = false
route53_zone_id     = "Z1234567890EXAMPLE"

frontend_vpc_id             = "vpc-frontend123"
frontend_public_subnet_ids  = ["subnet-public-a", "subnet-public-b"]
frontend_private_subnet_ids = ["subnet-private-a", "subnet-private-b"]

backend_vpc_id             = "vpc-backend123"
backend_private_subnet_ids = ["subnet-backend-a", "subnet-backend-b"]

backend_route_table_ids  = ["rtb-backend-a", "rtb-backend-b"]
frontend_route_table_ids = ["rtb-front-public-a", "rtb-front-public-b", "rtb-front-private-a", "rtb-front-private-b"]

assume_existing_vpc_routing = true

backend_ami_id         = "ami-0123456789abcdef0"
model_ebs_snapshot_id  = "snap-0123456789abcdef0"
model_source           = "ebs_snapshot"
model_repo             = "unsloth/Qwen3.6-35B-A3B-GGUF"
model_filename         = "UD-Q6_K_XL.gguf"
model_alias            = "qwen3.6-35b-a3b"
model_path             = "/models/UD-Q6_K_XL.gguf"
llama_cpp_image        = "ghcr.io/ggerganov/llama.cpp"
llama_cpp_image_tag    = "server-cuda"

admin_allowed_cidrs = ["10.0.0.0/8"]

llama_cpp_settings = {
  ctx_size         = 262144
  n_parallel       = 1
  n_gpu_layers     = 99
  temp             = 0.6
  top_p            = 0.95
  top_k            = 20
  min_p            = 0.00
  think_budget     = 2048
  host             = "0.0.0.0"
  port             = 8080
  jinja            = true
}

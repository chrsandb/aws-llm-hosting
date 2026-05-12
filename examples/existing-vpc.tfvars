project_name = "llm-hosting"
environment  = "shared"
domain_name  = "llm-shared.example.com"

create_route53_zone = false
route53_zone_id     = "Z1234567890EXAMPLE"

frontend_vpc_id             = "vpc-0abc123frontend"
frontend_public_subnet_ids  = ["subnet-0a1", "subnet-0a2"]
frontend_private_subnet_ids = ["subnet-0b1", "subnet-0b2"]
frontend_route_table_ids    = ["rtb-frontend-public-a", "rtb-frontend-public-b", "rtb-frontend-private-a", "rtb-frontend-private-b"]

backend_vpc_id             = "vpc-0def456backend"
backend_private_subnet_ids = ["subnet-0c1", "subnet-0c2"]
backend_route_table_ids    = ["rtb-backend-private-a", "rtb-backend-private-b"]

assume_existing_vpc_routing = true

database_mode = "rds"

# Use these only when database_mode = "ec2_postgres".
# postgres_ec2_instance_type = "t3.small"
# postgres_ec2_volume_size   = 40

backend_ami_id        = "ami-0123456789abcdef0"
model_ebs_snapshot_id = "snap-0123456789abcdef0"

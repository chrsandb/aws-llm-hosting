locals {
  frontend_subnet_count_ok = length(var.frontend_public_subnet_ids) >= 2 && length(var.frontend_private_subnet_ids) >= 2
  backend_subnet_count_ok  = length(var.backend_private_subnet_ids) >= 2
}

resource "terraform_data" "validations" {
  lifecycle {
    precondition {
      condition     = local.frontend_subnet_count_ok
      error_message = "At least two frontend public and two frontend private subnets are required."
    }

    precondition {
      condition     = local.backend_subnet_count_ok
      error_message = "At least two backend private subnets are required."
    }

    precondition {
      condition     = var.assume_existing_vpc_routing || (length(var.frontend_route_table_ids) > 0 && length(var.backend_route_table_ids) > 0)
      error_message = "Route table IDs must be supplied unless assume_existing_vpc_routing is true."
    }
  }

  input = {
    frontend_vpc_id = var.frontend_vpc_id
    backend_vpc_id  = var.backend_vpc_id
  }
}

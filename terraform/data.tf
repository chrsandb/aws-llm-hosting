data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_subnet" "frontend_private" {
  for_each = toset(var.frontend_private_subnet_ids)
  id       = each.value
}

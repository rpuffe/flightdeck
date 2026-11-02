module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0" # v6.x line requires AWS provider >= 6.x, matching our ~> 6.0 pin

  name = "${local.name_prefix}-vpc"
  cidr = "10.20.0.0/16"

  azs             = ["${var.region}a", "${var.region}b"]
  public_subnets  = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnets = ["10.20.10.0/24", "10.20.11.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  # No NAT (spec §10, 2026-11-01): app tasks run in the public subnets with
  # a per-task public IPv4 and egress through the internet gateway. The
  # private subnets are kept, unused and free, so an app still pinned to a
  # pre-v0.11 module fails on egress rather than on a missing output.
  enable_nat_gateway = false
}

output "vpc_id" {
  description = "ID of the flightdeck VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the flightdeck VPC"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (no egress route; unused since app tasks moved to the public subnets)"
  value       = module.vpc.private_subnets
}

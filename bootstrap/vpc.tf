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

  # NAT is provided by the fck-nat instance below, not managed NAT gateways.
  enable_nat_gateway = false
}

# Deliberate tradeoff (spec §5): a single fck-nat instance, no HA. A t4g.nano
# NAT instance costs ~$3/mo vs ~$32/mo + data processing for a managed NAT
# gateway; if its AZ fails, private-subnet egress is down until it's replaced.
# Cost over availability — acceptable for a personal platform.
module "fck_nat" {
  source  = "RaJiska/fck-nat/aws"
  version = "~> 1.4" # >= 1.4 requires AWS provider >= 6.0

  name      = "${local.name_prefix}-fck-nat"
  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.public_subnets[0]

  instance_type = "t4g.nano"
  ha_mode       = false # single instance, no autoscaling group

  # Point every private route table's 0.0.0.0/0 at the NAT instance.
  update_route_tables = true
  route_tables_ids = {
    for idx, rt_id in module.vpc.private_route_table_ids : "private-${idx}" => rt_id
  }
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
  description = "IDs of the private subnets"
  value       = module.vpc.private_subnets
}

# Two configurations of the same AWS provider. The default one uses your main
# region. The aliased one is pinned to us-east-1, where CloudFront keeps its
# certificates, metrics and the domain registration API. Modules receive both.
locals {
  tags = {
    Project     = var.project_name
    Environment = var.environment
    Stack       = "live"
    ManagedBy   = "terraform"
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}

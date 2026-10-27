# -----------------------------------------------------------------------------
# The live stack: everything that serves the website. CI runs `plan` on it for
# every pull request and `apply` after every merge to main.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State lives in the S3 bucket created by infra/bootstrap. The bucket name
  # is not written here because it has a random suffix. It is passed in at
  # init time ("partial configuration"):
  #   terraform init -backend-config="bucket=<state bucket>" -backend-config="region=<region>"
  # The Makefile and the workflows do this for you.
  # Docs: https://developer.hashicorp.com/terraform/language/backend#partial-configuration
  backend "s3" {
    key          = "live/terraform.tfstate"
    use_lockfile = true # S3-native locking (Terraform 1.10+), no DynamoDB table needed
    encrypt      = true
  }
}

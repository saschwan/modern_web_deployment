# -----------------------------------------------------------------------------
# providers.tf: how the providers authenticate and where they point.
#
# Neither block contains credentials. Terraform reads them from your shell:
#   AWS:    `aws configure` / AWS_PROFILE / AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY
#   GitHub: the GITHUB_TOKEN environment variable (a fine-grained token)
# Keeping credentials out of .tf files is what lets this repo be shared safely.
#
# Docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration
#       https://registry.terraform.io/providers/integrations/github/latest/docs#authentication
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  # Every AWS resource created by this provider gets these tags automatically.
  # Tags make resources easy to find in the console and let you filter costs
  # by project in Cost Explorer.
  default_tags {
    tags = {
      Project   = var.project_name
      Stack     = "bootstrap"
      ManagedBy = "terraform"
    }
  }
}

provider "github" {
  owner = var.github_owner
}

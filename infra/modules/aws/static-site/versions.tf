# A module declares which providers it needs, but never configures them.
# The caller (infra/live) passes configured providers in. `configuration_aliases`
# says this module also expects a second AWS provider pinned to us-east-1,
# because CloudFront certificates and domain registration only exist there.
# Docs: https://developer.hashicorp.com/terraform/language/modules/develop/providers
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

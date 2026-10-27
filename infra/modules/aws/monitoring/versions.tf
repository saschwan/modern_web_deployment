# CloudFront publishes its metrics only in us-east-1, so alarms on them (and
# the SNS topic the alarms notify) must be created there too.
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

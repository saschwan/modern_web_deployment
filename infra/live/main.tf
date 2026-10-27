# -----------------------------------------------------------------------------
# The live stack composes modules. Each module block is like a function call:
# it passes inputs (variables) to a folder of .tf files and receives outputs.
# Changing this file (or terraform.tfvars) and opening a PR is how you change
# what runs in AWS. See docs/02-making-changes.md for worked examples.
# -----------------------------------------------------------------------------
locals {
  name = "${var.project_name}-${var.environment}"
}

module "static_site" {
  # To move to another cloud you would point this at a module with the same
  # inputs and outputs, e.g. ../modules/gcp/static-site (docs/03-switching-clouds.md).
  source = "../modules/aws/static-site"

  # Hand the module both provider configurations (default and us-east-1).
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name            = local.name
  domain_name     = var.domain_name
  register_domain = var.register_domain
  domain_contact  = var.domain_contact
  price_class     = var.cdn_price_class
}

module "monitoring" {
  source = "../modules/aws/monitoring"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name               = local.name
  cdn_id             = module.static_site.cdn_id # output of one module feeds the next
  alert_emails       = var.alert_emails
  monthly_budget_usd = var.monthly_budget_usd
}

# Future phases plug in here, e.g.:
# module "network"   { source = "../modules/aws/network" ... }
# module "webserver" { source = "../modules/aws/webserver" ... }
# module "database"  { source = "../modules/aws/database" ... }

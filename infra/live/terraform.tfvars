# -----------------------------------------------------------------------------
# Settings of the live site. This file is committed: change a value, open a
# pull request, read the plan that CI posts, merge, and CI applies it.
# Terraform loads terraform.tfvars automatically.
# Never put secrets here (domain contact details come from a GitHub secret).
# -----------------------------------------------------------------------------
project_name = "modern-web"
environment  = "prod"
aws_region   = "eu-central-1" # must match aws_region in infra/bootstrap

# Custom domain (leave empty to use the free https://xxxx.cloudfront.net address).
# To buy one, set both lines below. That costs money and cannot be undone.
domain_name     = ""
register_domain = false

# Cheapest edge locations (North America and Europe).
cdn_price_class = "PriceClass_100"

# Cost overview. Add your address to receive budget and alarm emails, e.g.
# alert_emails = ["you@example.com"]
alert_emails       = []
monthly_budget_usd = 5

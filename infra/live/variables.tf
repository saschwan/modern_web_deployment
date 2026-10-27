variable "project_name" {
  description = "Short lowercase project name, used in resource names and the Project tag."
  type        = string
}

variable "environment" {
  description = "Environment name. A second environment (e.g. dev) would be a copy of this stack with another value."
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "Main AWS region for regional resources such as S3."
  type        = string
}

variable "domain_name" {
  description = "Custom domain. Empty string means the site uses its *.cloudfront.net address."
  type        = string
  default     = ""
}

variable "register_domain" {
  description = "Let Terraform buy domain_name. Costs money and cannot be refunded."
  type        = bool
  default     = false
}

variable "domain_contact" {
  description = "Registrant contact. Comes from the TF_VAR_DOMAIN_CONTACT GitHub secret in CI."
  type = object({
    first_name     = string
    last_name      = string
    email          = string
    phone_number   = string
    address_line_1 = string
    city           = string
    zip_code       = string
    country_code   = string
  })
  default   = null
  sensitive = true

  validation {
    condition     = !var.register_domain || var.domain_contact != null
    error_message = "register_domain = true needs domain_contact (set it in infra/bootstrap and re-run the bootstrap)."
  }
}

variable "cdn_price_class" {
  type    = string
  default = "PriceClass_100"
}

variable "alert_emails" {
  description = "Who gets alarm and budget emails. Empty list disables all emails."
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  type    = number
  default = 5
}

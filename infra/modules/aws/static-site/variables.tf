# -----------------------------------------------------------------------------
# The module's inputs. Together with outputs.tf this is the module's "contract":
# the live stack only knows these names, not how the module works inside.
# A GCP or Azure version of this module would keep the same inputs and
# outputs (see docs/03-switching-clouds.md).
# -----------------------------------------------------------------------------
variable "name" {
  description = "Prefix for resource names, e.g. modern-web-prod."
  type        = string
}

variable "domain_name" {
  description = "Custom domain such as example.com. Empty means: use the free *.cloudfront.net address."
  type        = string
  default     = ""
}

variable "register_domain" {
  description = <<-EOT
    true: Terraform registers domain_name through Route 53 Domains (costs money,
    about 15 USD a year for .com, not refundable).
    false: the domain is already registered and has a Route 53 hosted zone.
  EOT
  type        = bool
  default     = false
}

variable "domain_contact" {
  description = "Registrant contact, required when register_domain is true."
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
}

variable "price_class" {
  description = <<-EOT
    Which CloudFront edge locations serve the site. PriceClass_100 (North
    America and Europe) is the cheapest. PriceClass_All is fastest worldwide.
  EOT
  type        = string
  default     = "PriceClass_100"
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete the bucket even when it still contains files."
  type        = bool
  default     = true # fine for a hobby site whose content lives in git anyway
}

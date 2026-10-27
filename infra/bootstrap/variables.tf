# -----------------------------------------------------------------------------
# variables.tf: the inputs of this stack.
#
# Variables are how the same code is reused with different values. You set them
# in terraform.tfvars (copy terraform.tfvars.example), with -var on the command
# line, or with TF_VAR_<name> environment variables.
#
# Docs: https://developer.hashicorp.com/terraform/language/values/variables
# -----------------------------------------------------------------------------
variable "project_name" {
  description = "Short lowercase name used to name and tag every resource."
  type        = string
  default     = "modern-web"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,20}$", var.project_name))
    error_message = "Use 3 to 20 lowercase letters, digits or dashes (it ends up in S3 bucket names)."
  }
}

variable "aws_region" {
  description = "Main AWS region. CloudFront is global, so this mainly decides where S3 buckets live."
  type        = string
  default     = "eu-central-1" # Frankfurt. eu-central-2 is Zurich.
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository."
  type        = string
  default     = "saschwan"
}

variable "github_repository" {
  description = "Repository name (without owner)."
  type        = string
  default     = "modern_web_deployment"
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    An AWS account can hold only one OIDC provider for GitHub. Set this to false
    if your account already has one (IAM > Identity providers >
    token.actions.githubusercontent.com); Terraform will then look it up instead.
  EOT
  type        = bool
  default     = true
}

variable "enable_branch_protection" {
  description = <<-EOT
    Require the CI checks to pass before anything merges into main. GitHub only
    offers branch protection on private repositories with a paid plan (Pro,
    Team). On GitHub Free, make the repo public or set this to false.
  EOT
  type        = bool
  default     = true
}

variable "domain_contact" {
  description = <<-EOT
    Contact details required by domain registries. Only needed if you register
    a domain in the live stack. Stored as a GitHub Actions secret so it is never
    committed. Leave as null for now.
  EOT
  type = object({
    first_name     = string
    last_name      = string
    email          = string
    phone_number   = string # format +41.791234567
    address_line_1 = string
    city           = string
    zip_code       = string
    country_code   = string # two letters, e.g. CH
  })
  default   = null
  sensitive = true
}

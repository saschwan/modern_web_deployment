# -----------------------------------------------------------------------------
# versions.tf: which Terraform and which providers this stack needs.
#
# A "provider" is a plugin that translates Terraform resources into API calls.
# This stack uses two: AWS (to create the state bucket and the CI role) and
# GitHub (to configure the repository's Actions variables and branch rules).
# `terraform init` downloads them and records the exact versions in
# .terraform.lock.hcl, which you commit so everyone gets the same versions.
#
# Docs: https://developer.hashicorp.com/terraform/language/providers/requirements
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # any 6.x, but not 7.0 (which may contain breaking changes)
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # No `backend` block here on purpose. The bootstrap stack creates the S3 bucket
  # that will hold remote state, so it cannot store its own state there before
  # the bucket exists (chicken and egg). Its state stays in a local
  # terraform.tfstate file, which is gitignored. Keep that file safe, or see
  # docs/00-getting-started.md for how to migrate it into the bucket afterwards.
}

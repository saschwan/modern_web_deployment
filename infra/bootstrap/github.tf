# -----------------------------------------------------------------------------
# Bootstrap stack, GitHub side.
#
# Terraform is not only for clouds: any API with a provider can be managed.
# Here it writes the values the workflows need (role ARNs, state bucket) into
# the repository's Actions variables, and makes the CI checks mandatory.
# Docs: https://registry.terraform.io/providers/integrations/github/latest/docs
# -----------------------------------------------------------------------------

# The repository already exists (you created it), so we only read it.
data "github_repository" "this" {
  full_name = local.repo_full_name
}

locals {
  # Non-secret values for the workflows. They appear under
  # Settings > Secrets and variables > Actions > Variables and are read in
  # workflow files as ${{ vars.NAME }}.
  actions_variables = {
    AWS_REGION          = var.aws_region
    AWS_PLAN_ROLE_ARN   = aws_iam_role.plan.arn
    AWS_DEPLOY_ROLE_ARN = aws_iam_role.deploy.arn
    TF_STATE_BUCKET     = aws_s3_bucket.state.bucket
  }
}

# `for_each` creates one resource per map entry. Adding a key to the map above
# makes the next plan show exactly one new variable to create.
resource "github_actions_variable" "this" {
  for_each = local.actions_variables

  repository    = var.github_repository
  variable_name = each.key
  value         = each.value
}

# Domain contact details are personal data, so they go into a secret
# (encrypted, never shown again). The deploy workflow exposes it to Terraform
# as TF_VAR_domain_contact, which fills the live stack's variable of that name.
resource "github_actions_secret" "domain_contact" {
  # nonsensitive() is needed because count may not depend on a secret value.
  # Only the null check leaks, not the contents.
  count = nonsensitive(var.domain_contact != null) ? 1 : 0

  repository      = var.github_repository
  secret_name     = "TF_VAR_DOMAIN_CONTACT"
  plaintext_value = jsonencode(var.domain_contact)
}

# Makes tests mandatory: nothing reaches main unless the PR checks pass.
# The check names must match the job names in .github/workflows/ci.yml.
resource "github_branch_protection" "main" {
  count = var.enable_branch_protection ? 1 : 0

  repository_id  = data.github_repository.this.node_id
  pattern        = "main"
  enforce_admins = true # applies to you as the owner, too

  required_status_checks {
    strict   = true # the PR branch must be up to date with main before merging
    contexts = ["test", "terraform"]
  }

  # A pull request is required, but no approving review, since you work alone.
  required_pull_request_reviews {
    required_approving_review_count = 0
  }
}

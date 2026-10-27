# -----------------------------------------------------------------------------
# Bootstrap stack, AWS side. Run once from your machine with admin credentials.
#
# It creates the things every later step depends on:
#   1. An S3 bucket that stores the *live* stack's Terraform state.
#   2. Trust between GitHub Actions and AWS (OIDC), so CI never needs a
#      long-lived AWS access key.
#   3. Two IAM roles that CI assumes: a read-only "plan" role for pull requests
#      and a "deploy" role for the main branch.
#
# Reading tip: each `resource "TYPE" "NAME"` block is one real object in AWS.
# TYPE comes from the provider (look it up in the registry docs), NAME is only
# used inside Terraform to refer to it, e.g. aws_s3_bucket.state.arn.
# -----------------------------------------------------------------------------

# Data sources read existing information instead of creating anything.
# This one returns the account ID of the credentials you are using.
data "aws_caller_identity" "current" {}

locals {
  repo_full_name = "${var.github_owner}/${var.github_repository}"

  # GitHub puts the repository into the token's `sub` claim in one of two
  # formats. Newer repositories use "immutable subjects" that include the
  # numeric IDs, so a renamed or re-created repo cannot inherit the trust:
  #   legacy:    repo:saschwan/modern_web_deployment:ref:refs/heads/main
  #   immutable: repo:saschwan@5630718/modern_web_deployment@1435655998:ref:refs/heads/main
  # Check yours with: gh api repos/OWNER/REPO/actions/oidc/customization/sub
  # Both are accepted here; the IDs are looked up in github.tf.
  oidc_subject_prefixes = [
    "repo:${local.repo_full_name}",
    "repo:${var.github_owner}@${data.github_user.owner.id}/${var.github_repository}@${data.github_repository.this.repo_id}",
  ]
}

# --- 1. Remote state bucket ---------------------------------------------------
# Terraform remembers what it created in a "state" file. Storing it in S3 means
# your laptop and GitHub Actions share the same memory of the infrastructure.
# Docs: https://developer.hashicorp.com/terraform/language/backend/s3

resource "aws_s3_bucket" "state" {
  # bucket_prefix lets AWS add a random suffix, because bucket names are
  # globally unique across all AWS customers.
  bucket_prefix = "${var.project_name}-tfstate-"

  # A lifecycle meta-argument. Terraform will refuse any plan that would delete
  # this bucket, since losing state means Terraform forgets your infrastructure.
  lifecycle {
    prevent_destroy = true
  }
}

# Versioning keeps every previous state file, so a broken state can be rolled back.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id # a reference: creates an implicit dependency
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Old state versions are only needed for a while. Expire them after 90 days.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# --- 2. GitHub OIDC trust -----------------------------------------------------
# GitHub Actions can issue a short-lived signed token (OIDC) that says "I am a
# workflow in repo X on branch Y". AWS checks the signature and hands out
# temporary credentials for a role. No secret keys are stored anywhere.
# Docs: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services

resource "aws_iam_openid_connect_provider" "github" {
  # `count` turns a resource on or off: 1 creates it, 0 skips it.
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  # Whichever of the two above exists. [0] picks the single element that `count` created.
  oidc_provider_arn = (var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
  : data.aws_iam_openid_connect_provider.github[0].arn)
}

# --- 3. IAM roles for CI ------------------------------------------------------
# A trust policy says *who* may assume a role. The `sub` claim of GitHub's
# token encodes where the workflow runs, so each role only trusts one context.
# Note: if a job uses `environment:`, its sub claim becomes
# "repo:OWNER/REPO:environment:NAME" and these conditions must change too.
# Claim formats: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect#example-subject-claims

data "aws_iam_policy_document" "trust_pull_requests" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for p in local.oidc_subject_prefixes : "${p}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "trust_main_branch" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for p in local.oidc_subject_prefixes : "${p}:ref:refs/heads/main"]
    }
  }
}

# Both roles need to read and write the state file and its lock file
# (`use_lockfile` creates a small .tflock object next to the state while a
# plan or apply runs, so two runs never change infrastructure at the same time).
data "aws_iam_policy_document" "state_access" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }
  statement {
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }
}

# "plan" role: used on pull requests. It can look at everything but change
# nothing (except the lock file), so a PR can never modify the live site.
resource "aws_iam_role" "plan" {
  name               = "${var.project_name}-github-plan"
  assume_role_policy = data.aws_iam_policy_document.trust_pull_requests.json
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_access.json
}

# "deploy" role: used after a merge to main to run `terraform apply` and
# upload the site. PowerUserAccess allows every service except IAM user and
# account management. That is enough for S3 + CloudFront + CloudWatch.
# Once the webserver phases need IAM roles for EC2, add a scoped IAM policy
# here (see docs/04-webserver-roadmap.md, phase 2).
resource "aws_iam_role" "deploy" {
  name               = "${var.project_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.trust_main_branch.json
}

resource "aws_iam_role_policy_attachment" "deploy_poweruser" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

resource "aws_iam_role_policy" "deploy_state" {
  name   = "terraform-state"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.state_access.json
}

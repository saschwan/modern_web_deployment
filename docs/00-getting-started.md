# 0. Getting started

This page takes you from an empty AWS account to a live hello-world page.
Plan for 30 minutes the first time.

## What you need

| Tool | Why | Install |
| --- | --- | --- |
| Terraform 1.10 or newer | runs the `.tf` files | https://developer.hashicorp.com/terraform/install |
| AWS CLI v2 | logs you in to AWS, uploads files | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Node.js 22 | runs the site tests | https://nodejs.org |
| make | optional shortcuts (`make help`) | preinstalled on macOS/Linux |

## 1. AWS credentials (your machine only)

The bootstrap creates IAM roles, so it needs an identity with administrator
rights. Do not use the account's root user for daily work. The modern way is
IAM Identity Center (SSO):

```bash
aws configure sso          # follow the prompts, pick AdministratorAccess
export AWS_PROFILE=<the profile name you chose>
aws sts get-caller-identity # should print your account ID
```

An IAM user with an access key also works (`aws configure`), but delete the
key once the bootstrap is done. After that, CI never uses stored keys: it logs
in through OIDC with short-lived credentials.

## 2. GitHub token

Create a **fine-grained personal access token** at
https://github.com/settings/personal-access-tokens/new

- Repository access: only `saschwan/modern_web_deployment`
- Permissions (Repository): **Administration** read/write (branch protection),
  **Secrets** read/write, **Variables** read/write, **Metadata** read

```bash
export GITHUB_TOKEN=github_pat_...
```

## 3. Run the bootstrap

```bash
cp infra/bootstrap/terraform.tfvars.example infra/bootstrap/terraform.tfvars
# edit if needed, then:
make bootstrap
```

Terraform prints a plan (around 20 resources to add) and asks for `yes`.
Read the plan before you type it: that habit is the most important one in
Terraform. Things that can go wrong:

- **"EntityAlreadyExists: Provider with url https://token.actions.githubusercontent.com"**:
  your account already trusts GitHub. Set `create_github_oidc_provider = false`.
- **Branch protection "Upgrade to GitHub Pro"**: private repos on GitHub Free
  have no branch protection. Set `enable_branch_protection = false` or make the
  repo public.

The bootstrap state is a local file, `infra/bootstrap/terraform.tfstate`. Back
it up (or move it into the state bucket, see the end of this page).

## 4. First deploy

Open the repository's **Actions** tab, choose **Deploy**, then **Run workflow**.
After 3 to 5 minutes (CloudFront takes a while the first time) the run
summary shows `Deployed to https://dxxxxxxxx.cloudfront.net`. Open it.

From now on, every merge to main deploys automatically.

## 5. Your daily loop

```bash
git switch -c my-change
# edit site/ or infra/
npm test           # same tests as CI
make fmt           # format Terraform
git push -u origin my-change
```

Open a pull request. CI runs the tests and posts the Terraform plan as a
comment. Merge when both checks are green.

## 6. See costs and health

- CloudWatch dashboard: the link is printed by `terraform output dashboard_url`
  (run `make init` first).
- Billing: enable **Billing preferences > Receive CloudWatch billing alerts**
  once in the console so the dashboard's cost widget shows data.
- Emails: add your address to `alert_emails` in `infra/live/terraform.tfvars`,
  merge, and confirm the subscription email from AWS.

## 7. Tear everything down

```bash
make destroy                               # removes the live site
terraform -chdir=infra/bootstrap destroy   # fails on purpose: the state bucket has prevent_destroy
```

To remove the bootstrap too, delete the `prevent_destroy` block in
`infra/bootstrap/main.tf`, empty the bucket, then run the destroy again.

## Troubleshooting

### "Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity"

The workflow reached AWS, but the role's trust policy did not match the
token GitHub sent. Compare the two:

```bash
# What the role expects
aws iam get-role --role-name modern-web-github-deploy \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'

# How GitHub writes the subject for this repo
gh api repos/saschwan/modern_web_deployment/actions/oidc/customization/sub
```

| Cause | Fix |
| --- | --- |
| The repo uses **immutable subjects** (`use_immutable_subject: true`, IDs in the subject). | Already handled: the trust policies accept both formats. If you see this on an old bootstrap, re-run `make bootstrap`. |
| The repo was **renamed, moved or re-created**. The IDs or name changed. | Update `github_owner` / `github_repository` if needed and re-run `make bootstrap`. |
| A **custom subject template** (`use_default: false`). | Make the `values` in the `trust_*` policy documents in `infra/bootstrap/main.tf` match the template, then re-run `make bootstrap`. |
| A job uses `environment:`. Its subject then ends in `:environment:NAME`. | Add that subject to the trust policy, or remove `environment:` from the job. |
| You used `create_github_oidc_provider = false` and the existing provider has no `sts.amazonaws.com` audience. | Add the audience in IAM > Identity providers, or let the bootstrap create the provider. |

Use the `plan` role name (`modern-web-github-plan`) for failures on pull
requests, and the `deploy` role for failures on main.

### A pull request that changes `infra/bootstrap/` fails its own checks

CI never applies the bootstrap; only you do, locally. So when a PR changes
the bootstrap (for example the trust policies above), CI still runs against
the old version and can fail. Because branch protection requires the checks,
the PR cannot merge either. The way out is to apply the bootstrap from the
PR branch first:

```bash
git fetch origin && git switch <pr-branch>
make bootstrap        # read the plan: it should only touch what the PR changes
```

Then re-run the failed check on the PR and merge. Afterwards, `git switch main
&& git pull` so your local copy matches what you applied.

### "startup_failure" with no jobs

GitHub could not start the workflow at all, so the code was never read.
Open the failed run in the Actions tab for the reason. Typical causes:
Actions disabled for the repo, or a billing or spending-limit lock on private
repo minutes. Runs that fail this way cannot be re-run. Use **Run workflow**
on the CI or Deploy workflow, or push a new commit.

### The plan step is skipped on pull requests

The AWS steps only run once the bootstrap has written the repository
variables (`AWS_PLAN_ROLE_ARN` and others). Check them under Settings >
Secrets and variables > Actions > Variables, and re-run `make bootstrap` if
they are missing.

## Optional: move the bootstrap state into S3

Once the bucket exists, add this to `infra/bootstrap/versions.tf` inside the
`terraform {}` block and run `terraform -chdir=infra/bootstrap init -migrate-state`:

```hcl
backend "s3" {
  bucket       = "<state bucket from `terraform output state_bucket`>"
  key          = "bootstrap/terraform.tfstate"
  region       = "eu-central-1"
  use_lockfile = true
}
```

## Optional: commit provider lock files

`terraform init` writes `.terraform.lock.hcl`, which pins the exact provider
versions. Run `make lock` once and commit both lock files so your laptop and
CI always use identical providers.

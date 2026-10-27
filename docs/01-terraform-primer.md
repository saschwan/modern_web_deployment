# 1. Terraform primer, using this repository

This page explains Terraform at three zoom levels: what it does for the
project as a whole (macro), how the pieces of this repo relate (mid), and what
single lines in the files mean (micro). Have the `infra/` folder open while
you read.

---

## Macro: what Terraform is for

Without Terraform you would build this site by clicking through the AWS
console: create a bucket, create a CloudFront distribution, copy an ID from
one screen into another, set a policy. That works once, but nobody can review
it, repeat it or undo it reliably.

Terraform turns the infrastructure into **code that describes the desired
end state**:

> "There is a private S3 bucket. There is a CloudFront distribution that reads
> from it. There is an alarm on the distribution's error rate."

You never write *how* to create these things, in which order, or what to do if
some of them already exist. Terraform works that out by comparing three things:

```
   your .tf files          the state file              the real cloud
  (what you want)   vs  (what Terraform built)   vs   (what exists now)
          \                     |                        /
           \____________ terraform plan ________________/
                                |
                  "+ create 3, ~ update 1, - destroy 0"
                                |
                         terraform apply
                     (calls the AWS APIs)
```

This is called **declarative** infrastructure. The consequences are what make
it powerful:

- **Reviewable:** a change to the infrastructure is a diff in a pull request,
  and CI shows the plan before anything happens.
- **Repeatable:** the same code builds a second environment (dev, staging) or
  rebuilds after a disaster.
- **Reversible:** removing a block and applying deletes exactly what that
  block created, nothing else.
- **Portable knowledge:** the same workflow works for AWS, GCP, Azure,
  Cloudflare, GitHub and thousands of other APIs, because each is just a
  *provider*.

### Where the line is: what Terraform does *not* do here

Terraform manages **long-lived infrastructure**. It does not upload the site's
HTML files, even though it could (`aws_s3_object` with `for_each`). Content
changes on every commit and can be thousands of files. Putting every file into
Terraform state would make plans slow and noisy. So the split is:

| Job | Tool | Where |
| --- | --- | --- |
| Create and configure bucket, CDN, alarms, budget, roles | Terraform | `infra/` |
| Upload site files, clear CDN cache | AWS CLI | `deploy.yml` |
| Run tests, decide *when* to apply | GitHub Actions | `.github/workflows/` |
| Configure GitHub itself (variables, branch rules) | Terraform (GitHub provider) | `infra/bootstrap/github.tf` |

The same split will apply later: Terraform creates the EC2 instance and the
database; the application code and the database tables are deployed by CI.

---

## Mid level: how this repo is organised

### Two stacks

A **stack** (also "root module") is a folder you run `terraform` in. It has
its own state. This repo has two:

```
infra/bootstrap   run once, from your laptop, with admin rights
   creates  ->  S3 state bucket, GitHub OIDC trust, 2 IAM roles,
                GitHub Actions variables, branch protection
   state    ->  local file (it cannot live in the bucket it creates)

infra/live        run by CI on every PR (plan) and merge (apply)
   creates  ->  site bucket, CloudFront, dashboard, alarm, budget, (domain)
   state    ->  s3://<state bucket>/live/terraform.tfstate
```

Why split? Different **lifecycles** and **permissions**. The bootstrap
changes almost never and needs IAM rights. The live stack changes all the
time and should run with less power. A mistake in the live stack cannot delete
the roles that CI needs to fix the mistake.

### Modules

`infra/live/main.tf` is short because the work happens in **modules**:

```hcl
module "static_site" {
  source      = "../modules/aws/static-site"
  name        = local.name
  domain_name = var.domain_name
}
```

A module is a folder of `.tf` files with inputs (`variables.tf`) and outputs
(`outputs.tf`). Think of it as a function:

```
static_site(name, domain_name, ...) -> { site_url, content_bucket, cdn_id }
```

The live stack chains them: `module.static_site.cdn_id` goes into the
monitoring module. Terraform sees that reference and knows it must create the
CDN before the alarm that watches it.

Modules are also the key to multi-cloud: a `modules/gcp/static-site` with the
**same inputs and outputs** can replace the AWS one without changing the rest
(see [03-switching-clouds.md](03-switching-clouds.md)).

### File naming

Terraform reads **all** `.tf` files in a folder as one configuration; file
names are only for humans. The convention used here:

| File | Contains |
| --- | --- |
| `versions.tf` | required Terraform version, providers, backend |
| `providers.tf` | provider configuration (region, default tags) |
| `variables.tf` | inputs |
| `main.tf` | resources |
| `outputs.tf` | outputs |
| `terraform.tfvars` | values for the inputs (auto-loaded) |

### State, remote backend and locking

The **state** (`terraform.tfstate`) is a JSON file that maps each block in
your code to a real object ID, e.g. `module.static_site.aws_s3_bucket.site`
-> `modern-web-prod-site-20261027abc`. Without it Terraform would not know
that the bucket already exists and would try to create a second one.

- It is stored in S3 (`backend "s3"` in `infra/live/versions.tf`) so CI and
  your laptop share it.
- `use_lockfile = true` writes a lock object during each run, so two runs can
  never change infrastructure at the same time.
- Versioning on the bucket keeps every previous state.
- State can contain secrets. That is why `*.tfstate` is in `.gitignore`.

### The command lifecycle

| Command | What happens | Touches the cloud? |
| --- | --- | --- |
| `terraform init` | downloads providers and modules, connects to the backend | reads state only |
| `terraform fmt` | rewrites files in canonical style | no |
| `terraform validate` | checks syntax and types | no |
| `terraform plan` | refreshes state from real APIs, prints the diff | reads only |
| `terraform apply` | plans again, asks, then calls create/update/delete APIs | **yes** |
| `terraform destroy` | plans the deletion of everything in state | **yes** |
| `terraform output` | prints outputs from state | no |
| `terraform state list` | lists everything Terraform manages | no |

CI runs `fmt`, `validate` and `plan` on pull requests, and `apply` on main.

### Authentication without secrets (OIDC)

```
GitHub Actions job ---(1) "give me a token for this job"---> GitHub OIDC
                  <--(2) signed JWT: sub=repo:saschwan/modern_web_deployment:pull_request
                  ---(3) AssumeRoleWithWebIdentity(role, JWT)---> AWS STS
AWS STS checks the signature against the OIDC provider in IAM, and checks
the role's trust policy (sub must match)
                  <--(4) credentials valid for 1 hour
```

Newer repositories use **immutable subjects** with numeric IDs instead
(`repo:saschwan@5630718/modern_web_deployment@1435655998:pull_request`), so a
deleted and re-created repo with the same name cannot reuse the trust. The
bootstrap accepts both formats.

That is what `aws_iam_openid_connect_provider` and the two `trust_*` policy
documents in `infra/bootstrap/main.tf` set up. A pull request gets the
read-only role, so a PR can never change the live site. Only `main` gets the
deploy role.

---

## Micro level: reading single lines

Take this block from `infra/modules/aws/static-site/main.tf`:

```hcl
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.site]
}
```

| Piece | Meaning |
| --- | --- |
| `resource` | "this should exist". The other top-level kinds are `data` (read something), `variable`, `output`, `locals`, `module`. |
| `"aws_s3_bucket_policy"` | the resource **type**. The prefix `aws_` picks the provider. Every type has a docs page: search the registry for it. |
| `"site"` | the local **name**. Together: address `aws_s3_bucket_policy.site`. Inside a module the full address is `module.static_site.aws_s3_bucket_policy.site`. |
| `bucket = ...` | an **argument**. The docs page lists which are required. |
| `aws_s3_bucket.site.id` | a **reference** to another resource's attribute. It creates an implicit dependency (bucket first, policy second) and the value is only known after the bucket exists ("known after apply" in plans). |
| `data.aws_iam_policy_document...json` | a data source that builds JSON from HCL, so you never write IAM JSON by hand. |
| `depends_on` | an **explicit** dependency for cases Terraform cannot infer from references. Rarely needed. |

What `apply` does for this block: one `PutBucketPolicy` API call to S3. If
you later change the policy, the plan shows `~ update in-place` and apply
calls `PutBucketPolicy` again. If you delete the block, apply calls
`DeleteBucketPolicy`.

### Meta-arguments used in this repo

| Meta-argument | Example | What it does |
| --- | --- | --- |
| `count` | `count = local.use_domain ? 1 : 0` | creates N copies; 0 turns a resource off. Addressed as `x[0]`. |
| `for_each` | `for_each = toset(var.alert_emails)` | one copy per map key / set element. Addressed as `x["key"]`. Better than `count` for lists, because removing one item does not renumber the rest. |
| `provider` | `provider = aws.us_east_1` | use a non-default provider configuration (here: another region). |
| `lifecycle { prevent_destroy = true }` | state bucket, domain | any plan that would delete it fails. |
| `lifecycle { create_before_destroy = true }` | certificate | when a replacement is needed, build the new one before deleting the old. |
| `depends_on` | bucket policy | explicit ordering. |

### Expressions you will meet

```hcl
"${var.project_name}-${var.environment}"         # string interpolation
var.domain_name != "" ? "https://..." : "..."    # conditional
[for r in aws_route53_record.x : r.fqdn]         # list comprehension
{ for o in list : o.domain_name => o }           # map comprehension
jsonencode({ widgets = [...] })                  # HCL object -> JSON string
file("${path.module}/index-rewrite.js")          # read a file next to the module
dynamic "notification" { for_each = ... }        # generate nested blocks
```

Reference for all built-in functions:
https://developer.hashicorp.com/terraform/language/functions

### Reading a plan

```
  # module.static_site.aws_cloudfront_distribution.this will be updated in-place
  ~ resource "aws_cloudfront_distribution" "this" {
        id          = "E2ABC123"
      ~ price_class = "PriceClass_100" -> "PriceClass_All"
    }

  # module.monitoring.aws_sns_topic_subscription.email["me@example.com"] will be created
  + resource "aws_sns_topic_subscription" "email" { ... }

  # module.static_site.aws_s3_bucket.site must be replaced
-/+ resource "aws_s3_bucket" "site" {
      ~ bucket_prefix = "modern-web-prod-site-" -> "modern-web-dev-site-" # forces replacement
    }

Plan: 2 to add, 1 to change, 1 to destroy.
```

| Symbol | Meaning | Risk |
| --- | --- | --- |
| `+` | create | low |
| `~` | update in place (same object, new settings) | low to medium |
| `-/+` or `+/-` | **replace**: delete and recreate (some settings cannot change on a live object) | high: new IDs, possible downtime or data loss |
| `-` | destroy | high |
| `<=` | read a data source | none |

Always look for `forces replacement` and `destroy` before merging.

## Where to look things up

- Terraform language: https://developer.hashicorp.com/terraform/language
- AWS provider resources: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
- GitHub provider resources: https://registry.terraform.io/providers/integrations/github/latest/docs
- Tutorials (free, good next step): https://developer.hashicorp.com/terraform/tutorials/aws-get-started

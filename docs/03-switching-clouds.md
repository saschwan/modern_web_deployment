# 3. Switching clouds: what changes in the Terraform files

## The honest answer first

Terraform is **multi-cloud, not cloud-agnostic**. The language, the workflow
(`init`/`plan`/`apply`), state, modules and CI stay the same on every cloud.
The **resources do not**: `aws_cloudfront_distribution` has no GCP twin with
the same arguments. Each cloud has its own building blocks, prices and limits.

So "generalised to all clouds" is achieved by **architecture**, not by magic:

1. Each capability (static site, webserver, database, auth) is a **module**
   with a fixed contract: the same input variables and output names.
2. There is one implementation per cloud: `modules/aws/static-site`,
   `modules/gcp/static-site`, `modules/azure/static-site`.
3. The live stack picks one. Everything around it (tfvars, CI, tests,
   site content) keeps working because it only uses the contract.

```
infra/modules/
  aws/static-site     <- exists
  gcp/static-site     <- sketch below
  azure/static-site   <- sketch below
```

## The static-site contract

| | Name | Meaning |
| --- | --- | --- |
| input | `name` | prefix for resource names |
| input | `domain_name` | custom domain or `""` |
| output | `site_url` | public URL |
| output | `content_bucket` | where CI uploads `site/` |
| output | `cdn_id` | what CI uses to clear the cache |

## What changes, file by file

| Concern | AWS (today) | Google Cloud | Azure |
| --- | --- | --- | --- |
| Provider | `hashicorp/aws` | `hashicorp/google` | `hashicorp/azurerm` |
| State backend | `backend "s3"` | `backend "gcs"` | `backend "azurerm"` |
| CI login (no keys) | GitHub OIDC -> IAM role | GitHub OIDC -> Workload Identity Federation | GitHub OIDC -> federated credential on an Entra app |
| Login action | `aws-actions/configure-aws-credentials` | `google-github-actions/auth` | `azure/login` |
| File storage | S3 bucket | Cloud Storage bucket | Storage account (blob) |
| CDN | CloudFront | Cloud CDN behind a global load balancer | Front Door (or Static Web Apps) |
| TLS certificate | ACM (us-east-1) | Google-managed certificate | managed by Front Door / Static Web Apps |
| DNS | Route 53 | Cloud DNS | Azure DNS |
| Domain purchase | Route 53 Domains | Cloud Domains (being retired; buy elsewhere) | App Service Domains (not in Terraform) |
| Upload command | `aws s3 sync` | `gcloud storage rsync` | `az storage blob sync` |
| Cache clear | `aws cloudfront create-invalidation` | `gcloud compute url-maps invalidate-cdn-cache` | `az afd endpoint purge` |
| Dashboard | CloudWatch | Cloud Monitoring | Azure Monitor |
| Budget | `aws_budgets_budget` | `google_billing_budget` | `azurerm_consumption_budget_subscription` |
| Rough cost for this site | ~0 USD (free tier) | ~18 USD/mo (load balancer rule) | ~0 (Static Web Apps free) or ~35 USD/mo (Front Door) |

The cost row is the lesson most people learn the hard way: the "same"
architecture has very different price floors per cloud.

## Sketch: `modules/gcp/static-site/main.tf`

Not wired up and untested; it shows the shape of the change.

```hcl
terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
  }
}

resource "google_storage_bucket" "site" {
  name                        = "${var.name}-site"   # must be globally unique
  location                    = "EU"
  uniform_bucket_level_access = true
  force_destroy               = true

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }
}

# Cloud CDN reads public objects (unlike CloudFront + OAC, which keeps S3 private).
resource "google_storage_bucket_iam_member" "public_read" {
  bucket = google_storage_bucket.site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_compute_backend_bucket" "site" {
  name        = "${var.name}-site"
  bucket_name = google_storage_bucket.site.name
  enable_cdn  = true
}

resource "google_compute_url_map" "site" {
  name            = "${var.name}-site"
  default_service = google_compute_backend_bucket.site.id
}

resource "google_compute_managed_ssl_certificate" "site" {
  name = "${var.name}-site"
  managed { domains = [var.domain_name] }   # GCP needs a real domain for HTTPS
}

resource "google_compute_target_https_proxy" "site" {
  name             = "${var.name}-site"
  url_map          = google_compute_url_map.site.id
  ssl_certificates = [google_compute_managed_ssl_certificate.site.id]
}

resource "google_compute_global_address" "site" {
  name = "${var.name}-site"
}

resource "google_compute_global_forwarding_rule" "site" {
  name       = "${var.name}-site"
  target     = google_compute_target_https_proxy.site.id
  ip_address = google_compute_global_address.site.address
  port_range = "443"
}

output "site_url"       { value = "https://${var.domain_name}" }
output "content_bucket" { value = google_storage_bucket.site.name }
output "cdn_id"         { value = google_compute_url_map.site.name }
```

Compare with the AWS module: the *idea* is identical (bucket + CDN +
certificate), but GCP needs four networking resources where CloudFront is one.

## Sketch: `modules/azure/static-site/main.tf`

The cheapest Azure option is Static Web Apps (free tier, includes a CDN and
HTTPS on `*.azurestaticapps.net`):

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

resource "azurerm_resource_group" "site" {
  name     = "${var.name}-site"
  location = "westeurope"
}

resource "azurerm_static_web_app" "site" {
  name                = "${var.name}-site"
  resource_group_name = azurerm_resource_group.site.name
  location            = azurerm_resource_group.site.location
  sku_tier            = "Free"
}

output "site_url"       { value = "https://${azurerm_static_web_app.site.default_host_name}" }
output "content_bucket" { value = azurerm_static_web_app.site.name }   # CI deploys with the API key below
output "cdn_id"         { value = "" }                                  # no manual cache clearing needed
output "deploy_token" {
  value     = azurerm_static_web_app.site.api_key
  sensitive = true
}
```

Notice the contract starts to bend: Static Web Apps has no "bucket", it takes
uploads through its own deploy action. Real multi-cloud code has to decide
whether the contract is about *storage* or about *"a place CI deploys to"*.
That kind of design decision is the actual work of multi-cloud.

## What the switch looks like in `infra/live`

```diff
 # providers.tf
-provider "aws" { region = var.aws_region }
+provider "google" {
+  project = var.gcp_project
+  region  = "europe-west6"   # Zurich
+}

 # versions.tf
-  backend "s3" { key = "live/terraform.tfstate" ... }
+  backend "gcs" { prefix = "live" }   # bucket passed with -backend-config

 # main.tf
 module "static_site" {
-  source = "../modules/aws/static-site"
+  source = "../modules/gcp/static-site"
   name        = local.name
   domain_name = var.domain_name
 }
```

`.github/workflows/deploy.yml` swaps the login action and the two upload
commands. `site/`, `tests/` and the PR flow do not change at all.

## Running two clouds at once

Nothing stops the live stack from calling an AWS module *and* a GCP module,
for example AWS for hosting and Cloudflare for DNS. Each provider is
configured once in `providers.tf` and resources pick theirs by type prefix.
That is common in practice (Cloudflare DNS + AWS compute is a classic) and
is the realistic meaning of "multi-cloud" for a small project.

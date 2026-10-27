# 2. Making changes: from a `.tf` edit to a change in AWS

Every change follows the same loop:

```
edit .tf / .tfvars  ->  open PR  ->  CI posts `terraform plan`  ->  you read it
       ->  merge  ->  deploy.yml runs `terraform apply`  ->  AWS API calls
```

You can also try each example locally first with `make plan` (read-only). The
examples get progressively deeper. For each one you see the code change, the
plan you should expect, and what actually happens in AWS.

---

## Example 1: switch on email alerts (change a value)

**Edit** `infra/live/terraform.tfvars`:

```diff
-alert_emails       = []
+alert_emails       = ["you@example.com"]
```

**Expected plan**

```
  # module.monitoring.aws_sns_topic_subscription.email["you@example.com"] will be created
  # module.monitoring.aws_budgets_budget.monthly will be updated in-place
  #   + notification { threshold = 80 ... }  + notification { threshold = 100 ... }
  # module.monitoring.aws_cloudwatch_metric_alarm.cdn_5xx will be updated in-place
  #   ~ alarm_actions = [] -> ["arn:aws:sns:us-east-1:...:modern-web-prod-alerts"]
Plan: 1 to add, 2 to change, 0 to destroy.
```

**What happens in AWS:** SNS sends you a "Subscription Confirmation" email.
Until you click it, the subscription is pending. The budget gets two
notification rules, the alarm gets an action. Nothing about the site changes.

**What you learned:** one variable can fan out into several resources
(`for_each = toset(var.alert_emails)`, `dynamic "notification"`, and the
conditional in `alarm_actions`). Find each of these in
`infra/modules/aws/monitoring/main.tf`.

---

## Example 2: serve from more edge locations (update in place)

**Edit** `infra/live/terraform.tfvars`:

```diff
-cdn_price_class = "PriceClass_100"
+cdn_price_class = "PriceClass_All"
```

**Expected plan:** `~ price_class = "PriceClass_100" -> "PriceClass_All"`,
`1 to change`.

**What happens in AWS:** one `UpdateDistribution` call. CloudFront rolls the
new configuration out to its edge locations, which takes a few minutes; the
apply waits until the status is "Deployed". The site stays online. Visitors in
Asia, South America and Australia now get a nearby edge, and the price per GB
there is higher.

**What you learned:** most settings change the existing object (`~`). The
resource's docs page tells you which arguments are updatable.

---

## Example 3: add a new alarm (add a resource)

Add this to `infra/modules/aws/monitoring/main.tf`:

```hcl
# Many 404s usually mean a broken link or a deleted page.
resource "aws_cloudwatch_metric_alarm" "cdn_4xx" {
  provider = aws.us_east_1

  alarm_name          = "${var.name}-cdn-4xx-error-rate"
  namespace           = "AWS/CloudFront"
  metric_name         = "4xxErrorRate"
  statistic           = "Average"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 20
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DistributionId = var.cdn_id
    Region         = "Global"
  }

  alarm_actions = local.send_emails ? [aws_sns_topic.alerts.arn] : []
}
```

**Expected plan:** `+ create`, `1 to add`.

**What happens in AWS:** one `PutMetricAlarm` call in us-east-1. You can see
it under CloudWatch > Alarms (switch the console to N. Virginia).

**Try next:** make the threshold a variable in `variables.tf`, pass it from
`infra/live/main.tf` and set it in `terraform.tfvars`. That is the full path a
setting travels: tfvars -> live variable -> module argument -> module variable
-> resource argument.

---

## Example 4: buy and connect a custom domain (many resources, real money)

1. Put your contact details into `infra/bootstrap/terraform.tfvars`
   (`domain_contact = { ... }`) and run `make bootstrap` again. The plan shows
   one new resource: the GitHub secret `TF_VAR_DOMAIN_CONTACT`.
2. Check the name is free and its price:
   `aws route53domains check-domain-availability --region us-east-1 --domain-name example.com`
3. Edit `infra/live/terraform.tfvars`:

```diff
-domain_name     = ""
-register_domain = false
+domain_name     = "example.com"
+register_domain = true
```

**Expected plan** (abridged):

```
  + aws_route53domains_domain.this[0]                 # registers the domain
  + aws_acm_certificate.site[0]                       # requests HTTPS certificate
  + aws_route53_record.cert_validation["example.com"]
  + aws_route53_record.cert_validation["www.example.com"]
  + aws_acm_certificate_validation.site[0]            # waits until issued
  + aws_route53_record.site["apex-a"]  ...["apex-aaaa"] ...["www-a"] ...["www-aaaa"]
  ~ aws_cloudfront_distribution.this
      ~ aliases = [] -> ["example.com", "www.example.com"]
      ~ viewer_certificate { cloudfront_default_certificate = true -> acm_certificate_arn = ... }
Plan: 9 to add, 1 to change, 0 to destroy.
```

**What happens in AWS:** Route 53 Domains starts the registration (you get an
email to verify your contact address; do it within 15 days or the domain is
suspended) and creates a hosted zone. ACM issues a certificate once the
validation records resolve. CloudFront starts answering for your domain. The
first apply can take 10 to 30 minutes.

**What you learned:** `count = cond ? 1 : 0` blocks in `domain.tf` that were
dormant switch on together, and `dynamic "viewer_certificate"` swaps one nested
block for another. `prevent_destroy` on the domain means a later plan that
would remove it fails instead of silently deleting a paid domain.

---

## Example 5: rename a resource without destroying it (`moved`)

Say you decide `aws_s3_bucket.site` should be called `aws_s3_bucket.content`.
Renaming the block alone gives:

```
  # module.static_site.aws_s3_bucket.site will be destroyed
  # module.static_site.aws_s3_bucket.content will be created
Plan: 1 to add, 0 to change, 1 to destroy.
```

Terraform tracks objects by **address**, so a new name looks like a new
bucket. To tell it the object simply moved, add next to the renamed block:

```hcl
moved {
  from = aws_s3_bucket.site
  to   = aws_s3_bucket.content
}
```

Now the plan says `has moved to ... 0 to add, 0 to change, 0 to destroy`.
Nothing happens in AWS; only the state is rewritten.

**What you learned:** the state is a map from addresses to real IDs. Read
every `destroy` in a plan and ask whether it is really intended.
Docs: https://developer.hashicorp.com/terraform/language/modules/develop/refactoring

---

## Example 6: drift (someone changed AWS by hand)

In the CloudFront console, change the distribution's comment. Then run
`make plan`:

```
  ~ comment = "changed by hand" -> "modern-web-prod static site"
```

Terraform noticed the **drift** and wants to put the code's value back. This
is why manual console changes are discouraged: the next apply reverts them.
Either change the code to match, or let the apply undo it.

---

## Example 7: remove something (destroy)

Delete the whole `aws_budgets_budget` block. The plan shows `- destroy`.
After the merge, the budget is gone from the Billing console. Put it back by
reverting the commit; the next apply creates it again (with a new ID). That is
the "reversible" property from the primer, with one caveat: data inside a
destroyed resource (files in a bucket, rows in a database) does not come back.
That is why stateful resources get `prevent_destroy` or `deletion_protection`.

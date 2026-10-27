# -----------------------------------------------------------------------------
# Monitoring and cost overview:
#   - a CloudWatch dashboard with traffic, errors and the account's estimated bill
#   - an alarm on server errors
#   - a monthly AWS Budget
#   - optional emails for both (only when alert_emails is not empty)
#
# Free tier notes: 3 dashboards, 10 alarms and 2 budgets are free.
# -----------------------------------------------------------------------------
data "aws_region" "current" {}

locals {
  send_emails = length(var.alert_emails) > 0
}

# --- Notifications ------------------------------------------------------------
# SNS is AWS's pub/sub service. Alarms publish to the topic, and each email
# subscription forwards messages. AWS sends a confirmation mail first: the
# subscription stays "pending" until you click the link in it.
resource "aws_sns_topic" "alerts" {
  provider = aws.us_east_1
  name     = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  provider = aws.us_east_1
  # toset() turns the list into a set, so each address becomes one resource
  # addressed by its value, e.g. aws_sns_topic_subscription.email["me@x.ch"].
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- Alarm --------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "cdn_5xx" {
  provider = aws.us_east_1

  alarm_name          = "${var.name}-cdn-5xx-error-rate"
  alarm_description   = "More than ${var.error_rate_threshold}% of requests failed with a 5xx error."
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  statistic           = "Average"
  period              = 300 # seconds
  evaluation_periods  = 2   # two bad 5-minute periods in a row
  threshold           = var.error_rate_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" # no traffic is not an error

  dimensions = {
    DistributionId = var.cdn_id
    Region         = "Global"
  }

  alarm_actions = local.send_emails ? [aws_sns_topic.alerts.arn] : []
  ok_actions    = local.send_emails ? [aws_sns_topic.alerts.arn] : []
}

# --- Budget -------------------------------------------------------------------
# Budgets are global (not tied to a region). Notifications are generated from
# the list of emails, so with no emails the budget still shows up in the
# Billing console but stays silent.
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = local.send_emails ? {
      actual_80      = { type = "ACTUAL", threshold = 80 }
      forecasted_100 = { type = "FORECASTED", threshold = 100 }
    } : {}

    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.alert_emails
    }
  }
}

# --- Dashboard ----------------------------------------------------------------
# The dashboard body is JSON. jsonencode() lets us write it as Terraform
# objects, so we can insert variables and get syntax checking for free.
# Format reference: https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/CloudWatch-Dashboard-Body-Structure.html
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = join("", [
            "## ${var.name}\n",
            "Monthly budget: **${var.monthly_budget_usd} USD**. ",
            "[Cost Explorer](https://console.aws.amazon.com/cost-management/home#/cost-explorer) · ",
            "[Budgets](https://console.aws.amazon.com/billing/home#/budgets) · ",
            "Filter costs by the tag `Project` to see only this project."
          ])
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Requests"
          region = "us-east-1"
          stat   = "Sum"
          period = 3600
          view   = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "Requests", "DistributionId", var.cdn_id, "Region", "Global"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Error rate (%)"
          region = "us-east-1"
          stat   = "Average"
          period = 3600
          view   = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "4xxErrorRate", "DistributionId", var.cdn_id, "Region", "Global"],
            ["AWS/CloudFront", "5xxErrorRate", "DistributionId", var.cdn_id, "Region", "Global"]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Data transferred to visitors (bytes)"
          region = "us-east-1"
          stat   = "Sum"
          period = 86400
          view   = "timeSeries"
          metrics = [
            ["AWS/CloudFront", "BytesDownloaded", "DistributionId", var.cdn_id, "Region", "Global"]
          ]
        }
      },
      {
        # Shows data only after you enable "Receive CloudWatch billing alerts"
        # once in Billing > Billing preferences (a console-only setting).
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Estimated charges this month (USD, whole account)"
          region = "us-east-1"
          stat   = "Maximum"
          period = 21600
          view   = "singleValue"
          metrics = [
            ["AWS/Billing", "EstimatedCharges", "Currency", "USD"]
          ]
        }
      }
    ]
  })
}

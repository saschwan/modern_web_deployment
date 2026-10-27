variable "name" {
  description = "Prefix for resource names."
  type        = string
}

variable "cdn_id" {
  description = "CloudFront distribution to watch."
  type        = string
}

variable "alert_emails" {
  description = "Addresses for alarm and budget emails. Empty list means no emails at all."
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  description = "Monthly spending limit for the whole AWS account, in USD."
  type        = number
  default     = 5
}

variable "error_rate_threshold" {
  description = "Alarm when this percentage of requests return a 5xx error."
  type        = number
  default     = 5
}

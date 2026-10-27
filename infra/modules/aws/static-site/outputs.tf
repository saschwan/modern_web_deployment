# The module's outputs: what the live stack (and CI) may use.
output "site_url" {
  description = "Public address of the site."
  value       = local.use_domain ? "https://${var.domain_name}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "content_bucket" {
  description = "Bucket that CI uploads the site files to."
  value       = aws_s3_bucket.site.bucket
}

output "cdn_id" {
  description = "CloudFront distribution ID, used to clear the cache after a deploy."
  value       = aws_cloudfront_distribution.this.id
}

output "cdn_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

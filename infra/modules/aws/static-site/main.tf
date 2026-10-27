# -----------------------------------------------------------------------------
# Static website on AWS: a private S3 bucket behind CloudFront.
#
#   browser --HTTPS--> CloudFront edge (cache) --signed request--> S3 bucket
#
# The bucket is not public. CloudFront signs its requests with "Origin Access
# Control" (OAC) and the bucket policy only accepts requests from this one
# distribution. Nobody can bypass the CDN, and you pay nothing for a server.
# -----------------------------------------------------------------------------

# --- Bucket for the site files ------------------------------------------------
resource "aws_s3_bucket" "site" {
  bucket_prefix = "${var.name}-site-"
  force_destroy = var.force_destroy
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# "BucketOwnerEnforced" disables old-style ACLs; access is controlled only by policies.
resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Only this CloudFront distribution may read objects.
# Docs: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
data "aws_iam_policy_document" "site_bucket" {
  statement {
    sid       = "AllowCloudFrontRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json

  # Without this, Terraform could attach the policy while the public access
  # block is still being created, and the API call would fail.
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# --- CloudFront ---------------------------------------------------------------
resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${var.name}-site"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# A tiny JavaScript function that runs at the edge on every request and turns
# "/about/" into "/about/index.html", so folders work like on a normal webserver.
# CloudFront Functions are cheap (first 2 million calls per month are free).
resource "aws_cloudfront_function" "index_rewrite" {
  name    = "${var.name}-index-rewrite"
  runtime = "cloudfront-js-2.0"
  comment = "Append index.html to directory requests"
  publish = true
  code    = file("${path.module}/index-rewrite.js") # file() reads a file next to this module
}

# Managed policies are presets maintained by AWS, referenced by ID.
# Docs: https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html
locals {
  cache_policy_caching_optimized   = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  response_headers_security_policy = "67f7725c-6f97-4210-82d7-5512b31e9d03" # HSTS, X-Frame-Options, ...
  use_domain                       = var.domain_name != ""
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "${var.name} static site"
  default_root_object = "index.html"
  price_class         = var.price_class
  http_version        = "http2and3"

  # The custom domain (and its www variant) once one is configured.
  aliases = local.use_domain ? [var.domain_name, "www.${var.domain_name}"] : []

  origin {
    origin_id                = "s3-site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = local.cache_policy_caching_optimized
    response_headers_policy_id = local.response_headers_security_policy

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  # S3 answers 403 (not 404) for missing files when the caller may not list
  # the bucket. Show our 404 page with the correct status code instead.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # A `dynamic` block generates nested blocks from data. Here exactly one of
  # the two certificate options is rendered, depending on whether a domain is set.
  dynamic "viewer_certificate" {
    for_each = local.use_domain ? [] : [1]
    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = local.use_domain ? [1] : []
    content {
      acm_certificate_arn      = aws_acm_certificate_validation.site[0].certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }
}

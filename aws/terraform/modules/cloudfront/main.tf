# =============================================================================
# Module: CloudFront
# Global CDN for game assets and web builds.
# Uses Origin Access Control (OAC) — modern replacement for OAI.
# Two origins: /assets/* → assets bucket, /builds/* → builds bucket.
# =============================================================================

# ── Origin Access Control ─────────────────────────────────────────────────────

resource "aws_cloudfront_origin_access_control" "assets" {
  name                              = "${var.name_prefix}-assets-oac"
  description                       = "OAC for Kingdom Quest 2D assets bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_origin_access_control" "builds" {
  name                              = "${var.name_prefix}-builds-oac"
  description                       = "OAC for Kingdom Quest 2D builds bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── Cache Policies ────────────────────────────────────────────────────────────

# Long-lived cache for versioned assets (sprites, audio) — 1 year
resource "aws_cloudfront_cache_policy" "assets" {
  name        = "${var.name_prefix}-assets-cache"
  min_ttl     = 86400
  default_ttl = 2592000    # 30 days
  max_ttl     = 31536000   # 1 year

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config  { cookie_behavior = "none" }
    headers_config  { header_behavior = "none" }
    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings { items = ["v", "bust"] }  # Allow cache-busting via ?v=
    }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# Shorter cache for game builds (new patch = new build)
resource "aws_cloudfront_cache_policy" "builds" {
  name        = "${var.name_prefix}-builds-cache"
  min_ttl     = 60
  default_ttl = 3600      # 1 hour
  max_ttl     = 86400     # 1 day

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config  { cookie_behavior = "none" }
    headers_config  { header_behavior = "none" }
    query_strings_config { query_string_behavior = "none" }
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true
  }
}

# ── Distribution ──────────────────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "main" {
  comment         = "Kingdom Quest 2D CDN (${var.environment})"
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"  # US, Canada, Europe — cheapest tier

  # Custom domain (optional — skip if no cert)
  aliases = var.certificate_arn != "" ? [
    "cdn.${var.domain_name}",
    "assets.${var.domain_name}"
  ] : []

  # ── Origin 1: Game Assets ──────────────────────────────────────────────────
  origin {
    domain_name              = var.assets_bucket_domain
    origin_id                = "S3-Assets"
    origin_access_control_id = aws_cloudfront_origin_access_control.assets.id
  }

  # ── Origin 2: Game Builds ──────────────────────────────────────────────────
  origin {
    domain_name              = var.builds_bucket_domain
    origin_id                = "S3-Builds"
    origin_access_control_id = aws_cloudfront_origin_access_control.builds.id
  }

  # ── Default: assets ───────────────────────────────────────────────────────
  default_cache_behavior {
    target_origin_id       = "S3-Assets"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.assets.id
    compress               = true

    # Security headers
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  # ── /builds/* → builds bucket ─────────────────────────────────────────────
  ordered_cache_behavior {
    path_pattern           = "/builds/*"
    target_origin_id       = "S3-Builds"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.builds.id
    compress               = true
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  # ── .wasm files — correct MIME type for Godot web export ──────────────────
  ordered_cache_behavior {
    path_pattern           = "*.wasm"
    target_origin_id       = "S3-Builds"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.builds.id
    compress               = false  # Don't double-compress wasm
    response_headers_policy_id = aws_cloudfront_response_headers_policy.wasm.id
  }

  # ── SSL ───────────────────────────────────────────────────────────────────
  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn != "" ? var.certificate_arn : null
    cloudfront_default_certificate = var.certificate_arn == ""
    ssl_support_method       = var.certificate_arn != "" ? "sni-only" : null
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # ── WAF (optional — attach via console or separate resource) ──────────────
  # web_acl_id = aws_wafv2_web_acl.main.arn

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  tags = { Name = "${var.name_prefix}-cdn" }
}

# ── Response Headers Policies ─────────────────────────────────────────────────

resource "aws_cloudfront_response_headers_policy" "security" {
  name    = "${var.name_prefix}-security-headers"
  comment = "Security headers for Kingdom Quest 2D"

  security_headers_config {
    content_type_options {
      override = true  # X-Content-Type-Options: nosniff
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    xss_protection {
      mode_block = true
      protection = true
      override   = true
    }
  }

  cors_config {
    access_control_allow_credentials = false
    access_control_allow_headers  { items = ["*"] }
    access_control_allow_methods  { items = ["GET", "HEAD"] }
    access_control_allow_origins  { items = ["*"] }
    access_control_max_age_sec    = 86400
    origin_override               = true
  }
}

# Special headers for .wasm — browser requires application/wasm MIME type
resource "aws_cloudfront_response_headers_policy" "wasm" {
  name    = "${var.name_prefix}-wasm-headers"
  comment = "Headers for WebAssembly files"

  custom_headers_config {
    items {
      header   = "Content-Type"
      value    = "application/wasm"
      override = true
    }
    items {
      header   = "Cross-Origin-Opener-Policy"
      value    = "same-origin"
      override = true
    }
    items {
      header   = "Cross-Origin-Embedder-Policy"
      value    = "require-corp"
      override = true
    }
  }
}

# ── S3 Bucket Policies (grant CloudFront OAC access) ─────────────────────────

data "aws_iam_policy_document" "assets_bucket_policy" {
  statement {
    sid     = "AllowCloudFrontOAC"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${var.assets_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "assets" {
  bucket = var.assets_bucket_id
  policy = data.aws_iam_policy_document.assets_bucket_policy.json
}

data "aws_iam_policy_document" "builds_bucket_policy" {
  statement {
    sid     = "AllowCloudFrontOAC"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = ["${var.builds_bucket_arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "builds" {
  bucket = var.builds_bucket_id
  policy = data.aws_iam_policy_document.builds_bucket_policy.json
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"          { type = string }
variable "environment"          { type = string }
variable "assets_bucket_id"     { type = string }
variable "assets_bucket_arn"    { type = string }
variable "assets_bucket_domain" { type = string }
variable "builds_bucket_domain" { type = string }
variable "builds_bucket_arn"    { type = string }
variable "builds_bucket_id"     { type = string; default = "" }
variable "certificate_arn"      { type = string; default = "" }
variable "domain_name"          { type = string }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cdn_url"            { value = "https://${aws_cloudfront_distribution.main.domain_name}" }
output "distribution_id"   { value = aws_cloudfront_distribution.main.id }
output "distribution_arn"  { value = aws_cloudfront_distribution.main.arn }

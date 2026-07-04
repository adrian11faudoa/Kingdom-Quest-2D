# =============================================================================
# Module: S3
# Creates three S3 buckets:
#   1. Assets bucket    — game sprites, audio, tilesets (served via CloudFront)
#   2. Builds bucket    — exported Godot Web builds (served via CloudFront)
#   3. Saves bucket     — encrypted cloud save backups (private, IAM only)
#
# All buckets block public access; CloudFront uses Origin Access Control.
# =============================================================================

# ── Assets Bucket ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "assets" {
  bucket = "${var.name_prefix}-game-assets-${var.account_id}"
  tags   = { Purpose = "GameAssets" }
}

resource "aws_s3_bucket_versioning" "assets" {
  bucket = aws_s3_bucket.assets.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CORS — allow the game client to fetch assets directly
resource "aws_s3_bucket_cors_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = ["*"]
    expose_headers  = ["ETag", "Content-Length"]
    max_age_seconds = 86400
  }
}

# Lifecycle: move old asset versions to Glacier after 90 days
resource "aws_s3_bucket_lifecycle_configuration" "assets" {
  bucket = aws_s3_bucket.assets.id

  rule {
    id     = "archive-old-versions"
    status = "Enabled"
    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }
    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# ── Builds Bucket ─────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "builds" {
  bucket = "${var.name_prefix}-game-builds-${var.account_id}"
  tags   = { Purpose = "GameBuilds" }
}

resource "aws_s3_bucket_versioning" "builds" {
  bucket = aws_s3_bucket.builds.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "builds" {
  bucket = aws_s3_bucket.builds.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "builds" {
  bucket                  = aws_s3_bucket.builds.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Cloud Saves Bucket ────────────────────────────────────────────────────────

resource "aws_s3_bucket" "saves" {
  bucket = "${var.name_prefix}-player-saves-${var.account_id}"
  tags   = { Purpose = "PlayerSaves", Sensitivity = "PlayerData" }
}

resource "aws_s3_bucket_versioning" "saves" {
  bucket = aws_s3_bucket.saves.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "saves" {
  bucket = aws_s3_bucket.saves.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"  # KMS for player PII
    }
  }
}

resource "aws_s3_bucket_public_access_block" "saves" {
  bucket                  = aws_s3_bucket.saves.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Save backups kept for 90 days, then moved to Glacier
resource "aws_s3_bucket_lifecycle_configuration" "saves" {
  bucket = aws_s3_bucket.saves.id

  rule {
    id     = "tiered-storage"
    status = "Enabled"
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

# ── CI/CD Pipeline Bucket (build artifacts) ───────────────────────────────────

resource "aws_s3_bucket" "pipeline" {
  bucket = "${var.name_prefix}-pipeline-artifacts-${var.account_id}"
  tags   = { Purpose = "PipelineArtifacts" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "pipeline" {
  bucket                  = aws_s3_bucket.pipeline.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "pipeline" {
  bucket = aws_s3_bucket.pipeline.id
  rule {
    id     = "expire-artifacts"
    status = "Enabled"
    expiration { days = 30 }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "name_prefix"  { type = string }
variable "environment"  { type = string }
variable "account_id"   { type = string }

# ── Outputs ───────────────────────────────────────────────────────────────────

output "assets_bucket_id"     { value = aws_s3_bucket.assets.id }
output "assets_bucket_arn"    { value = aws_s3_bucket.assets.arn }
output "assets_bucket_domain" { value = aws_s3_bucket.assets.bucket_regional_domain_name }
output "builds_bucket_id"     { value = aws_s3_bucket.builds.id }
output "builds_bucket_arn"    { value = aws_s3_bucket.builds.arn }
output "builds_bucket_domain" { value = aws_s3_bucket.builds.bucket_regional_domain_name }
output "saves_bucket_id"      { value = aws_s3_bucket.saves.id }
output "saves_bucket_arn"     { value = aws_s3_bucket.saves.arn }
output "pipeline_bucket_id"   { value = aws_s3_bucket.pipeline.id }

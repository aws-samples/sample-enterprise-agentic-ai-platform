# ---------------------------------------------------------------------------
# CloudFront access logs — demo path only (deploy_console).
#
# One private bucket receives standard access logs from the console
# distribution and the examples-console Langfuse distribution, under separate
# prefixes. CloudFront standard logging writes through ACLs, so the bucket uses
# BucketOwnerPreferred ownership (the log objects are still owned by this
# account). Logs expire after 90 days.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "cloudfront_logs" {
  #checkov:skip=CKV_AWS_18:This is the access-log destination; logging it to itself would recurse.
  #checkov:skip=CKV_AWS_144:Access logs for a sample stack; cross-region replication not required.
  #checkov:skip=CKV_AWS_145:SSE-S3 avoids granting the CloudFront log-delivery service use of a KMS key; access logs hold no secrets. Use SSE-KMS with the documented key policy for production.
  #checkov:skip=CKV2_AWS_62:No consumers for object-created events on the log bucket.
  count = var.deploy_console ? 1 : 0

  bucket        = "eap-cloudfront-logs-${var.environment}-${local.account_id}"
  force_destroy = true # teardown scripts destroy the stack; logs are disposable
  tags          = var.tags
}

resource "aws_s3_bucket_ownership_controls" "cloudfront_logs" {
  #checkov:skip=CKV2_AWS_65:CloudFront standard logging delivers through ACLs and needs BucketOwnerPreferred.
  count  = var.deploy_console ? 1 : 0
  bucket = aws_s3_bucket.cloudfront_logs[0].id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudfront_logs" {
  count                   = var.deploy_console ? 1 : 0
  bucket                  = aws_s3_bucket.cloudfront_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudfront_logs" {
  count  = var.deploy_console ? 1 : 0
  bucket = aws_s3_bucket.cloudfront_logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "cloudfront_logs" {
  count  = var.deploy_console ? 1 : 0
  bucket = aws_s3_bucket.cloudfront_logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudfront_logs" {
  count  = var.deploy_console ? 1 : 0
  bucket = aws_s3_bucket.cloudfront_logs[0].id
  rule {
    id     = "expire-access-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 7
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

locals {
  # Built from the ownership-controls resource so CloudFront is only configured
  # after ACLs are enabled on the bucket (CloudFront rejects it otherwise).
  cloudfront_log_bucket_domain = var.deploy_console ? "${aws_s3_bucket_ownership_controls.cloudfront_logs[0].bucket}.s3.amazonaws.com" : ""
}

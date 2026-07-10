# Terraform state bucket. Holds bootstrap state plus future per-app state
# under apps/<name>/ keys. Locking uses the native S3 lockfile (TF >= 1.10,
# use_lockfile in the backend config) — no DynamoDB table.

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # Deliberate: flightdeck is a teardown-first demo platform, and
  # `make destroy-bootstrap` must be able to remove a versioned bucket
  # (all object versions and delete markers) without manual emptying.
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state"
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket holding Terraform state"
  value       = aws_s3_bucket.state.arn
}

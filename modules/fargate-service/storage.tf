# Optional per-app S3 storage (spec-docs/arcade-app-spec.md: the arcade app's
# high-score table must survive restarts/redeploys). Everything below is
# conditional on the storage opt-in via the count pattern, so the default
# (storage = "") creates zero new resources here — existing apps adopting
# v0.4.0 without opting in see an empty diff.
#
# Two modes (spec §6):
#   storage = "s3"          — demo-grade: teardown-first, data dies with the
#                             stack. Unchanged since v0.4.0.
#   storage = "s3-retained" — production-data posture (v0.7.0, justified by
#                             the studio app): versioning + lifecycle
#                             retention, and terraform cannot delete the
#                             bucket while it holds data.

locals {
  storage_enabled  = var.storage != ""
  storage_retained = var.storage == "s3-retained"
}

# Only fetched when storage is on, so the default path makes no extra AWS
# API call either.
data "aws_caller_identity" "storage" {
  count = local.storage_enabled ? 1 : 0
}

# Keyed on svc_name (not name): dev and prod stacks of the same app get
# separate buckets automatically — environment data isolation for free.
# One resource for both modes so an s3 → s3-retained upgrade is an in-place
# update to the same bucket: no replacement, no data migration. (That rules
# out lifecycle.prevent_destroy, which must be a literal; retained deletion
# protection comes from force_destroy = false instead — Terraform cannot
# delete a non-empty bucket without it.)
resource "aws_s3_bucket" "data" {
  count  = local.storage_enabled ? 1 : 0
  bucket = "flightdeck-${local.svc_name}-data-${data.aws_caller_identity.storage[0].account_id}"

  # storage = "s3": deliberate, mirrors bootstrap/state.tf — flightdeck is a
  # teardown-first demo platform and an app's data dies with its stack.
  # storage = "s3-retained": the opposite promise. terraform destroy fails on
  # this bucket while it holds any object version; that failure is the
  # break-glass. Deleting production data requires deliberately emptying the
  # bucket (all versions, operator credentials — the deploy role cannot purge
  # versions) or downgrading the manifest to storage: s3 and applying first.
  force_destroy = !local.storage_retained
}

# Retained mode only: version history protects the data against overwrite
# and deletion bugs, not just teardown. Old versions are kept 90 days —
# long enough to notice and recover from a bad write, bounded so cost
# stays at pennies for app-scale data.
resource "aws_s3_bucket_versioning" "data" {
  count  = local.storage_retained ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  count  = local.storage_retained ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  rule {
    id     = "retention"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Lifecycle rules referencing noncurrent versions require versioning to
  # exist first.
  depends_on = [aws_s3_bucket_versioning.data]
}

# SSE-S3 is deliberate for this low-cost personal platform; a customer-managed
# KMS key would add cost and key-policy/recovery lifecycle without protecting
# against the trusted account administrators already able to read app data.
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  count  = local.storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  count  = local.storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Milestone: this is the first permission the task role (main.tf) has ever
# had — it's permissionless by design in v1 and stays that way unless the
# manifest asks for storage. Even then, it can reach exactly its own
# bucket, nothing else in the account. The policy is version-blind: no
# s3:DeleteObjectVersion, so on a retained bucket the app can only create
# delete markers, never destroy history.
resource "aws_iam_role_policy_attachment" "task_storage" {
  count = local.storage_enabled ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${local.svc_name}-task-storage"
}

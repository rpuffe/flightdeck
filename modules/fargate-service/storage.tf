# Optional per-app S3 storage (spec-docs/arcade-app-spec.md: the arcade app's
# high-score table must survive restarts/redeploys). Everything below is
# conditional on var.storage == "s3" via the count pattern, so the default
# (storage = "") creates zero new resources here — existing apps adopting
# v0.4.0 without opting in see an empty diff.

# Only fetched when storage is on, so the default path makes no extra AWS
# API call either.
data "aws_caller_identity" "storage" {
  count = var.storage == "s3" ? 1 : 0
}

# Keyed on svc_name (not name): dev and prod stacks of the same app get
# separate buckets automatically — environment data isolation for free.
resource "aws_s3_bucket" "data" {
  count  = var.storage == "s3" ? 1 : 0
  bucket = "flightdeck-${local.svc_name}-data-${data.aws_caller_identity.storage[0].account_id}"

  # Deliberate, mirrors bootstrap/state.tf: flightdeck is a teardown-first
  # demo platform. An app's data dies with its stack — that's stated loudly
  # in the docs, not a durability promise this module is making.
  force_destroy = true

  # No versioning: this is score-table-scale demo data, not a workload with
  # real durability requirements. Revisit if that ever changes.
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  count  = var.storage == "s3" ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  count  = var.storage == "s3" ? 1 : 0
  bucket = aws_s3_bucket.data[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Milestone: this is the first permission the task role (main.tf) has ever
# had — it's permissionless by design in v1 and stays that way unless the
# manifest asks for storage. Even then, it can reach exactly its own
# bucket, nothing else in the account.
resource "aws_iam_role_policy_attachment" "task_storage" {
  count = var.storage == "s3" ? 1 : 0

  role       = aws_iam_role.task.name
  policy_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/flightdeck-${local.svc_name}-task-storage"
}

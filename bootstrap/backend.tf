# Intentionally empty: the state bucket is created by this same stack.
# `make bootstrap` runs the first apply against local state, then migrates
# into the bucket via `terraform init -migrate-state` with -backend-config
# flags (bucket name derived from the caller's account id at runtime, so it
# is never committed).
terraform {
  backend "s3" {}
}

terraform {
  # >= 1.10 for native S3 state locking (use_lockfile), no DynamoDB table needed
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    # Zips the scaler Lambda's source at plan time (bootstrap/scaler.tf).
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

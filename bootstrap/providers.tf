provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project    = "flightdeck"
      managed-by = "terraform"
      repo       = "github.com/rpuffe/flightdeck"
    }
  }
}

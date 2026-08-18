# Day-0 foundation for one production GCP project.
# The Distr runner does not apply this stack.

terraform {
  required_version = ">= 1.11.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

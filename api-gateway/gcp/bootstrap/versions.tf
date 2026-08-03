# Day-0 foundation for the sandbox and production GCP projects.
# The Distr runner does not apply this stack.

terraform {
  required_version = ">= 1.11.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

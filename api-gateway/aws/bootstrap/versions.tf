# Bootstrap stack for the Distr Docker agent host (laptop-applied).
# Not applied by the Distr runner — day-0 only.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Copy backend.tf.example → backend.tf and fill bucket/key before real applies.
}

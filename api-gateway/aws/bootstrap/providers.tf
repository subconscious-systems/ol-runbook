provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project    = "api-gateway-infra"
      Component  = "docker-agent-host"
      ManagedBy  = "terraform"
      NamePrefix = var.name_prefix
    }
  }
}

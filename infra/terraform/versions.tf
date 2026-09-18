terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.tags
  }
}


# Billing, Cost Explorer, Budgets, and BCM Data Exports are global-style
# services whose primary API endpoints are in us-east-1.
provider "aws" {
  alias  = "billing"
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}

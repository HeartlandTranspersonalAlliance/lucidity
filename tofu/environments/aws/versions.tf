terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.23"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        ManagedBy = "OpenTofu"
        Project   = "lucidity"
      },
      var.tags
    )
  }
}

# Authentication is read only from CLOUDFLARE_API_TOKEN at runtime.
provider "cloudflare" {}

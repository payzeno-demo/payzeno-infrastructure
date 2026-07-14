terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.49"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # State lives in the payzeno-tfstate bucket, one key per environment.
  # The lock table is shared. Do not point staging at this key.
  backend "s3" {
    bucket         = "payzeno-tfstate"
    key            = "production/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "payzeno-tfstate-locks"
    encrypt        = true
  }
}

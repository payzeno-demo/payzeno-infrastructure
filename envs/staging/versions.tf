terraform {
  required_version = ">= 1.7.0, < 1.8.0"

  required_providers {
    # NOTE(apager): production is on ~> 5.49. The bump to 5.49 was applied here in
    # month 8 and reverted the same evening — the plan diff was 400 lines of
    # tag-only churn and nobody was reading it at 18:00 on a Friday. PAY-1904.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.42"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"

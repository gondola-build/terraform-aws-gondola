language {
  compatible_with {
    opentofu = ">= 1.12.0"
  }
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

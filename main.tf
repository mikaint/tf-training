provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {}
}

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }
}
provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    bucket = "mystate123"
    key    = "terraform.tfstate"
    region = "eu-west-1"
  }
}

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"

  tags = {
    Name = "main-vpc"
  }
}
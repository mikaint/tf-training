variable "aws_region" {
    description = "AWS region"
}

variable "whitelisted_ips" {
    type = "list"
    description = "IPs allowed to access resources"
}

variable "key_name" {
    description = "Key pair name"
}
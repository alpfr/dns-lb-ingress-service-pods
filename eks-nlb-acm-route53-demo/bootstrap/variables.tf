variable "aws_region" {
  type        = string
  description = "AWS region for the remote state S3 bucket"
  default     = "us-east-1"
}

variable "bucket_prefix" {
  type        = string
  description = "Prefix for the remote state S3 bucket name"
  default     = "eks-demo-tfstate"
}

variable "aws_region" {
  type        = string
  description = "AWS region for all resources"
  default     = "us-east-1"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS Auto Mode cluster"
  default     = "demo-eks"
}

variable "vpc_id" {
  type        = string
  description = "Optional existing VPC ID. If provided, EKS and ALB deploy into this VPC instead of creating a new one."
  default     = ""
}

variable "subnet_ids" {
  type        = list(string)
  description = "Optional list of subnet IDs for EKS. If empty and vpc_id is provided, subnets will be automatically discovered."
  default     = []
}

variable "domain_name" {
  type        = string
  description = "Route53 public hosted zone name (e.g. alpfrtech.com)"
  default     = "alpfrtech.com"
}

variable "create_route53_zone" {
  type        = bool
  description = "Whether to create a new Route 53 public hosted zone if one does not already exist in AWS"
  default     = false
}

variable "app_subdomain" {
  type        = string
  description = "Subdomain prefix for the application URL"
  default     = "app"
}

variable "app_image" {
  type        = string
  description = "Container image URI including tag"
}

variable "aws_load_balancer_controller_chart_version" {
  type        = string
  description = "Helm chart version for aws-load-balancer-controller"
  default     = "1.11.0"
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to all resources"
  default = {
    Project = "eks-demo"
  }
}

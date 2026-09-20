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

variable "ingress_nginx_chart_version" {
  type        = string
  description = "Helm chart version for ingress-nginx"
  default     = "4.15.1"
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to all resources"
  default = {
    Project = "eks-demo"
  }
}

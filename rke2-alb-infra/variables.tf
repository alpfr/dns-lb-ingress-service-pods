variable "aws_region" {
  type        = string
  description = "AWS region where RKE2 cluster and ALB reside"
  default     = "us-east-1"
}

variable "name" {
  type        = string
  description = "Prefix for AWS ALB, target group, and security group resources"
  default     = "rke2-ingress"
}

variable "vpc_id" {
  type        = string
  description = "VPC ID where the RKE2 EC2 instances and subnets reside"
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "List of public subnet IDs for the ALB. If empty, public subnets in vpc_id will be auto-discovered."
  default     = []
}

variable "domain_name" {
  type        = string
  description = "Route 53 public hosted zone domain name (e.g. alpfrtech.com)"
  default     = "alpfrtech.com"
}

variable "app_subdomain" {
  type        = string
  description = "Subdomain prefix for the application URL (e.g. app)"
  default     = "app"
}

variable "create_route53_zone" {
  type        = bool
  description = "Whether to create a new Route 53 public hosted zone if one does not already exist"
  default     = false
}

variable "worker_instance_ids" {
  type        = list(string)
  description = "List of EC2 Worker Node instance IDs to attach to the ALB Target Group"
  default     = []
}

variable "worker_asg_name" {
  type        = string
  description = "Optional Auto Scaling Group (ASG) name managing RKE2 Worker Nodes to attach directly to Target Group"
  default     = ""
}

variable "worker_security_group_id" {
  type        = string
  description = "Optional Security Group ID attached to RKE2 Worker Nodes to allow ingress strictly from the ALB"
  default     = ""
}

variable "ingress_port" {
  type        = number
  description = "Port where rke2-ingress-nginx listens on the Worker Nodes (typically 80 for hostNetwork or 30080 for NodePort)"
  default     = 80
}

variable "ingress_protocol" {
  type        = string
  description = "Protocol between the ALB and Worker Nodes (HTTP or HTTPS)"
  default     = "HTTP"
}

variable "health_check_path" {
  type        = string
  description = "Health check path on rke2-ingress-nginx"
  default     = "/healthz"
}

variable "health_check_port" {
  type        = string
  description = "Health check port for rke2-ingress-nginx (typically 10254 for NGINX health check endpoint or 'traffic-port')"
  default     = "10254"
}

variable "deregistration_delay" {
  type        = number
  description = "Seconds to wait before removing a deregistering target from the target group (connection draining)"
  default     = 30
}

variable "tags" {
  type        = map(string)
  description = "Common tags applied to all provisioned resources"
  default = {
    Environment = "Production"
    Cluster     = "RKE2"
    ManagedBy   = "Terraform"
  }
}

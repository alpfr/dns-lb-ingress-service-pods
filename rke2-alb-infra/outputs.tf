output "app_url" {
  description = "Public HTTPS application URL"
  value       = "https://${var.app_subdomain}.${var.domain_name}"
}

output "alb_dns_name" {
  description = "Public DNS hostname of the AWS Application Load Balancer"
  value       = aws_lb.rke2_app.dns_name
}

output "alb_arn" {
  description = "ARN of the AWS Application Load Balancer"
  value       = aws_lb.rke2_app.arn
}

output "alb_zone_id" {
  description = "Canonical hosted zone ID of the AWS Application Load Balancer"
  value       = aws_lb.rke2_app.zone_id
}

output "target_group_arn" {
  description = "ARN of the ALB Target Group routing to RKE2 Worker Nodes"
  value       = aws_lb_target_group.rke2_workers.arn
}

output "target_group_name" {
  description = "Name of the ALB Target Group"
  value       = aws_lb_target_group.rke2_workers.name
}

output "alb_security_group_id" {
  description = "Security Group ID of the Application Load Balancer"
  value       = aws_security_group.alb.id
}

output "acm_certificate_arn" {
  description = "ARN of the validated ACM Public Certificate"
  value       = aws_acm_certificate_validation.app.certificate_arn
}

output "ingress_target_type" {
  description = "Target type used for ALB routing"
  value       = "instance"
}

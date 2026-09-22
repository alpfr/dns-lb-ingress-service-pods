output "url" {
  description = "Public URL for the deployed application"
  value       = "https://${var.app_subdomain}.${var.domain_name}"
}

output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS Kubernetes API server"
  value       = module.eks.cluster_endpoint
}

output "alb_hostname" {
  description = "Hostname of the AWS Application Load Balancer provisioned by the AWS Load Balancer Controller"
  value       = try(data.kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname, null)
}

output "nlb_hostname" {
  description = "Legacy alias for alb_hostname pointing to the provisioned AWS Load Balancer"
  value       = try(data.kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname, null)
}

output "ingress_class" {
  description = "Kubernetes Ingress class utilized for routing"
  value       = "alb"
}

output "load_balancer_type" {
  description = "Type of AWS Load Balancer managing external ingress"
  value       = "AWS Application Load Balancer"
}

output "ecr_note" {
  description = "Guidance note on building and pushing the container image"
  value       = "Build and push app_image before applying the Kubernetes deployment."
}

output "vpc_id" {
  description = "VPC ID where the EKS cluster and workloads are deployed"
  value       = local.cluster_vpc_id
}

output "subnet_ids" {
  description = "Subnet IDs utilized by the EKS cluster"
  value       = local.cluster_subnet_ids
}

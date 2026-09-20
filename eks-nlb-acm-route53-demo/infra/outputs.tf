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

output "nlb_hostname" {
  description = "Hostname of the AWS Network Load Balancer provisioned for Ingress NGINX"
  value       = try(data.kubernetes_service_v1.ingress.status[0].load_balancer[0].ingress[0].hostname, null)
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

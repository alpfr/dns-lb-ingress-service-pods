# RKE2 Application Load Balancer (ALB) to Worker Nodes Module

Production-grade Terraform module provisioning an **AWS Application Load Balancer (ALB)** targeting **RKE2 (Rancher Kubernetes Engine 2) Worker Nodes** (`target_type = "instance"`), implementing the **Enterprise Network Team Recommendation**.

---

## Architecture

```
[Internet Client]
       │
       │ HTTPS :443 / TLS
       ▼
[Amazon Route 53] ──► (A Alias: app.alpfrtech.com -> ALB DNS Name)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│ AWS Application Load Balancer (ALB)                         │
│   • TLS Termination: ACM Public Certificate (*.domain)      │
│   • Automated HTTP-to-HTTPS Redirection (Port 80 -> 443)    │
│   • Target Type: "instance" (EC2 Worker Instances / ASG)    │
│   • Direct Health Probe: /healthz on Port 10254             │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               │ HTTP (Port 80 or 30080)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ RKE2 Worker Nodes (EC2 Instances)                           │
│   • Security Group: Ingress restricted strictly to ALB SG   │
│   • rke2-ingress-nginx: hostNetwork (Port 80 / 443)         │
│   • Real Client IP: Preserved via X-Forwarded-For           │
│   • Canal / Calico Overlay (10.42.0.0/16) to Workload Pods  │
└─────────────────────────────────────────────────────────────┘
```

---

## Why Target Worker Nodes in RKE2?

1. **Canal / Calico Overlay CNI**: RKE2 pod IPs (`10.42.0.0/16`) reside on a private VXLAN overlay network and are not directly routable from AWS VPC subnets. The ALB must target the EC2 Worker Node instances on native VPC IPs.
2. **Zero Pod Deletion Churn on AWS**: Pods can scale or restart without triggering AWS `DeregisterTargets` API calls. `rke2-ingress-nginx` updates internal endpoints dynamically in cluster memory.
3. **Control Plane Isolation**: RKE2 Server nodes (`rke2-server`) run `etcd` and `kube-apiserver` with `NoSchedule` taints. Application traffic is strictly directed to worker nodes.

---

## Deployment Instructions

### 1. Configure Input Variables
Copy the template and specify your VPC ID and optional worker instance IDs:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region          = "us-east-1"
vpc_id              = "vpc-04069dd8bf42ea2db"
domain_name         = "alpfrtech.com"
app_subdomain       = "app"
worker_instance_ids = ["i-0123456789abcdef0", "i-0123456789abcdef1"]
```

### 2. Deploy with Terraform

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Configure `rke2-ingress-nginx` for Real Client IP Preservation

On your RKE2 cluster, apply the ConfigMap patch so NGINX forwards real client IPs from the ALB:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: rke2-ingress-nginx-controller
  namespace: kube-system
data:
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
  use-proxy-protocol: "false"
EOF
```

---

## Outputs

| Output | Description |
| :--- | :--- |
| `app_url` | Full public HTTPS URL (`https://app.alpfrtech.com`) |
| `alb_dns_name` | Public DNS hostname of the AWS Application Load Balancer |
| `alb_arn` | ARN of the Application Load Balancer |
| `target_group_arn` | ARN of the target group routing to RKE2 Worker Nodes |
| `alb_security_group_id` | Security Group ID of the ALB (use to restrict worker node SG) |

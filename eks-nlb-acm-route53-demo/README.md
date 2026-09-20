# EKS Auto Mode + NLB + NGINX Ingress + ACM + Route 53 Demo

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D%201.10.0-844FBA?logo=terraform&logoColor=white)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.33-326CE5?logo=kubernetes&logoColor=white)](https://kubernetes.io/)
[![Helm](https://img.shields.io/badge/Helm-ingress--nginx%204.15.1-0F1689?logo=helm&logoColor=white)](https://kubernetes.github.io/ingress-nginx/)

This module contains the complete, production-ready implementation of an **Amazon EKS Auto Mode** cluster with automated AWS Network Load Balancer (NLB) provisioning, ACM TLS termination, in-cluster Ingress NGINX routing, and Route 53 public DNS integration.

---

## Traffic Flow

```
[Internet Client]
       │
       │  HTTPS (443) / TLS
       ▼
[Amazon Route 53 Public Hosted Zone] (CNAME: app.example.com -> NLB DNS)
       │
       ▼
[AWS Network Load Balancer] (TLS Terminated with ACM Public Certificate)
       │
       │  Plain HTTP / TCP (Port 80)
       ▼
[NGINX Ingress Controller] (Host & Path Routing in namespace: ingress-nginx)
       │
       │  ClusterIP (Port 80)
       ▼
[Kubernetes Service: demo-app] (TargetPort: 8080 in namespace: default)
       │
       ▼
[Hardened Flask Pods running via Gunicorn] (Non-root user 10001)
```

---

## Architecture & Design Highlights

- **EKS Auto Mode**: Dynamically manages EC2 node pools (`general-purpose`) with automated node provisioning and scaling without requiring manual node group or Karpenter installations.
- **SSL Termination at the NLB**: The AWS Network Load Balancer offloads TLS decryption using an ACM certificate validated via Route 53 DNS records.
- **Redirect Loop Prevention**: Because traffic from the NLB arrives at Ingress NGINX as plain HTTP, `nginx.ingress.kubernetes.io/ssl-redirect` is explicitly set to `"false"`. The controller config enables `"use-forwarded-headers" = "true"`, preventing `308 Permanent Redirect` / `ERR_TOO_MANY_REDIRECTS` loops.
- **Asynchronous NLB Ready Wait**: Integrates `time_sleep.wait_for_ingress_lb` (45 seconds), ensuring the NLB public DNS name is assigned by AWS before Route 53 CNAME record creation executes.
- **Dynamic Provider Authentication**: The `kubernetes` and `helm` Terraform providers use `aws eks get-token` via dynamic `exec` blocks, avoiding the 15-minute token expiration issue during long cluster creation runs.
- **Enterprise Security Hardening**:
  - **S3 State Storage**: S3 bucket enforces `BucketOwnerEnforced` object ownership (legacy ACLs disabled), AES-256 server-side encryption, versioning, and public access blocks. State locking uses native S3 locking (`use_lockfile = true`).
  - **Pod Security**: Pods run as unprivileged user `appuser` (UID `10001`), drop all Linux capabilities (`drop = ["ALL"]`), and enforce `RuntimeDefault` seccomp profiles.
  - **Network & WSGI Tuning**: Gunicorn uses `--keep-alive 65` (exceeding the NLB 60s idle timeout) with 2 workers and 2 threads.

---

## Directory Structure

```
eks-nlb-acm-route53-demo/
├── README.md                          # This module operational documentation
├── bootstrap/                         # Terraform module for remote S3 state storage
│   ├── main.tf                        # S3 bucket, versioning, encryption, ownership controls
│   ├── variables.tf                   # Region and bucket prefix variables
│   └── versions.tf                    # AWS provider constraints
├── infra/                             # Core infrastructure and Kubernetes workloads
│   ├── main.tf                        # VPC, EKS, ACM, Ingress-NGINX, Route 53, K8s manifests
│   ├── variables.tf                   # Input variable definitions
│   ├── outputs.tf                     # Output endpoints and connection data
│   ├── versions.tf                    # Terraform, AWS, Kubernetes, Helm, Time provider constraints
│   ├── backend.tf.example             # Template for S3 remote backend
│   └── terraform.tfvars.example       # Template for environment input variables
└── app/                               # Python Flask microservice
    ├── app.py                         # Application logic with / and /healthz endpoints
    ├── Dockerfile                     # Multi-stage, non-root hardened container
    ├── requirements.txt               # Flask and Gunicorn runtime dependencies
    └── .dockerignore                  # Docker build exclusions
```

---

## Quick Start (Automated Scripts)

For end-to-end automated deployment without manual execution:

```bash
# From the repository root:
./scripts/deploy.sh --domain example.com -y

# Verify health probes:
./scripts/verify.sh --domain example.com

# Teardown:
./scripts/destroy.sh
```

---

## Complete Deployment Instructions (Manual Walkthrough)

### Prerequisites Check
Before executing, ensure you have:
1. **AWS CLI** configured (`aws sts get-caller-identity`).
2. **Terraform** (`>= 1.10.0`) installed (`terraform -version`).
3. **Docker** running (`docker info`).
4. **kubectl** installed (`kubectl version --client`).
5. An active **Public Route 53 Hosted Zone** (e.g., `example.com`).

---

### Step 1: Bootstrap S3 Remote State
Create the encrypted, versioned S3 bucket for Terraform state:
```bash
cd bootstrap
terraform init
terraform apply -auto-approve

# Note the generated bucket name
STATE_BUCKET=$(terraform output -raw state_bucket)
echo "State Bucket: $STATE_BUCKET"
```

---

### Step 2: Build and Push Application Image
Create an Amazon ECR repository and push the hardened container image:
```bash
cd ../app

AWS_REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/demo-app:v1"

# 1. Create ECR repo
aws ecr create-repository --repository-name demo-app --region "$AWS_REGION" 2>/dev/null || true

# 2. Authenticate Docker
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# 3. Build and push image
docker build -t demo-app:v1 .
docker tag demo-app:v1 "$ECR_URI"
docker push "$ECR_URI"

echo "Image published to: $ECR_URI"
```

---

### Step 3: Configure Infrastructure Variables
Navigate to `infra/`:
```bash
cd ../infra

# Configure backend.tf
cp backend.tf.example backend.tf
```
Update `backend.tf` with the `$STATE_BUCKET` name created in Step 1.

Configure `terraform.tfvars`:
```bash
cp terraform.tfvars.example terraform.tfvars
```
Update `terraform.tfvars`:
```hcl
aws_region                  = "us-east-1"
cluster_name                = "demo-eks"
domain_name                 = "example.com"      # Your Route 53 domain
app_subdomain               = "app"              # Yields app.example.com
app_image                   = "<ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/demo-app:v1"
ingress_nginx_chart_version = "4.15.1"
tags = {
  Environment = "Production"
  Project     = "EKS-Demo"
}
```

---

### Step 4: Deploy Infrastructure & Workload
```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

---

### Step 5: Verify the Deployment
```bash
# Update kubeconfig
aws eks update-kubeconfig --region us-east-1 --name demo-eks

# Check pod and ingress status
kubectl get pods,svc,ingress -A

# Test the public HTTPS endpoints
curl -i https://app.example.com/healthz
curl -i https://app.example.com/
```

---

### Step 6: Teardown & Resource Cleanup
```bash
cd infra
terraform destroy -auto-approve

cd ../bootstrap
aws s3 rm "s3://${STATE_BUCKET}" --recursive
terraform destroy -auto-approve
```

---

## Troubleshooting Guide

| Issue | Cause | Fix |
| :--- | :--- | :--- |
| `ERR_TOO_MANY_REDIRECTS` | Ingress SSL redirect loop | Ensure `"nginx.ingress.kubernetes.io/ssl-redirect" = "false"`. |
| Ingress Hostname Empty | Asynchronous NLB creation | Wait for `time_sleep.wait_for_ingress_lb` (45s). |
| Dynamic 401 Auth Error | Expired static token | Providers use dynamic `exec` authentication with `aws eks get-token`. |
| Pod CrashLoopBackOff | Application binding error | App binds to `0.0.0.0:$PORT` (8080) and has valid health probes on `/healthz`. |

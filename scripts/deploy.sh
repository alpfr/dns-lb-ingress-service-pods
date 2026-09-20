#!/usr/bin/env bash
# ==============================================================================
# AWS EKS Auto Mode + NLB + Ingress NGINX + ACM + Route 53
# Automated End-to-End Deployment Script
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Formatting & Colors
# ------------------------------------------------------------------------------
BOLD='\033[1m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_banner() {
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "${BOLD}${CYAN}🚀 EKS Auto Mode + NLB + ACM + Route 53 Deployment Suite${NC}"
    echo -e "${BLUE}========================================================================${NC}"
}

print_step() {
    echo -e "\n${BOLD}${BLUE}==> [STEP $1] $2${NC}"
}

print_success() {
    echo -e "${GREEN}✔ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✖ $1${NC}"
}

# ------------------------------------------------------------------------------
# Directory Paths
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEMO_DIR="${ROOT_DIR}/eks-nlb-acm-route53-demo"
BOOTSTRAP_DIR="${DEMO_DIR}/bootstrap"
INFRA_DIR="${DEMO_DIR}/infra"
APP_DIR="${DEMO_DIR}/app"

# ------------------------------------------------------------------------------
# Default Options & Parameter Parsing
# ------------------------------------------------------------------------------
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
CLUSTER_NAME="demo-eks"
DOMAIN_NAME=""
APP_SUBDOMAIN="app"
IMAGE_TAG="v1"
SKIP_BOOTSTRAP=false
SKIP_BUILD=false
AUTO_APPROVE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automates the provisioning of EKS Auto Mode, S3 state backend, ECR repository,
container build & push, Ingress NGINX with NLB TLS termination, and Route 53 DNS.

Options:
  -d, --domain DOMAIN       Route 53 public hosted zone name (e.g., example.com) [REQUIRED]
  -s, --subdomain SUB       Subdomain prefix for application (default: app)
  -r, --region REGION       AWS region (default: us-east-1 or \$AWS_REGION)
  -c, --cluster NAME        EKS cluster name (default: demo-eks)
  -t, --tag TAG             Container image tag (default: v1)
  --skip-bootstrap          Skip S3 state bucket bootstrap (assumes backend.tf is configured)
  --skip-build              Skip Docker build and push to Amazon ECR
  -y, --auto-approve        Auto approve Terraform apply and bootstrap operations
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0") --domain example.com
  $(basename "$0") -d example.com -s myapp -r us-west-2 -y
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN_NAME="$2"
            shift 2
            ;;
        -s|--subdomain)
            APP_SUBDOMAIN="$2"
            shift 2
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --skip-bootstrap)
            SKIP_BOOTSTRAP=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        -y|--auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown argument: $1"
            usage
            ;;
    esac
done

# If DOMAIN_NAME was not passed as a flag, check if it exists in terraform.tfvars
if [[ -z "$DOMAIN_NAME" && -f "${INFRA_DIR}/terraform.tfvars" ]]; then
    EXTRACTED_DOMAIN=$(grep -E '^\s*domain_name\s*=' "${INFRA_DIR}/terraform.tfvars" | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
    if [[ -n "$EXTRACTED_DOMAIN" && "$EXTRACTED_DOMAIN" != "example.com" ]]; then
        DOMAIN_NAME="$EXTRACTED_DOMAIN"
        print_success "Using domain_name from terraform.tfvars: ${DOMAIN_NAME}"
    fi
fi

if [[ -z "$DOMAIN_NAME" ]]; then
    print_error "Domain name is required. Provide with --domain <your-domain.com>"
    usage
fi

APPROVAL_FLAG=""
if [[ "$AUTO_APPROVE" == true ]]; then
    APPROVAL_FLAG="-auto-approve"
fi

print_banner
echo -e "${CYAN}Configuration:${NC}"
echo -e "  Domain:         ${BOLD}${DOMAIN_NAME}${NC}"
echo -e "  Application URL:${BOLD}https://${APP_SUBDOMAIN}.${DOMAIN_NAME}${NC}"
echo -e "  AWS Region:     ${BOLD}${AWS_REGION}${NC}"
echo -e "  Cluster Name:   ${BOLD}${CLUSTER_NAME}${NC}"
echo -e "  Skip Bootstrap: ${BOLD}${SKIP_BOOTSTRAP}${NC}"
echo -e "  Skip Build:     ${BOLD}${SKIP_BUILD}${NC}"

# ------------------------------------------------------------------------------
# 1. Check Prerequisites
# ------------------------------------------------------------------------------
print_step "1/5" "Verifying CLI tools and AWS authentication"

for tool in aws terraform docker kubectl; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "Required tool not found in PATH: $tool"
        exit 1
    fi
done
print_success "CLI tools present: aws, terraform, docker, kubectl"

TF_VERSION=$(terraform -version | head -n 1)
print_success "Terraform version: $TF_VERSION"

echo "Verifying AWS credentials..."
CALLER_IDENTITY=$(aws sts get-caller-identity --output json)
ACCOUNT_ID=$(echo "$CALLER_IDENTITY" | jq -r '.Account' 2>/dev/null || aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(echo "$CALLER_IDENTITY" | jq -r '.Arn' 2>/dev/null || aws sts get-caller-identity --query Arn --output text)
print_success "Authenticated to AWS Account: ${ACCOUNT_ID} (${CALLER_ARN})"

echo "Verifying Route 53 public hosted zone for ${DOMAIN_NAME}..."
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${DOMAIN_NAME}." --query "HostedZones[?Name=='${DOMAIN_NAME}.'].Id" --output text 2>/dev/null | head -n 1 || true)
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "None" ]]; then
    print_warning "Could not confirm public hosted zone for '${DOMAIN_NAME}'. Ensure it exists before ACM validation runs."
else
    print_success "Found Route 53 Hosted Zone: ${ZONE_ID}"
fi

# ------------------------------------------------------------------------------
# 2. Bootstrap Remote S3 State
# ------------------------------------------------------------------------------
print_step "2/5" "Terraform S3 Remote State Bootstrap"

if [[ "$SKIP_BOOTSTRAP" == true ]]; then
    print_warning "Skipping bootstrap step as requested (--skip-bootstrap)."
else
    cd "$BOOTSTRAP_DIR"
    echo "Initializing bootstrap module..."
    terraform init -upgrade
    
    echo "Applying bootstrap module..."
    if [[ "$AUTO_APPROVE" == true ]]; then
        terraform apply -auto-approve
    else
        terraform apply
    fi
    
    STATE_BUCKET=$(terraform output -raw state_bucket)
    print_success "Terraform Remote State Bucket: ${STATE_BUCKET}"

    # Configure backend.tf in infra if needed
    if [[ ! -f "${INFRA_DIR}/backend.tf" ]]; then
        echo "Creating ${INFRA_DIR}/backend.tf from template..."
        sed "s/REPLACE_WITH_BOOTSTRAP_OUTPUT/${STATE_BUCKET}/g" "${INFRA_DIR}/backend.tf.example" > "${INFRA_DIR}/backend.tf"
        print_success "Configured ${INFRA_DIR}/backend.tf with bucket: ${STATE_BUCKET}"
    else
        # If backend.tf already exists but has the placeholder, replace it
        if grep -q "REPLACE_WITH_BOOTSTRAP_OUTPUT" "${INFRA_DIR}/backend.tf"; then
            sed -i.bak "s/REPLACE_WITH_BOOTSTRAP_OUTPUT/${STATE_BUCKET}/g" "${INFRA_DIR}/backend.tf" && rm -f "${INFRA_DIR}/backend.tf.bak"
            print_success "Updated ${INFRA_DIR}/backend.tf with bucket: ${STATE_BUCKET}"
        else
            print_success "Existing ${INFRA_DIR}/backend.tf preserved"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 3. Build & Push Application Image to Amazon ECR
# ------------------------------------------------------------------------------
print_step "3/5" "Build & Push Container Image to Amazon ECR"

ECR_REPO_NAME="demo-app"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}:${IMAGE_TAG}"

if [[ "$SKIP_BUILD" == true ]]; then
    print_warning "Skipping image build and push (--skip-build). Using ECR URI: ${ECR_URI}"
else
    cd "$APP_DIR"
    echo "Ensuring Amazon ECR repository '${ECR_REPO_NAME}' exists..."
    aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" &>/dev/null || \
        aws ecr create-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" >/dev/null
    print_success "ECR repository ready: ${ECR_REPO_NAME}"

    echo "Authenticating Docker with Amazon ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

    echo "Building container image (${ECR_REPO_NAME}:${IMAGE_TAG})..."
    docker build --platform linux/amd64 -t "${ECR_REPO_NAME}:${IMAGE_TAG}" .

    echo "Tagging and pushing image to ${ECR_URI}..."
    docker tag "${ECR_REPO_NAME}:${IMAGE_TAG}" "$ECR_URI"
    docker push "$ECR_URI"
    print_success "Image published successfully: ${ECR_URI}"
fi

# ------------------------------------------------------------------------------
# 4. Configure & Apply Infrastructure
# ------------------------------------------------------------------------------
print_step "4/5" "Deploying Infrastructure & Kubernetes Workload"

cd "$INFRA_DIR"

# Generate or update terraform.tfvars
echo "Updating ${INFRA_DIR}/terraform.tfvars..."
cat > "${INFRA_DIR}/terraform.tfvars" <<EOF
aws_region                  = "${AWS_REGION}"
cluster_name                = "${CLUSTER_NAME}"
domain_name                 = "${DOMAIN_NAME}"
app_subdomain               = "${APP_SUBDOMAIN}"
app_image                   = "${ECR_URI}"
ingress_nginx_chart_version = "4.15.1"
tags = {
  Environment = "Production"
  ManagedBy   = "Terraform"
  Project     = "EKS-Demo"
}
EOF
print_success "Configured terraform.tfvars"

echo "Initializing Terraform infrastructure module..."
terraform init -upgrade

echo "Validating Terraform code..."
terraform fmt -check
terraform validate
print_success "Terraform configuration is valid"

echo "Planning infrastructure changes..."
terraform plan -out=tfplan

echo -e "\n${BOLD}${YELLOW}Applying infrastructure plan (EKS creation takes ~12-15 minutes)...${NC}"
if [[ "$AUTO_APPROVE" == true ]]; then
    terraform apply -auto-approve tfplan
else
    terraform apply tfplan
fi
print_success "Infrastructure provisioned successfully"

# ------------------------------------------------------------------------------
# 5. Connect kubectl and Post-Deployment Verification
# ------------------------------------------------------------------------------
print_step "5/5" "Verifying Deployment & Testing Live Endpoints"

echo "Configuring kubectl context for cluster: ${CLUSTER_NAME}..."
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
print_success "kubectl context updated"

echo "Running verification checks..."
if [[ -f "${SCRIPT_DIR}/verify.sh" ]]; then
    bash "${SCRIPT_DIR}/verify.sh" --domain "$DOMAIN_NAME" --subdomain "$APP_SUBDOMAIN"
else
    kubectl get pods,svc,ingress -A
fi

echo -e "\n${GREEN}========================================================================${NC}"
echo -e "${BOLD}${GREEN}🎉 Deployment Complete!${NC}"
echo -e "Application URL: ${BOLD}https://${APP_SUBDOMAIN}.${DOMAIN_NAME}${NC}"
echo -e "${GREEN}========================================================================${NC}"

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
DOMAIN_NAME="alpfrtech.com"
DOMAIN_PROVIDED=false
APP_SUBDOMAIN="app"
APP_SUBDOMAIN_PROVIDED=false
VPC_ID=""
VPC_ID_PROVIDED=false
FORCE_CREATE_VPC=false
IMAGE_TAG="v1"
SKIP_BOOTSTRAP=false
SKIP_BUILD=false
AUTO_APPROVE=false
CREATE_ROUTE53_ZONE=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automates the provisioning of EKS Auto Mode, S3 state backend, ECR repository,
container build & push, Ingress NGINX with NLB TLS termination, and Route 53 DNS.

Options:
  -d, --domain DOMAIN       Route 53 public hosted zone name (default: alpfrtech.com)
  -s, --subdomain SUB       Subdomain prefix for application (default: app)
  -r, --region REGION       AWS region (default: us-east-1 or \$AWS_REGION)
  -c, --cluster NAME        EKS cluster name (default: demo-eks)
  --vpc-id VPC_ID           Use an existing VPC ID in the target AWS region
  --use-existing-vpc        Auto-select or prompt for an existing VPC (default behavior)
  --create-vpc              Force creation of a new dedicated VPC (demo-eks-vpc)
  -t, --tag TAG             Container image tag (default: v1)
  --create-zone             Create a new Route 53 public hosted zone if not present
  --skip-bootstrap          Skip S3 state bucket bootstrap (assumes backend.tf is configured)
  --skip-build              Skip Docker build and push to Amazon ECR
  -y, --auto-approve        Auto approve Terraform apply and bootstrap operations
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0")
  $(basename "$0") --vpc-id vpc-04069dd8bf42ea2db
  $(basename "$0") --create-vpc
  $(basename "$0") --domain alpfrtech.com -y
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--domain)
            DOMAIN_NAME="$2"
            DOMAIN_PROVIDED=true
            shift 2
            ;;
        -s|--subdomain)
            APP_SUBDOMAIN="$2"
            APP_SUBDOMAIN_PROVIDED=true
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
        --vpc-id)
            VPC_ID="$2"
            VPC_ID_PROVIDED=true
            shift 2
            ;;
        --create-vpc)
            FORCE_CREATE_VPC=true
            shift
            ;;
        --use-existing-vpc)
            FORCE_CREATE_VPC=false
            shift
            ;;
        -t|--tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        --create-zone)
            CREATE_ROUTE53_ZONE=true
            shift
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
if [[ "$DOMAIN_PROVIDED" == false && -f "${INFRA_DIR}/terraform.tfvars" ]]; then
    RAW_DOMAIN=$(grep -E '^\s*domain_name\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "' || true)
    if [[ -n "$RAW_DOMAIN" && "$RAW_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        DOMAIN_NAME="$RAW_DOMAIN"
        print_success "Using domain_name from terraform.tfvars: ${DOMAIN_NAME}"
    else
        print_warning "No valid domain_name in terraform.tfvars; defaulting to: ${DOMAIN_NAME}"
    fi
fi

if [[ "$APP_SUBDOMAIN_PROVIDED" == false && -f "${INFRA_DIR}/terraform.tfvars" ]]; then
    EXTRACTED_SUB=$(grep -E '^\s*app_subdomain\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "' || true)
    if [[ -n "$EXTRACTED_SUB" && "$EXTRACTED_SUB" =~ ^[a-zA-Z0-9-]+$ ]]; then
        APP_SUBDOMAIN="$EXTRACTED_SUB"
    fi
fi

if [[ "$VPC_ID_PROVIDED" == false && "$FORCE_CREATE_VPC" == false && -f "${INFRA_DIR}/terraform.tfvars" ]]; then
    RAW_VPC=$(grep -E '^\s*vpc_id\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "' || true)
    if [[ -n "$RAW_VPC" && "$RAW_VPC" =~ ^vpc-[a-f0-9]+$ ]]; then
        VPC_ID="$RAW_VPC"
        print_success "Using vpc_id from terraform.tfvars: ${VPC_ID}"
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
if [[ "$FORCE_CREATE_VPC" == true ]]; then
    echo -e "  VPC:            ${BOLD}Create dedicated VPC${NC}"
elif [[ -n "$VPC_ID" ]]; then
    echo -e "  VPC:            ${BOLD}Existing (${VPC_ID})${NC}"
else
    echo -e "  VPC:            ${BOLD}Auto-discover in ${AWS_REGION}${NC}"
fi
echo -e "  Skip Bootstrap: ${BOLD}${SKIP_BOOTSTRAP}${NC}"
echo -e "  Skip Build:     ${BOLD}${SKIP_BUILD}${NC}"

# ------------------------------------------------------------------------------
# 1. Check Prerequisites
# ------------------------------------------------------------------------------
print_step "1/5" "Verifying CLI tools and AWS authentication"

for tool in aws terraform docker kubectl jq; do
    if ! command -v "$tool" &> /dev/null; then
        print_error "Required tool not found in PATH: $tool"
        exit 1
    fi
done
print_success "CLI tools present: aws, terraform, docker, kubectl, jq"

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
    if [[ "$CREATE_ROUTE53_ZONE" == true ]]; then
        print_warning "No existing hosted zone found for '${DOMAIN_NAME}'. Terraform will automatically create it in Route 53."
    else
        print_warning "No existing public hosted zone found for '${DOMAIN_NAME}' in AWS."
        print_warning "Enabling 'create_route53_zone = true' so Terraform automatically provisions it."
        CREATE_ROUTE53_ZONE=true
    fi
else
    print_success "Found active Route 53 Hosted Zone: ${ZONE_ID}"
    CREATE_ROUTE53_ZONE=false
fi

echo "Verifying VPC configuration for ${AWS_REGION}..."
if [[ "$FORCE_CREATE_VPC" == true ]]; then
    print_warning "New dedicated VPC creation requested (--create-vpc)."
    VPC_ID=""
elif [[ -n "$VPC_ID" ]]; then
    if aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" &>/dev/null; then
        VPC_NAME=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$AWS_REGION" --query "Vpcs[0].Tags[?Key=='Name'].Value|[0]" --output text 2>/dev/null || echo "")
        print_success "Using specified existing VPC: ${VPC_ID} (${VPC_NAME:-Unnamed})"
    else
        print_error "VPC '${VPC_ID}' was not found in region '${AWS_REGION}'."
        exit 1
    fi
else
    echo "Scanning for existing VPCs in ${AWS_REGION}..."
    IGW_VPCS=$(aws ec2 describe-internet-gateways --region "$AWS_REGION" --query "InternetGateways[*].Attachments[*].VpcId" --output text 2>/dev/null || true)
    NAT_VPCS=$(aws ec2 describe-nat-gateways --region "$AWS_REGION" --filter "Name=state,Values=available" --query "NatGateways[*].VpcId" --output text 2>/dev/null || true)

    CANDIDATE_IDS=()
    CANDIDATE_LABELS=()

    while IFS=$'\t' read -r vid vname vcidr; do
        [[ -z "$vid" ]] && continue
        vname="${vname:-Unnamed}"
        has_igw="No"
        has_nat="No"
        if echo "$IGW_VPCS" | grep -qw "$vid"; then has_igw="Yes"; fi
        if echo "$NAT_VPCS" | grep -qw "$vid"; then has_nat="Yes"; fi

        lbl="${vid} | ${vname} | CIDR: ${vcidr} | IGW: ${has_igw} | NAT: ${has_nat}"
        if [[ "$has_igw" == "Yes" && "$has_nat" == "Yes" ]]; then
            lbl="${lbl} (Recommended)"
            CANDIDATE_IDS=("$vid" "${CANDIDATE_IDS[@]}")
            CANDIDATE_LABELS=("$lbl" "${CANDIDATE_LABELS[@]}")
        else
            CANDIDATE_IDS+=("$vid")
            CANDIDATE_LABELS+=("$lbl")
        fi
    done < <(aws ec2 describe-vpcs --region "$AWS_REGION" --output json 2>/dev/null | jq -r '.Vpcs[] | ["\(.VpcId)", "\(.Tags[]? | select(.Key=="Name") | .Value)", "\(.CidrBlock)"] | @tsv' || true)

    if [[ ${#CANDIDATE_IDS[@]} -gt 0 ]]; then
        if [[ "$AUTO_APPROVE" == true || "$VPC_ID_PROVIDED" == true ]]; then
            VPC_ID="${CANDIDATE_IDS[0]}"
            print_success "Auto-selected healthy existing VPC: ${VPC_ID} (${CANDIDATE_LABELS[0]})"
        else
            echo -e "\n${BOLD}${CYAN}Existing VPCs discovered in ${AWS_REGION}:${NC}"
            for i in "${!CANDIDATE_LABELS[@]}"; do
                idx=$((i + 1))
                echo -e "  [${idx}] ${CANDIDATE_LABELS[$i]}"
            done
            new_idx=$((${#CANDIDATE_LABELS[@]} + 1))
            echo -e "  [${new_idx}] Create a new dedicated VPC (demo-eks-vpc)"

            read -rp "Select VPC option [1-${new_idx}] (default: 1): " vpc_choice
            vpc_choice="${vpc_choice:-1}"

            if [[ "$vpc_choice" =~ ^[0-9]+$ ]] && [ "$vpc_choice" -ge 1 ] && [ "$vpc_choice" -le "${#CANDIDATE_IDS[@]}" ]; then
                chosen_idx=$((vpc_choice - 1))
                VPC_ID="${CANDIDATE_IDS[$chosen_idx]}"
                print_success "Selected existing VPC: ${VPC_ID}"
            else
                VPC_ID=""
                print_warning "Proceeding with new dedicated VPC creation."
            fi
        fi
    else
        print_warning "No existing VPCs found in ${AWS_REGION}. A new dedicated VPC will be created."
        VPC_ID=""
    fi
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
vpc_id                      = "${VPC_ID}"
domain_name                 = "${DOMAIN_NAME}"
app_subdomain               = "${APP_SUBDOMAIN}"
app_image                   = "${ECR_URI}"
ingress_nginx_chart_version = "4.15.1"
create_route53_zone         = ${CREATE_ROUTE53_ZONE}
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

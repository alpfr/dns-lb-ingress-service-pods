#!/usr/bin/env bash
# ==============================================================================
# AWS EKS Auto Mode + AWS ALB + AWS Load Balancer Controller + ACM + Route 53
# Teardown and Resource Cleanup Script
# ==============================================================================

set -euo pipefail

BOLD='\033[1m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEMO_DIR="${ROOT_DIR}/eks-nlb-acm-route53-demo"
BOOTSTRAP_DIR="${DEMO_DIR}/bootstrap"
INFRA_DIR="${DEMO_DIR}/infra"
PLATFORM="eks"

AUTO_APPROVE=false
DELETE_BOOTSTRAP=false
DELETE_ECR=false
ECR_REPO_NAME="demo-app"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Safely tears down the EKS cluster or RKE2 ALB infrastructure, Target Groups,
Route 53 records, ACM certificates, and optionally cleans up ECR and S3 remote state.

Options:
  --rke2                    Tear down RKE2 ALB infrastructure (preserves EC2 worker nodes)
  -y, --auto-approve        Skip interactive confirmation prompts
  --delete-ecr              Delete the demo-app ECR repository and images
  --delete-bootstrap        Delete the Terraform remote state S3 bucket
  -r, --region REGION       AWS Region (default: us-east-1 or \$AWS_REGION)
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0")
  $(basename "$0") --rke2 -y
  $(basename "$0") -y --delete-ecr
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rke2)
            PLATFORM="rke2"
            INFRA_DIR="${ROOT_DIR}/rke2-alb-infra"
            shift
            ;;
        -y|--auto-approve)
            AUTO_APPROVE=true
            shift
            ;;
        --delete-ecr)
            DELETE_ECR=true
            shift
            ;;
        --delete-bootstrap)
            DELETE_BOOTSTRAP=true
            shift
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            usage
            ;;
    esac
done

echo -e "${RED}========================================================================${NC}"
echo -e "${BOLD}${RED}⚠ WARNING: Infrastructure Teardown (${PLATFORM^^})${NC}"
echo -e "${RED}========================================================================${NC}"

if [[ "$PLATFORM" == "rke2" ]]; then
    echo "This action will permanently destroy:"
    echo "  • AWS Application Load Balancer (ALB) for RKE2 Worker Nodes"
    echo "  • ALB Target Group (rke2-workers-tg)"
    echo "  • Route 53 A Alias Record and ACM TLS Certificate"
    echo "  • ALB Security Group and Ingress Rules"
    echo -e "${GREEN}  • RKE2 Control Plane and Worker EC2 instances are PRESERVED and untouched.${NC}"
    echo -e "${GREEN}  • Existing VPC and Subnets are PRESERVED and untouched.${NC}"
else
    echo "This action will permanently destroy:"
    echo "  • EKS Auto Mode Cluster and Compute Instances"
    echo "  • AWS Application Load Balancer (ALB)"
    echo "  • Route 53 DNS Records"
    echo "  • ACM TLS Certificate"
    echo "  • AWS Load Balancer Controller & Microservice Pods"
    if [[ -f "${INFRA_DIR}/terraform.tfvars" ]] && grep -qE '^\s*vpc_id\s*=\s*"vpc-' "${INFRA_DIR}/terraform.tfvars"; then
        VPC_USED=$(grep -E '^\s*vpc_id\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "')
        echo -e "${GREEN}  • Existing VPC (${VPC_USED}) is PRESERVED and will NOT be modified or destroyed.${NC}"
    else
        echo "  • Dedicated VPC and Subnets (if created by Terraform)"
    fi
fi

if [[ "$DELETE_ECR" == true ]]; then
    echo "  • Amazon ECR Repository (${ECR_REPO_NAME})"
fi
if [[ "$DELETE_BOOTSTRAP" == true ]]; then
    echo "  • Bootstrap Remote State S3 Bucket"
fi
echo ""

if [[ "$AUTO_APPROVE" != true ]]; then
    read -rp "Are you sure you want to proceed with teardown? (type 'yes' to confirm): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Teardown aborted."
        exit 0
    fi
fi

# 1. Destroy Infrastructure
echo -e "\n${BOLD}${BLUE}==> [1/3] Destroying Core Infrastructure (${INFRA_DIR})...${NC}"
cd "$INFRA_DIR"
if [[ -f "terraform.tfvars" ]]; then
    terraform init -upgrade
    if [[ "$AUTO_APPROVE" == true ]]; then
        terraform destroy -auto-approve
    else
        terraform destroy
    fi
    echo -e "${GREEN}✔ Infrastructure destroyed successfully.${NC}"
else
    echo -e "${YELLOW}⚠ terraform.tfvars not found in ${INFRA_DIR}. Skipping infra destroy.${NC}"
fi

# 2. Delete ECR Repository if requested
if [[ "$DELETE_ECR" == true ]]; then
    echo -e "\n${BOLD}${BLUE}==> [2/3] Deleting ECR Repository (${ECR_REPO_NAME})...${NC}"
    if aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" --region "$AWS_REGION" &>/dev/null; then
        aws ecr delete-repository --repository-name "$ECR_REPO_NAME" --region "$AWS_REGION" --force
        echo -e "${GREEN}✔ ECR repository deleted.${NC}"
    else
        echo -e "${YELLOW}⚠ ECR repository not found.${NC}"
    fi
else
    echo -e "\n${BOLD}${BLUE}==> [2/3] Skipping ECR repository deletion (use --delete-ecr to remove).${NC}"
fi

# 3. Delete Bootstrap S3 State Bucket if requested
if [[ "$DELETE_BOOTSTRAP" == true ]]; then
    echo -e "\n${BOLD}${BLUE}==> [3/3] Deleting Bootstrap S3 State Bucket...${NC}"
    cd "$BOOTSTRAP_DIR"
    STATE_BUCKET=$(terraform output -raw state_bucket 2>/dev/null || true)
    if [[ -n "$STATE_BUCKET" ]]; then
        echo "Purging versioned objects from S3 bucket: ${STATE_BUCKET}..."
        aws s3 rm "s3://${STATE_BUCKET}" --recursive 2>/dev/null || true
        # Empty all version markers
        VERSIONS=$(aws s3api list-object-versions --bucket "$STATE_BUCKET" --output json 2>/dev/null || echo "{}")
        echo "Destroying bootstrap resources..."
        terraform destroy -auto-approve
        echo -e "${GREEN}✔ Bootstrap S3 bucket destroyed.${NC}"
    else
        echo -e "${YELLOW}⚠ Could not find state bucket output in bootstrap. Skipping.${NC}"
    fi
else
    echo -e "\n${BOLD}${BLUE}==> [3/3] Skipping Bootstrap S3 bucket deletion (use --delete-bootstrap to remove).${NC}"
fi

echo -e "\n${GREEN}========================================================================${NC}"
echo -e "${BOLD}${GREEN}✔ Teardown completed successfully.${NC}"
echo -e "${GREEN}========================================================================${NC}"

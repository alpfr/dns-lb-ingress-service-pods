#!/usr/bin/env bash
# ==============================================================================
# AWS EKS Auto Mode + AWS ALB + AWS Load Balancer Controller + ACM + Route 53
# Post-Deployment Verification & Health Check Script
# ==============================================================================

set -euo pipefail

BOLD='\033[1m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
INFRA_DIR="${ROOT_DIR}/eks-nlb-acm-route53-demo/infra"

DOMAIN_NAME="alpfrtech.com"
DOMAIN_PROVIDED=false
APP_SUBDOMAIN="app"
APP_SUBDOMAIN_PROVIDED=false

PLATFORM="eks"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Performs cluster, ingress, pod, and HTTP endpoint health checks.

Options:
  --rke2                    Validate RKE2 ALB to Worker Nodes deployment
  -d, --domain DOMAIN       Route 53 public domain (default: alpfrtech.com)
  -s, --subdomain SUB       Subdomain prefix (default: app)
  -r, --region REGION       AWS Region (default: us-east-1)
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0")
  $(basename "$0") --rke2
  $(basename "$0") --domain alpfrtech.com
  $(basename "$0") -d alpfrtech.com -s app
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
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Unknown argument: $1${NC}"
            usage
            ;;
    esac
done

# Try reading from terraform.tfvars if domain or subdomain not passed via CLI
if [[ -f "${INFRA_DIR}/terraform.tfvars" ]]; then
    if [[ "$DOMAIN_PROVIDED" == false ]]; then
        RAW_DOMAIN=$(grep -E '^\s*domain_name\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "' || true)
        if [[ -n "$RAW_DOMAIN" && "$RAW_DOMAIN" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
            DOMAIN_NAME="$RAW_DOMAIN"
        fi
    fi
    if [[ "$APP_SUBDOMAIN_PROVIDED" == false ]]; then
        EXTRACTED_SUB=$(grep -E '^\s*app_subdomain\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "' || true)
        if [[ -n "$EXTRACTED_SUB" && "$EXTRACTED_SUB" =~ ^[a-zA-Z0-9-]+$ ]]; then
            APP_SUBDOMAIN="$EXTRACTED_SUB"
        fi
    fi
    RAW_VPC=$(grep -E '^\s*vpc_id\s*=' "${INFRA_DIR}/terraform.tfvars" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "' || true)
    if [[ -n "$RAW_VPC" && "$RAW_VPC" =~ ^vpc-[a-f0-9]+$ ]]; then
        VPC_ID="$RAW_VPC"
    fi
fi

APP_URL="https://${APP_SUBDOMAIN}.${DOMAIN_NAME}"

echo -e "\n${BOLD}${CYAN}🔍 Starting Health and Verification Suite${NC}"
echo -e "Target Application URL: ${BOLD}${APP_URL}${NC}"
if [[ -n "${VPC_ID:-}" ]]; then
    echo -e "VPC:                    ${BOLD}Existing (${VPC_ID})${NC}\n"
else
    echo -e "VPC:                    ${BOLD}Dedicated demo-eks-vpc${NC}\n"
fi

# 1. Cluster connectivity & Node check
echo -e "${BOLD}${BLUE}[1/5] Checking Kubernetes Cluster Nodes & Distribution...${NC}"
if ! kubectl get nodes -o wide; then
    echo -e "${RED}✖ Failed to reach Kubernetes cluster API. Verify your kubeconfig context.${NC}"
    exit 1
fi

K8S_SERVER_VERSION=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || kubectl version --short 2>/dev/null || echo "Unknown")
if echo "$K8S_SERVER_VERSION" | grep -qi "rke2"; then
    CLUSTER_TYPE="RKE2"
    echo -e "${GREEN}✔ Cluster Distribution: RKE2 (${K8S_SERVER_VERSION})${NC}"
    echo -e "  • Control Plane Nodes: $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo 'N/A')"
    echo -e "  • Worker Nodes (ALB Targets): $(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address 2>/dev/null | tr '\n' ' ' || echo 'N/A')"
elif echo "$K8S_SERVER_VERSION" | grep -qi "eks"; then
    CLUSTER_TYPE="EKS"
    echo -e "${GREEN}✔ Cluster Distribution: AWS EKS (${K8S_SERVER_VERSION})${NC}"
else
    CLUSTER_TYPE="Kubernetes"
    echo -e "${GREEN}✔ Kubernetes Distribution: ${K8S_SERVER_VERSION}${NC}"
fi
echo ""

# 2. Ingress Controller & ALB status
echo -e "${BOLD}${BLUE}[2/5] Checking Ingress Controller & ALB Ingress Status...${NC}"
ALB_CONTROLLER_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --no-headers 2>/dev/null || true)
RKE2_INGRESS_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=rke2-ingress-nginx --no-headers 2>/dev/null || true)

if [[ -n "$ALB_CONTROLLER_PODS" ]]; then
    echo -e "${GREEN}✔ AWS Load Balancer Controller detected in kube-system:${NC}"
    echo "  $ALB_CONTROLLER_PODS"
elif [[ -n "$RKE2_INGRESS_PODS" ]]; then
    echo -e "${GREEN}✔ rke2-ingress-nginx detected in kube-system (RKE2 Worker Ingress):${NC}"
    echo "  $RKE2_INGRESS_PODS"
else
    echo -e "${YELLOW}⚠ Ingress controller pods not found in kube-system${NC}"
fi

ALB_HOSTNAME=$(kubectl get ingress demo-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -n "$ALB_HOSTNAME" ]]; then
    echo -e "${GREEN}✔ External Application Load Balancer (ALB) Hostname: ${ALB_HOSTNAME}${NC}"
else
    echo -e "${YELLOW}⚠ ALB hostname not registered on Ingress. Route 53 or external LB may be managed outside the ingress controller.${NC}"
fi

# Check AWS Target Group health directly if AWS CLI is configured
if command -v aws &>/dev/null; then
    TARGET_TG_NAME="rke2-workers-tg"
    if [[ "$PLATFORM" == "eks" ]]; then
        TARGET_TG_NAME=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --query "TargetGroups[?contains(TargetGroupName, 'demo-app')].TargetGroupName | [0]" --output text 2>/dev/null || echo "")
    fi
    if [[ -n "$TARGET_TG_NAME" && "$TARGET_TG_NAME" != "None" ]]; then
        TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --names "$TARGET_TG_NAME" --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
        if [[ -n "$TG_ARN" && "$TG_ARN" != "None" ]]; then
            HEALTH_SUMMARY=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$AWS_REGION" --query "TargetHealthDescriptions[*].TargetHealth.State" --output text 2>/dev/null || true)
            TOTAL_TARGETS=$(echo "$HEALTH_SUMMARY" | wc -w | tr -d ' ')
            HEALTHY_TARGETS=$(echo "$HEALTH_SUMMARY" | grep -o "healthy" | wc -l | tr -d ' ' || echo "0")
            echo -e "${GREEN}✔ AWS Target Group (${TARGET_TG_NAME}): ${HEALTHY_TARGETS}/${TOTAL_TARGETS} targets healthy in AWS${NC}"
        fi
    fi
fi
echo ""

# 3. Workload Pods, Ingress Rules & NetworkPolicy
echo -e "${BOLD}${BLUE}[3/5] Checking Microservice Pods, Ingress Rules & NetworkPolicy...${NC}"
kubectl get pods -l app=demo-app -o wide 2>/dev/null || kubectl get pods -A | grep -E "demo-app|datarobot" || true
kubectl get svc demo-app 2>/dev/null || true
kubectl get ingress demo-app 2>/dev/null || true
echo -e "\nVerifying NetworkPolicy (Zero-Trust Ingress Isolation)..."
if kubectl get networkpolicy -n default demo-app-ingress-only &>/dev/null; then
    kubectl get networkpolicy -n default demo-app-ingress-only
    echo -e "${GREEN}✔ NetworkPolicy 'demo-app-ingress-only' is active${NC}\n"
else
    echo -e "${YELLOW}⚠ NetworkPolicy 'demo-app-ingress-only' not found${NC}\n"
fi

# 4. Ingress Annotations, Target Type & Routing Architecture
echo -e "${BOLD}${BLUE}[4/5] Checking Ingress Target Type & Architecture Alignment...${NC}"
ALB_ANNOTATIONS=$(kubectl get ingress demo-app -o jsonpath='{.metadata.annotations}' 2>/dev/null || true)
if echo "$ALB_ANNOTATIONS" | grep -q "alb.ingress.kubernetes.io/target-type"; then
    TARGET_TYPE=$(echo "$ALB_ANNOTATIONS" | jq -r '."alb.ingress.kubernetes.io/target-type"' 2>/dev/null || echo "detected")
    echo -e "${GREEN}✔ Ingress configured with target-type: '${TARGET_TYPE}'${NC}"
    if [[ "$TARGET_TYPE" == "instance" ]]; then
        echo -e "${GREEN}  ✔ Matches Network Team Recommendation: ALB routes directly to RKE2 Worker Nodes on Port 80/443${NC}"
    elif [[ "$TARGET_TYPE" == "ip" ]]; then
        echo -e "${CYAN}  ℹ Target-type 'ip': ALB routes directly to Pod IPs (Standard on AWS VPC CNI; for RKE2 with overlay CNI, 'instance' is recommended)${NC}"
    fi
elif echo "$ALB_ANNOTATIONS" | grep -q "kubernetes.io/ingress.class"; then
    INGRESS_CLASS=$(echo "$ALB_ANNOTATIONS" | jq -r '."kubernetes.io/ingress.class"' 2>/dev/null || echo "nginx")
    echo -e "${GREEN}✔ Ingress using in-cluster controller: ${INGRESS_CLASS} (Worker Node Ingress pattern)${NC}"
else
    echo -e "${YELLOW}⚠ Standard ALB ingress annotations not present on Ingress resource${NC}"
fi

# Check RKE2 NGINX client IP forwarding configuration
if kubectl get configmap -n kube-system rke2-ingress-nginx-controller &>/dev/null; then
    FORWARD_HEADER=$(kubectl get configmap -n kube-system rke2-ingress-nginx-controller -o jsonpath='{.data.use-forwarded-headers}' 2>/dev/null || echo "false")
    if [[ "$FORWARD_HEADER" == "true" ]]; then
        echo -e "${GREEN}✔ rke2-ingress-nginx configured with 'use-forwarded-headers: true' (Real Client IP preserved from ALB)${NC}"
    else
        echo -e "${YELLOW}⚠ rke2-ingress-nginx missing 'use-forwarded-headers: true'. Ingress may record ALB IP instead of client IP.${NC}"
    fi
fi

# 5. HTTPS Endpoint Verification
echo -e "${BOLD}${BLUE}[5/5] Probing Public HTTPS Endpoints (${APP_URL})...${NC}"

echo -e "Testing ${APP_URL}/healthz (Liveness Probe)..."
HTTP_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${APP_URL}/healthz" 2>/dev/null || echo "000")
HEALTH_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "${APP_URL}/healthz" 2>/dev/null || echo "Failed to connect")

if [[ "$HTTP_HEALTH_CODE" == "200" ]]; then
    echo -e "${GREEN}✔ /healthz returned HTTP 200 OK${NC}"
    echo -e "  Response: ${HEALTH_RESPONSE}"
else
    echo -e "${YELLOW}⚠ /healthz returned HTTP ${HTTP_HEALTH_CODE} (DNS or SSL certificate validation may still be propagating)${NC}"
    echo -e "  Response: ${HEALTH_RESPONSE}"
    if [[ "$HTTP_HEALTH_CODE" == "503" ]]; then
        if [[ "$CLUSTER_TYPE" == "EKS" && "$APP_SUBDOMAIN" != "app" ]]; then
            echo -e "${CYAN}  ℹ Diagnostic Hint: Connected cluster is AWS EKS where workloads serve at https://app.${DOMAIN_NAME}${NC}"
            echo -e "${CYAN}    To validate the active EKS cluster, run: ./scripts/validate.sh -d ${DOMAIN_NAME} -s app${NC}"
        elif [[ "$PLATFORM" == "rke2" ]]; then
            echo -e "${CYAN}  ℹ Diagnostic Hint: HTTP 503 means zero healthy EC2 worker instances are registered in the RKE2 ALB Target Group.${NC}"
            echo -e "${CYAN}    Add worker node instance IDs to 'worker_instance_ids' in rke2-alb-infra/terraform.tfvars and re-apply.${NC}"
        fi
    fi
fi

echo -e "\nTesting ${APP_URL}/ready (Readiness Probe)..."
HTTP_READY_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${APP_URL}/ready" 2>/dev/null || echo "000")
READY_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "${APP_URL}/ready" 2>/dev/null || echo "Failed to connect")

if [[ "$HTTP_READY_CODE" == "200" ]]; then
    echo -e "${GREEN}✔ /ready returned HTTP 200 OK${NC}"
    echo -e "  Response: ${READY_RESPONSE}"
else
    echo -e "${YELLOW}⚠ /ready returned HTTP ${HTTP_READY_CODE}${NC}"
fi

echo -e "\nTesting ${APP_URL}/api/info (Telemetry Payload)..."
HTTP_INFO_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${APP_URL}/api/info" 2>/dev/null || echo "000")
INFO_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "${APP_URL}/api/info" 2>/dev/null || echo "Failed to connect")

if [[ "$HTTP_INFO_CODE" == "200" ]]; then
    echo -e "${GREEN}✔ /api/info returned HTTP 200 OK${NC}"
    echo -e "  Response summary: $(echo "$INFO_RESPONSE" | jq '{version: .version, pod: .pod.name, node: .pod.node, client_ip: .ingress.client_ip}' 2>/dev/null || echo "$INFO_RESPONSE" | cut -c 1-120)"
else
    echo -e "${YELLOW}⚠ /api/info returned HTTP ${HTTP_INFO_CODE}${NC}"
fi

echo -e "\nTesting ${APP_URL}/ (Interactive Dashboard)..."
HTTP_ROOT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${APP_URL}/" 2>/dev/null || echo "000")
ROOT_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "${APP_URL}/" 2>/dev/null || echo "Failed to connect")

if [[ "$HTTP_ROOT_CODE" == "200" ]]; then
    echo -e "${GREEN}✔ / returned HTTP 200 OK (Interactive Web UI Dashboard served)${NC}"
else
    echo -e "${YELLOW}⚠ / returned HTTP ${HTTP_ROOT_CODE}${NC}"
fi

echo -e "\n${BOLD}${GREEN}✔ Verification script completed successfully.${NC}"


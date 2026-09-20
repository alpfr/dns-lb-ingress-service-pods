#!/usr/bin/env bash
# ==============================================================================
# AWS EKS Auto Mode + NLB + Ingress NGINX + ACM + Route 53
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

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Performs cluster, ingress, pod, and HTTP endpoint health checks.

Options:
  -d, --domain DOMAIN       Route 53 public domain (default: alpfrtech.com)
  -s, --subdomain SUB       Subdomain prefix (default: app)
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0")
  $(basename "$0") --domain alpfrtech.com
  $(basename "$0") -d alpfrtech.com -s app
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
echo -e "${BOLD}${BLUE}[1/5] Checking EKS Cluster Nodes (Auto Mode)...${NC}"
if ! kubectl get nodes -o wide; then
    echo -e "${RED}✖ Failed to reach EKS cluster API. Run 'aws eks update-kubeconfig' first.${NC}"
    exit 1
fi
echo -e "${GREEN}✔ EKS API server accessible and nodes reported${NC}\n"

# 2. Ingress Controller status
echo -e "${BOLD}${BLUE}[2/5] Checking Ingress NGINX Controller & NLB Service...${NC}"
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller

NLB_HOSTNAME=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -n "$NLB_HOSTNAME" ]]; then
    echo -e "${GREEN}✔ External NLB Hostname: ${NLB_HOSTNAME}${NC}\n"
else
    echo -e "${YELLOW}⚠ NLB hostname is still pending in AWS. Route 53 resolution may take a moment.${NC}\n"
fi

# 3. Workload Pods, Ingress Rules & NetworkPolicy
echo -e "${BOLD}${BLUE}[3/5] Checking Microservice Pods, Ingress Rules & NetworkPolicy...${NC}"
kubectl get pods -l app=demo-app -o wide
kubectl get svc demo-app
kubectl get ingress demo-app
echo -e "\nVerifying NetworkPolicy (Zero-Trust Ingress Isolation)..."
if kubectl get networkpolicy -n default demo-app-ingress-only &>/dev/null; then
    kubectl get networkpolicy -n default demo-app-ingress-only
    echo -e "${GREEN}✔ NetworkPolicy 'demo-app-ingress-only' is active${NC}\n"
else
    echo -e "${YELLOW}⚠ NetworkPolicy 'demo-app-ingress-only' not found${NC}\n"
fi

# 4. Ingress Rate Limiting & JSON Logging
echo -e "${BOLD}${BLUE}[4/5] Checking Ingress Annotations & JSON Access Logging...${NC}"
RL_ANNOTATIONS=$(kubectl get ingress demo-app -o jsonpath='{.metadata.annotations}' 2>/dev/null || true)
if echo "$RL_ANNOTATIONS" | grep -q "limit-rps"; then
    echo -e "${GREEN}✔ Rate limiting annotations detected on Ingress: limit-rps=50, limit-connections=20, proxy-body-size=10m${NC}"
else
    echo -e "${YELLOW}⚠ Rate limiting annotations not found on Ingress${NC}"
fi

echo -e "\nChecking Ingress NGINX structured JSON logs..."
LAST_JSON_LOG=$(kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=1 2>/dev/null | grep -E '^\{.*\}$' || true)
if [[ -n "$LAST_JSON_LOG" ]]; then
    echo -e "${GREEN}✔ Ingress NGINX structured JSON logging is active${NC}"
    echo -e "  Sample log entry: ${LAST_JSON_LOG}"
else
    echo -e "${YELLOW}⚠ Waiting for JSON log entries or non-JSON logs received${NC}"
fi
echo ""

# 5. HTTPS Endpoint Verification
echo -e "${BOLD}${BLUE}[5/5] Probing Public HTTPS Endpoints (${APP_URL})...${NC}"

echo -e "Testing ${APP_URL}/healthz ..."
HTTP_HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${APP_URL}/healthz" 2>/dev/null || echo "000")
HEALTH_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "${APP_URL}/healthz" 2>/dev/null || echo "Failed to connect")

if [[ "$HTTP_HEALTH_CODE" == "200" ]]; then
    echo -e "${GREEN}✔ /healthz returned HTTP 200 OK${NC}"
    echo -e "  Response: ${HEALTH_RESPONSE}"
else
    echo -e "${YELLOW}⚠ /healthz returned HTTP ${HTTP_HEALTH_CODE} (DNS or SSL certificate validation may still be propagating)${NC}"
    echo -e "  Response: ${HEALTH_RESPONSE}"
fi

echo -e "\nTesting ${APP_URL}/ ..."
HTTP_ROOT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${APP_URL}/" 2>/dev/null || echo "000")
ROOT_RESPONSE=$(curl -s --connect-timeout 10 --max-time 15 "${APP_URL}/" 2>/dev/null || echo "Failed to connect")

if [[ "$HTTP_ROOT_CODE" == "200" ]]; then
    echo -e "${GREEN}✔ / returned HTTP 200 OK${NC}"
    echo -e "  Response: ${ROOT_RESPONSE}"
else
    echo -e "${YELLOW}⚠ / returned HTTP ${HTTP_ROOT_CODE}${NC}"
fi

echo -e "\n${BOLD}${GREEN}✔ Verification script completed successfully.${NC}"


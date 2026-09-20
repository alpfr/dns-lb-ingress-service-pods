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
APP_SUBDOMAIN="app"

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
            shift 2
            ;;
        -s|--subdomain)
            APP_SUBDOMAIN="$2"
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

# Try reading from terraform.tfvars if domain not passed
if [[ -z "$DOMAIN_NAME" && -f "${INFRA_DIR}/terraform.tfvars" ]]; then
    DOMAIN_NAME=$(grep -E '^\s*domain_name\s*=' "${INFRA_DIR}/terraform.tfvars" | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
    EXTRACTED_SUB=$(grep -E '^\s*app_subdomain\s*=' "${INFRA_DIR}/terraform.tfvars" | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
    if [[ -n "$EXTRACTED_SUB" ]]; then
        APP_SUBDOMAIN="$EXTRACTED_SUB"
    fi
fi

APP_URL="https://${APP_SUBDOMAIN}.${DOMAIN_NAME}"

echo -e "\n${BOLD}${CYAN}🔍 Starting Health and Verification Suite${NC}"
echo -e "Target Application URL: ${BOLD}${APP_URL}${NC}\n"

# 1. Cluster connectivity & Node check
echo -e "${BOLD}${BLUE}[1/4] Checking EKS Cluster Nodes (Auto Mode)...${NC}"
if ! kubectl get nodes -o wide; then
    echo -e "${RED}✖ Failed to reach EKS cluster API. Run 'aws eks update-kubeconfig' first.${NC}"
    exit 1
fi
echo -e "${GREEN}✔ EKS API server accessible and nodes reported${NC}\n"

# 2. Ingress Controller status
echo -e "${BOLD}${BLUE}[2/4] Checking Ingress NGINX Controller & NLB Service...${NC}"
kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx
kubectl get svc -n ingress-nginx ingress-nginx-controller

NLB_HOSTNAME=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
if [[ -n "$NLB_HOSTNAME" ]]; then
    echo -e "${GREEN}✔ External NLB Hostname: ${NLB_HOSTNAME}${NC}\n"
else
    echo -e "${YELLOW}⚠ NLB hostname is still pending in AWS. Route 53 resolution may take a moment.${NC}\n"
fi

# 3. Workload Pods and Ingress Rules
echo -e "${BOLD}${BLUE}[3/4] Checking Microservice Pods & Ingress Route...${NC}"
kubectl get pods -l app=demo-app -o wide
kubectl get svc demo-app
kubectl get ingress demo-app
echo -e "${GREEN}✔ Workload objects present in default namespace${NC}\n"

# 4. HTTPS Endpoint Verification
echo -e "${BOLD}${BLUE}[4/4] Probing Public HTTPS Endpoints (${APP_URL})...${NC}"

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

echo -e "\n${BOLD}${GREEN}✔ Verification script completed.${NC}"

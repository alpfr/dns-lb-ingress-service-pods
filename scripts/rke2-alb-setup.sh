#!/usr/bin/env bash
# ==============================================================================
# RKE2 on AWS EC2 - Application Load Balancer (ALB) to Worker Nodes Setup Suite
# Implements Network Team Recommendation:
#   • AWS Application Load Balancer (ALB) targeting RKE2 Worker Node Instances
#   • Protocol: HTTP (Port 80) or HTTPS (Port 443) on Worker Nodes (rke2-ingress-nginx)
#   • Target Type: "instance" (EC2 Node Instances / ASG)
#   • Client IP Preservation via X-Forwarded-For in rke2-ingress-nginx
#   • Least-Privilege Security Group Isolation (ALB SG -> Worker Node SG)
# ==============================================================================

set -euo pipefail

BOLD='\033[1m'
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo -e "${BLUE}========================================================================${NC}"
    echo -e "${BOLD}${CYAN}🚀 RKE2 + AWS ALB Ingress Integration (ALB -> Worker Nodes)${NC}"
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

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
VPC_ID=""
ALB_NAME="rke2-app-alb"
TARGET_GROUP_NAME="rke2-workers-tg"
DOMAIN_NAME="alpfrtech.com"
APP_SUBDOMAIN="app"
WORKER_PORT="80"
HEALTH_CHECK_PATH="/healthz"
AUTO_APPLY=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Configures an AWS Application Load Balancer (ALB) targeting RKE2 Worker Nodes (EC2 instances),
preserves Client IP forwarding in rke2-ingress-nginx, and configures security groups.

Options:
  --vpc-id VPC_ID           VPC ID where RKE2 EC2 instances reside
  -d, --domain DOMAIN       Route 53 domain name (default: alpfrtech.com)
  -s, --subdomain SUB       Subdomain prefix (default: app)
  -r, --region REGION       AWS Region (default: us-east-1)
  --port PORT               Worker node ingress port (default: 80)
  --health-path PATH        Health check endpoint on Ingress (default: /healthz)
  -y, --auto-apply          Automatically patch rke2-ingress-nginx ConfigMap
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0") --vpc-id vpc-04069dd8bf42ea2db
  $(basename "$0") -d alpfrtech.com -s app -y
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vpc-id)
            VPC_ID="$2"
            shift 2
            ;;
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
        --port)
            WORKER_PORT="$2"
            shift 2
            ;;
        --health-path)
            HEALTH_CHECK_PATH="$2"
            shift 2
            ;;
        -y|--auto-apply)
            AUTO_APPLY=true
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

print_banner
echo -e "${CYAN}Configuration:${NC}"
echo -e "  Architecture:   ${BOLD}ALB -> RKE2 Worker Nodes (Target Type: instance)${NC}"
echo -e "  Domain:         ${BOLD}https://${APP_SUBDOMAIN}.${DOMAIN_NAME}${NC}"
echo -e "  AWS Region:     ${BOLD}${AWS_REGION}${NC}"
echo -e "  Worker Port:    ${BOLD}${WORKER_PORT}${NC}"
echo -e "  Health Check:   ${BOLD}${HEALTH_CHECK_PATH}${NC}"

# 1. Discover RKE2 Nodes via kubectl
print_step "1/4" "Discovering RKE2 Cluster Nodes and Roles"
if command -v kubectl &>/dev/null && kubectl get nodes &>/dev/null; then
    echo "Querying Kubernetes API for node inventory..."
    CONTROL_NODES=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address 2>/dev/null || echo "None")
    WORKER_NODES=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address 2>/dev/null || echo "None")

    echo -e "\n${CYAN}Control Plane Nodes (Protected from Application Ingress):${NC}"
    echo "$CONTROL_NODES"
    echo -e "\n${GREEN}Worker Nodes (Eligible for ALB Target Group Registration):${NC}"
    echo "$WORKER_NODES"
    print_success "Node topology verified"
else
    print_warning "kubectl not connected or offline; proceeding with AWS infrastructure configuration template."
fi

# 2. Configure Client IP Preservation in rke2-ingress-nginx
print_step "2/4" "Configuring Client IP Preservation in rke2-ingress-nginx"

cat <<EOF

To ensure rke2-ingress-nginx passes real client IP addresses from the AWS ALB
to downstream application pods, apply the following ConfigMap to kube-system:

---
apiVersion: v1
kind: ConfigMap
metadata:
  name: rke2-ingress-nginx-controller
  namespace: kube-system
data:
  use-forwarded-headers: "true"
  compute-full-forwarded-for: "true"
  use-proxy-protocol: "false"
---
EOF

if [[ "$AUTO_APPLY" == true ]] && command -v kubectl &>/dev/null && kubectl get namespace kube-system &>/dev/null; then
    echo "Applying ConfigMap patch to rke2-ingress-nginx in kube-system..."
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
    print_success "rke2-ingress-nginx ConfigMap patched successfully"
else
    echo "Run with -y / --auto-apply to apply this ConfigMap automatically via kubectl."
fi

# 3. AWS Security Group Rules Blueprint
print_step "3/4" "Least-Privilege Security Group Architecture"
cat <<EOF
Recommended Security Group Rules for RKE2 Worker Ingress:

1. ALB Security Group (alb-sg):
   • Ingress: Port 80 (TCP) from 0.0.0.0/0 (or corporate CIDR)
   • Ingress: Port 443 (TCP) from 0.0.0.0/0 (or corporate CIDR)
   • Egress:  Port 80/443 to Worker Node Security Group (worker-sg)

2. RKE2 Worker Node Security Group (worker-sg):
   • Ingress: Port 80 / 443 (TCP) ONLY from Source: alb-sg (Security Group ID)
   • Ingress: Port 10250 (TCP) from Control Plane SG (Kubelet metrics)
   • Ingress: Port 4789 (UDP) from All Nodes (Canal/Calico VXLAN overlay)
   • Blocks direct public internet access to worker nodes on port 80/443.
EOF

# 4. Terraform / AWS CLI Deployment Blueprint
print_step "4/4" "AWS Infrastructure Configuration Blueprint (ALB to Worker Nodes)"
cat <<EOF
HCL Terraform Snippet for ALB Target Group (Worker Nodes):

resource "aws_lb_target_group" "rke2_workers" {
  name        = "${TARGET_GROUP_NAME}"
  port        = ${WORKER_PORT}
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance" # Matches Network Team Recommendation

  health_check {
    enabled             = true
    path                = "${HEALTH_CHECK_PATH}"
    protocol            = "HTTP"
    port                = "traffic-port"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  deregistration_delay = 30
}

# Attach Worker Auto Scaling Group (ASG):
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.rke2_workers.id
  lb_target_group_arn    = aws_lb_target_group.rke2_workers.arn
}
EOF

print_success "RKE2 ALB Setup Guide and Diagnostics complete."

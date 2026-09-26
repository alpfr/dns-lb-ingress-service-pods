# ==============================================================================
# RKE2 Application Load Balancer (ALB) to Worker Nodes
# Implements Network Team Recommendation:
#   • AWS Application Load Balancer (Layer 7) routing directly to RKE2 Worker Nodes
#   • Target Type: "instance" (EC2 Node Instances / ASG)
#   • ACM TLS Termination on Port 443 with automated HTTP -> HTTPS redirect
#   • Route 53 A Alias record (zero hop latency, supports apex & subdomains)
#   • Least-privilege Security Group boundary (Workers allow port 80/443 strictly from ALB)
# ==============================================================================

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# Auto-discover public subnets in the VPC if not explicitly passed
data "aws_subnets" "public" {
  count = length(var.public_subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }
}

data "aws_subnets" "all_vpc" {
  count = length(var.public_subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

locals {
  alb_subnet_ids = length(var.public_subnet_ids) > 0 ? var.public_subnet_ids : (
    length(try(data.aws_subnets.public[0].ids, [])) >= 2 ? data.aws_subnets.public[0].ids : data.aws_subnets.all_vpc[0].ids
  )
}

# ------------------------------------------------------------------------------
# Route 53 & ACM TLS Certificate
# ------------------------------------------------------------------------------
data "aws_route53_zone" "existing" {
  count        = var.create_route53_zone ? 0 : 1
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_zone" "created" {
  count = var.create_route53_zone ? 1 : 0
  name  = var.domain_name
  tags  = var.tags
}

locals {
  route53_zone_id = var.create_route53_zone ? aws_route53_zone.created[0].zone_id : data.aws_route53_zone.existing[0].zone_id
}

resource "aws_acm_certificate" "app" {
  domain_name               = "${var.app_subdomain}.${var.domain_name}"
  subject_alternative_names = [var.domain_name, "*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  allow_overwrite = true
  zone_id         = local.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

resource "aws_route53_record" "caa" {
  zone_id         = local.route53_zone_id
  name            = var.domain_name
  type            = "CAA"
  ttl             = 300
  records         = ["0 issue \"amazon.com\"", "0 issuewild \"amazon.com\""]
  allow_overwrite = true
}

# ------------------------------------------------------------------------------
# Security Groups: ALB & Worker Node Isolation
# ------------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Public ingress security group for RKE2 Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "Public HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Public HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Outbound to VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name = "${var.name}-alb-sg"
  })
}

# Least-privilege ingress rule allowing worker nodes to receive traffic strictly from the ALB
resource "aws_security_group_rule" "worker_from_alb" {
  count                    = var.worker_security_group_id != "" ? 1 : 0
  type                     = "ingress"
  from_port                = var.ingress_port
  to_port                  = var.ingress_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb.id
  security_group_id        = var.worker_security_group_id
  description              = "Allow traffic from ALB to rke2-ingress-nginx on Worker Nodes"
}

# ------------------------------------------------------------------------------
# AWS Application Load Balancer (ALB)
# ------------------------------------------------------------------------------
resource "aws_lb" "rke2_app" {
  name               = substr("${var.name}-alb", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.alb_subnet_ids

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = merge(var.tags, {
    Name = "${var.name}-alb"
  })
}

# ------------------------------------------------------------------------------
# Target Group targeting Worker Nodes (target_type = "instance")
# ------------------------------------------------------------------------------
resource "aws_lb_target_group" "rke2_workers" {
  name        = substr("${var.name}-workers-tg", 0, 32)
  port        = var.ingress_port
  protocol    = var.ingress_protocol
  vpc_id      = var.vpc_id
  target_type = "instance" # Matches Network Team Recommendation

  deregistration_delay = var.deregistration_delay

  health_check {
    enabled             = true
    path                = var.health_check_path
    port                = var.health_check_port
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 15
    matcher             = "200"
  }

  tags = merge(var.tags, {
    Name = "${var.name}-workers-tg"
  })
}

# Attach static EC2 worker instances if provided
resource "aws_lb_target_group_attachment" "workers" {
  for_each         = toset(var.worker_instance_ids)
  target_group_arn = aws_lb_target_group.rke2_workers.arn
  target_id        = each.value
  port             = var.ingress_port
}

# Attach worker Auto Scaling Group (ASG) if provided
resource "aws_autoscaling_attachment" "asg_workers" {
  count                  = var.worker_asg_name != "" ? 1 : 0
  autoscaling_group_name = var.worker_asg_name
  lb_target_group_arn    = aws_lb_target_group.rke2_workers.arn
}

# ------------------------------------------------------------------------------
# ALB Listeners: Port 80 Redirect & Port 443 HTTPS
# ------------------------------------------------------------------------------
resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.rke2_app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.rke2_app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rke2_workers.arn
  }
}

# ------------------------------------------------------------------------------
# Route 53 A Alias Record
# ------------------------------------------------------------------------------
resource "aws_route53_record" "app" {
  zone_id         = local.route53_zone_id
  name            = "${var.app_subdomain}.${var.domain_name}"
  type            = "A"
  allow_overwrite = true

  alias {
    name                   = aws_lb.rke2_app.dns_name
    zone_id                = aws_lb.rke2_app.zone_id
    evaluate_target_health = true
  }
}


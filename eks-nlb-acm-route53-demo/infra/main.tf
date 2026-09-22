data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

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
  create_vpc      = var.vpc_id == ""
}

data "aws_vpc" "selected" {
  count = local.create_vpc ? 0 : 1
  id    = var.vpc_id
}

data "aws_subnets" "existing_private" {
  count = local.create_vpc ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "tag:kubernetes.io/role/internal-elb"
    values = ["1"]
  }
}

data "aws_subnets" "existing_non_public" {
  count = local.create_vpc ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "map-public-ip-on-launch"
    values = ["false"]
  }
}

data "aws_subnets" "existing_all" {
  count = local.create_vpc ? 0 : 1
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

locals {
  existing_subnets = local.create_vpc ? [] : (
    length(var.subnet_ids) > 0 ? var.subnet_ids : (
      length(try(data.aws_subnets.existing_private[0].ids, [])) >= 2 ? data.aws_subnets.existing_private[0].ids : (
        length(try(data.aws_subnets.existing_non_public[0].ids, [])) >= 2 ? data.aws_subnets.existing_non_public[0].ids : (
          data.aws_subnets.existing_all[0].ids
        )
      )
    )
  )

  cluster_vpc_id     = local.create_vpc ? module.vpc[0].vpc_id : var.vpc_id
  cluster_subnet_ids = local.create_vpc ? module.vpc[0].private_subnets : local.existing_subnets
}

module "vpc" {
  count   = local.create_vpc ? 1 : 0
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                                     = var.cluster_name
  kubernetes_version                       = "1.33"
  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = local.cluster_vpc_id
  subnet_ids = local.cluster_subnet_ids

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose"]
  }

  tags = var.tags
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
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

module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name                              = "${var.cluster_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = var.tags
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  wait       = true
  timeout    = 600

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.load_balancer_controller_irsa_role.iam_role_arn
      }
    }
    region = var.aws_region
    vpcId  = local.cluster_vpc_id
  })]

  depends_on = [
    module.eks,
    module.load_balancer_controller_irsa_role
  ]
}

resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = "demo-app"
    namespace = "default"
    labels = {
      app = "demo-app"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "demo-app"
      }
    }

    template {
      metadata {
        labels = {
          app = "demo-app"
        }
      }

      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = {
              app = "demo-app"
            }
          }
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          fs_group        = 10001

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "demo-app"
          image = var.app_image

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name  = "PORT"
            value = "8080"
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 5
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "tmp-volume"
            mount_path = "/tmp"
          }
        }

        volume {
          name = "tmp-volume"
          empty_dir {}
        }
      }
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_pod_disruption_budget_v1" "app" {
  metadata {
    name      = "demo-app"
    namespace = "default"
  }

  spec {
    min_available = "1"

    selector {
      match_labels = {
        app = "demo-app"
      }
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  metadata {
    name      = "demo-app"
    namespace = "default"
  }

  spec {
    min_replicas = 2
    max_replicas = 10

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.app.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }

    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_v1" "app" {
  metadata {
    name      = "demo-app"
    namespace = "default"
  }

  spec {
    selector = {
      app = "demo-app"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }

    type = "ClusterIP"
  }

  depends_on = [module.eks]
}

resource "kubernetes_ingress_v1" "app" {
  metadata {
    name      = "demo-app"
    namespace = "default"
    annotations = {
      "alb.ingress.kubernetes.io/scheme"               = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"          = "ip"
      "alb.ingress.kubernetes.io/certificate-arn"      = aws_acm_certificate_validation.app.certificate_arn
      "alb.ingress.kubernetes.io/listen-ports"         = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"         = "443"
      "alb.ingress.kubernetes.io/healthcheck-path"     = "/healthz"
      "alb.ingress.kubernetes.io/healthcheck-port"     = "traffic-port"
      "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTP"
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = "${var.app_subdomain}.${var.domain_name}"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.app.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_service_v1.app,
    aws_acm_certificate_validation.app
  ]
}

# Wait for AWS Load Balancer Controller to provision the ALB and assign a public hostname
resource "time_sleep" "wait_for_ingress_lb" {
  depends_on      = [kubernetes_ingress_v1.app]
  create_duration = "45s"
}

data "kubernetes_ingress_v1" "app" {
  metadata {
    name      = kubernetes_ingress_v1.app.metadata[0].name
    namespace = kubernetes_ingress_v1.app.metadata[0].namespace
  }

  depends_on = [time_sleep.wait_for_ingress_lb]
}

resource "aws_route53_record" "app" {
  zone_id         = local.route53_zone_id
  name            = "${var.app_subdomain}.${var.domain_name}"
  type            = "CNAME"
  ttl             = 60
  records         = [data.kubernetes_ingress_v1.app.status[0].load_balancer[0].ingress[0].hostname]
  allow_overwrite = true
}

resource "kubernetes_network_policy_v1" "app_ingress_isolation" {
  metadata {
    name      = "demo-app-ingress-only"
    namespace = "default"
  }

  spec {
    pod_selector {
      match_labels = {
        app = "demo-app"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        ip_block {
          cidr = local.create_vpc ? module.vpc[0].vpc_cidr_block : data.aws_vpc.selected[0].cidr_block
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }

  depends_on = [module.eks]
}

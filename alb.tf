resource "aws_lb" "n8n" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [aws_security_group.alb.id]
  subnets                    = module.vpc.public_subnets
  drop_invalid_header_fields = true
  idle_timeout               = 120
  enable_deletion_protection = var.deletion_protection

  # Who called which URL when: n8n CE has no audit log, so the edge provides it.
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

# ALB access logs only support SSE-S3, not a customer-managed KMS key.
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${local.name}-alb-logs-${local.account_id}"
  force_destroy = !var.deletion_protection
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
  }
}

data "aws_elb_service_account" "this" {}

data "aws_iam_policy_document" "alb_logs" {
  statement {
    sid       = "ELBLogDelivery"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

resource "aws_lb_target_group" "main" {
  name                 = "${local.name}-main"
  port                 = 5678
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "webhook" {
  count                = var.enable_queue_mode ? 1 : 0
  name                 = "${local.name}-webhook"
  port                 = 5678
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = module.vpc.vpc_id
  deregistration_delay = 30

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.n8n.arn
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
  load_balancer_arn = aws_lb.n8n.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.listener_certificate_arn

  # With auth enabled, everything not matched by a public rule below requires a Cognito login.
  dynamic "default_action" {
    for_each = var.enable_alb_auth ? [1] : []
    content {
      type  = "authenticate-cognito"
      order = 1

      authenticate_cognito {
        user_pool_arn              = aws_cognito_user_pool.n8n[0].arn
        user_pool_client_id        = aws_cognito_user_pool_client.alb[0].id
        user_pool_domain           = aws_cognito_user_pool_domain.n8n[0].domain
        session_timeout            = 28800
        on_unauthenticated_request = "authenticate"
      }
    }
  }

  default_action {
    type             = "forward"
    order            = var.enable_alb_auth ? 2 : 1
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# Public paths, never behind the upstream login. In queue mode, production webhooks go to the
# scalable webhook processors; test webhooks must hit main (the editor listens there).
locals {
  public_routes = {
    webhook = {
      priority = 10
      path     = "/webhook/*"
      target   = var.enable_queue_mode ? aws_lb_target_group.webhook[0].arn : aws_lb_target_group.main.arn
    }
    webhook-test = {
      priority = 20
      path     = "/webhook-test/*"
      target   = aws_lb_target_group.main.arn
    }
  }
}

resource "aws_lb_listener_rule" "public" {
  for_each     = local.public_routes
  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = each.value.target
  }

  condition {
    path_pattern {
      values = [each.value.path]
    }
  }
}

moved {
  from = aws_lb_listener_rule.webhook[0]
  to   = aws_lb_listener_rule.public["webhook"]
}

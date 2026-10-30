# Each tier only accepts traffic from the tier in front of it. No SSH anywhere.

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Public HTTPS ingress"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_redirect" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_n8n" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.n8n.id
  ip_protocol                  = "tcp"
  from_port                    = 5678
  to_port                      = 5678
}

# authenticate-cognito: the ALB itself calls the Cognito token/userinfo endpoints.
resource "aws_vpc_security_group_egress_rule" "alb_to_idp" {
  count             = var.enable_alb_auth ? 1 : 0
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_security_group" "n8n" {
  name        = "${local.name}-tasks"
  description = "n8n ECS tasks"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "n8n_from_alb" {
  security_group_id            = aws_security_group.n8n.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 5678
  to_port                      = 5678
}

# Workflows call arbitrary third-party APIs, so outbound stays open (via NAT).
resource "aws_vpc_security_group_egress_rule" "n8n_all" {
  security_group_id = aws_security_group.n8n.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db"
  description = "PostgreSQL, only from n8n tasks"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_n8n" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.n8n.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_security_group" "redis" {
  name        = "${local.name}-redis"
  description = "Redis queue, only from n8n tasks"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_n8n" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.n8n.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
}

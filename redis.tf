# Only used in queue mode (enable_queue_mode = true).

resource "random_password" "redis" {
  count   = var.enable_queue_mode ? 1 : 0
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "redis" {
  count                   = var.enable_queue_mode ? 1 : 0
  name                    = "${local.name}/redis-auth-token"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "redis" {
  count         = var.enable_queue_mode ? 1 : 0
  secret_id     = aws_secretsmanager_secret.redis[0].id
  secret_string = random_password.redis[0].result
}

resource "aws_elasticache_subnet_group" "n8n" {
  count      = var.enable_queue_mode ? 1 : 0
  name       = local.name
  subnet_ids = module.vpc.private_subnets
}

# Bull requires noeviction, otherwise queued jobs can silently disappear under memory pressure.
resource "aws_elasticache_parameter_group" "n8n" {
  count  = var.enable_queue_mode ? 1 : 0
  name   = "${local.name}-redis7"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }
}

resource "aws_elasticache_replication_group" "n8n" {
  count                = var.enable_queue_mode ? 1 : 0
  replication_group_id = local.name
  description          = "n8n queue mode (Bull)"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t4g.micro"
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.n8n[0].name

  num_cache_clusters         = var.redis_ha ? 2 : 1
  automatic_failover_enabled = var.redis_ha
  multi_az_enabled           = var.redis_ha

  subnet_group_name  = aws_elasticache_subnet_group.n8n[0].name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.main.arn
  transit_encryption_enabled = true
  auth_token                 = random_password.redis[0].result

  snapshot_retention_limit = 1
  apply_immediately        = true
}

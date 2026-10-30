resource "aws_ecs_cluster" "n8n" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "n8n" {
  cluster_name       = aws_ecs_cluster.n8n.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

locals {
  env_common = {
    N8N_HOST            = var.hostname
    N8N_PORT            = "5678"
    N8N_PROTOCOL        = "https"
    N8N_EDITOR_BASE_URL = "https://${var.hostname}/"
    WEBHOOK_URL         = "https://${var.hostname}/"
    N8N_PROXY_HOPS      = "1"
    GENERIC_TIMEZONE    = var.timezone
    TZ                  = var.timezone

    DB_TYPE                               = "postgresdb"
    DB_POSTGRESDB_HOST                    = aws_db_instance.n8n.address
    DB_POSTGRESDB_PORT                    = "5432"
    DB_POSTGRESDB_DATABASE                = "n8n"
    DB_POSTGRESDB_USER                    = "n8n"
    DB_POSTGRESDB_SSL_ENABLED             = "true"
    DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED = "false"

    # Fixes the unbounded DB growth: keep 7 days / max 50k executions.
    EXECUTIONS_DATA_PRUNE           = "true"
    EXECUTIONS_DATA_MAX_AGE         = "168"
    EXECUTIONS_DATA_PRUNE_MAX_COUNT = "50000"

    N8N_DIAGNOSTICS_ENABLED               = "false"
    N8N_VERSION_NOTIFICATIONS_ENABLED     = "false"
    N8N_PERSONALIZATION_ENABLED           = "false"
    N8N_BLOCK_ENV_ACCESS_IN_NODE          = "true"
    N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS = "true"
    N8N_LOG_FORMAT                        = "json"

    # filesystem mode is not supported across processes in queue mode.
    N8N_DEFAULT_BINARY_DATA_MODE  = var.enable_queue_mode ? "database" : "filesystem"
    N8N_GRACEFUL_SHUTDOWN_TIMEOUT = "90"

    # Leave headroom below the task limit so Node fails gracefully instead of being OOM-killed.
    NODE_OPTIONS = "--max-old-space-size=${floor(var.task_memory * 0.75)}"
  }

  env_queue = { for k, v in {
    EXECUTIONS_MODE                      = "queue"
    QUEUE_BULL_REDIS_HOST                = one(aws_elasticache_replication_group.n8n[*].primary_endpoint_address)
    QUEUE_BULL_REDIS_PORT                = "6379"
    QUEUE_BULL_REDIS_TLS                 = "true"
    QUEUE_HEALTH_CHECK_ACTIVE            = "true"
    OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS = "true"
  } : k => v if var.enable_queue_mode }

  container_secrets = concat(
    [
      { name = "N8N_ENCRYPTION_KEY", valueFrom = aws_secretsmanager_secret.encryption_key.arn },
      { name = "DB_POSTGRESDB_PASSWORD", valueFrom = aws_secretsmanager_secret.db.arn },
    ],
    [for arn in aws_secretsmanager_secret.redis[*].arn : { name = "QUEUE_BULL_REDIS_PASSWORD", valueFrom = arn }],
  )

  base_container = {
    name         = "n8n"
    image        = var.n8n_image
    essential    = true
    stopTimeout  = 120
    portMappings = [{ containerPort = 5678, protocol = "tcp" }]
    environment  = [for k, v in merge(local.env_common, local.env_queue) : { name = k, value = v }]
    secrets      = local.container_secrets
    linuxParameters = {
      initProcessEnabled = true
    }
  }

  log_options = {
    awslogs-group  = aws_cloudwatch_log_group.n8n.name
    awslogs-region = var.region
  }
}

# --- main: UI, API, triggers/schedules. Exactly one instance (no multi-main in Community Edition).

resource "aws_ecs_task_definition" "main" {
  family                   = "${local.name}-main"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([merge(local.base_container, {
    logConfiguration = {
      logDriver = "awslogs"
      options   = merge(local.log_options, { awslogs-stream-prefix = "main" })
    }
  })])
}

resource "aws_ecs_service" "main" {
  name                   = "${local.name}-main"
  cluster                = aws_ecs_cluster.n8n.id
  task_definition        = aws_ecs_task_definition.main.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true
  propagate_tags         = "SERVICE"

  # Stop old before starting new: two mains would double-fire schedules and race DB migrations.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100
  health_check_grace_period_seconds  = 180

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.n8n.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "n8n"
    container_port   = 5678
  }

  depends_on = [aws_lb_listener.https, aws_iam_role_policy.execution_secrets]
}

# --- workers: execute jobs from the Redis queue (queue mode only).

resource "aws_ecs_task_definition" "worker" {
  count                    = var.enable_queue_mode ? 1 : 0
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([merge(local.base_container, {
    command = ["worker", "--concurrency=10"]
    logConfiguration = {
      logDriver = "awslogs"
      options   = merge(local.log_options, { awslogs-stream-prefix = "worker" })
    }
  })])
}

resource "aws_ecs_service" "worker" {
  count                  = var.enable_queue_mode ? 1 : 0
  name                   = "${local.name}-worker"
  cluster                = aws_ecs_cluster.n8n.id
  task_definition        = aws_ecs_task_definition.worker[0].arn
  desired_count          = var.worker_min
  enable_execute_command = true
  propagate_tags         = "SERVICE"

  # Baseline on regular Fargate, peak capacity on Spot.
  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.worker_min
    weight            = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.n8n.id]
    assign_public_ip = false
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.n8n, aws_iam_role_policy.execution_secrets]
}

# --- webhook processors: receive /webhook/* and enqueue (queue mode only).

resource "aws_ecs_task_definition" "webhook" {
  count                    = var.enable_queue_mode ? 1 : 0
  family                   = "${local.name}-webhook"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([merge(local.base_container, {
    command = ["webhook"]
    logConfiguration = {
      logDriver = "awslogs"
      options   = merge(local.log_options, { awslogs-stream-prefix = "webhook" })
    }
  })])
}

resource "aws_ecs_service" "webhook" {
  count                             = var.enable_queue_mode ? 1 : 0
  name                              = "${local.name}-webhook"
  cluster                           = aws_ecs_cluster.n8n.id
  task_definition                   = aws_ecs_task_definition.webhook[0].arn
  desired_count                     = var.webhook_min
  launch_type                       = "FARGATE"
  enable_execute_command            = true
  propagate_tags                    = "SERVICE"
  health_check_grace_period_seconds = 120

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.n8n.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.webhook[0].arn
    container_name   = "n8n"
    container_port   = 5678
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_lb_listener_rule.public, aws_iam_role_policy.execution_secrets]
}

# Queue mode only: CPU target tracking plus scheduled pre-scaling for the known peaks.

locals {
  scaled_services = var.enable_queue_mode ? {
    worker  = { service = aws_ecs_service.worker[0].name, min = var.worker_min, max = var.worker_max }
    webhook = { service = aws_ecs_service.webhook[0].name, min = var.webhook_min, max = var.webhook_max }
  } : {}

  worker_schedules = var.enable_queue_mode ? merge([
    for k, w in var.worker_peak_windows : {
      "${k}-up"   = { cron = w.start, min = var.worker_peak_min }
      "${k}-down" = { cron = w.end, min = var.worker_min }
    }
  ]...) : {}
}

resource "aws_appautoscaling_target" "svc" {
  for_each           = local.scaled_services
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.n8n.name}/${each.value.service}"
  min_capacity       = each.value.min
  max_capacity       = each.value.max

  lifecycle {
    ignore_changes = [min_capacity]
  }
}

resource "aws_appautoscaling_policy" "cpu" {
  for_each           = aws_appautoscaling_target.svc
  name               = "${local.name}-${each.key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = each.value.service_namespace
  scalable_dimension = each.value.scalable_dimension
  resource_id        = each.value.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_scheduled_action" "worker" {
  for_each           = local.worker_schedules
  name               = "${local.name}-worker-${each.key}"
  service_namespace  = aws_appautoscaling_target.svc["worker"].service_namespace
  scalable_dimension = aws_appautoscaling_target.svc["worker"].scalable_dimension
  resource_id        = aws_appautoscaling_target.svc["worker"].resource_id
  schedule           = each.value.cron
  timezone           = var.timezone

  scalable_target_action {
    min_capacity = each.value.min
    max_capacity = var.worker_max
  }
}

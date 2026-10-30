resource "aws_cloudwatch_log_group" "n8n" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = aws_kms_key.main.arn
}

# Must be confirmed once via the email AWS sends.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

data "aws_iam_policy_document" "alarms_topic" {
  # SNS topic policies don't accept "sns:*"; this is the default owner action set.
  statement {
    sid = "AccountAdmin"
    actions = [
      "SNS:GetTopicAttributes",
      "SNS:SetTopicAttributes",
      "SNS:AddPermission",
      "SNS:RemovePermission",
      "SNS:DeleteTopic",
      "SNS:Subscribe",
      "SNS:ListSubscriptionsByTopic",
      "SNS:Publish",
    ]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "AlarmsAndEvents"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}

locals {
  alb_dims  = { LoadBalancer = aws_lb.n8n.arn_suffix }
  tg_dims   = { LoadBalancer = aws_lb.n8n.arn_suffix, TargetGroup = aws_lb_target_group.main.arn_suffix }
  main_dims = { ClusterName = aws_ecs_cluster.n8n.name, ServiceName = aws_ecs_service.main.name }
  db_dims   = { DBInstanceIdentifier = aws_db_instance.n8n.identifier }

  alarms = {
    alb-5xx = {
      description = "ALB/target 5xx responses (webhooks failing)"
      namespace   = "AWS/ApplicationELB", metric = "HTTPCode_Target_5XX_Count", statistic = "Sum"
      comparison  = "GreaterThanThreshold", threshold = 10, periods = 1, missing = "notBreaching"
      dimensions  = tomap(local.alb_dims)
    }
    n8n-down = {
      description = "No healthy n8n main task behind the ALB"
      namespace   = "AWS/ApplicationELB", metric = "HealthyHostCount", statistic = "Minimum"
      comparison  = "LessThanThreshold", threshold = 1, periods = 2, missing = "breaching"
      dimensions  = tomap(local.tg_dims)
    }
    slow-responses = {
      description = "Average response time above 5s"
      namespace   = "AWS/ApplicationELB", metric = "TargetResponseTime", statistic = "Average"
      comparison  = "GreaterThanThreshold", threshold = 5, periods = 3, missing = "notBreaching"
      dimensions  = tomap(local.alb_dims)
    }
    main-cpu = {
      description = "n8n main CPU high"
      namespace   = "AWS/ECS", metric = "CPUUtilization", statistic = "Average"
      comparison  = "GreaterThanThreshold", threshold = 85, periods = 3, missing = "notBreaching"
      dimensions  = tomap(local.main_dims)
    }
    main-memory = {
      description = "n8n main memory high (OOM risk)"
      namespace   = "AWS/ECS", metric = "MemoryUtilization", statistic = "Average"
      comparison  = "GreaterThanThreshold", threshold = 85, periods = 3, missing = "notBreaching"
      dimensions  = tomap(local.main_dims)
    }
    db-cpu = {
      description = "RDS CPU high"
      namespace   = "AWS/RDS", metric = "CPUUtilization", statistic = "Average"
      comparison  = "GreaterThanThreshold", threshold = 80, periods = 3, missing = "notBreaching"
      dimensions  = tomap(local.db_dims)
    }
    db-storage = {
      description = "RDS free storage below 5 GB"
      namespace   = "AWS/RDS", metric = "FreeStorageSpace", statistic = "Minimum"
      comparison  = "LessThanThreshold", threshold = 5368709120, periods = 1, missing = "notBreaching"
      dimensions  = tomap(local.db_dims)
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  comparison_operator = each.value.comparison
  threshold           = each.value.threshold
  evaluation_periods  = each.value.periods
  period              = 300
  treat_missing_data  = each.value.missing
  dimensions          = each.value.dimensions

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# Managed backups on top of RDS automated backups (7 days PITR): daily snapshots kept 35 days,
# monthly kept 1 year, in a KMS-encrypted vault that is separate from the DB lifecycle.

resource "aws_backup_vault" "n8n" {
  name          = local.name
  kms_key_arn   = aws_kms_key.main.arn
  force_destroy = !var.deletion_protection
}

resource "aws_backup_plan" "n8n" {
  name = local.name

  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.n8n.name
    schedule          = "cron(0 3 * * ? *)"
    start_window      = 60
    completion_window = 180

    lifecycle {
      delete_after = 35
    }
  }

  rule {
    rule_name         = "monthly"
    target_vault_name = aws_backup_vault.n8n.name
    schedule          = "cron(0 4 1 * ? *)"

    lifecycle {
      delete_after = 365
    }
  }
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${local.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

resource "aws_backup_selection" "n8n" {
  name         = "${local.name}-db"
  plan_id      = aws_backup_plan.n8n.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_db_instance.n8n.arn]
}

resource "aws_cloudwatch_event_rule" "backup_failed" {
  name        = "${local.name}-backup-failed"
  description = "AWS Backup job for n8n failed"
  event_pattern = jsonencode({
    source        = ["aws.backup"]
    "detail-type" = ["Backup Job State Change"]
    detail = {
      state           = ["FAILED", "ABORTED", "EXPIRED"]
      backupVaultName = [aws_backup_vault.n8n.name]
    }
  })
}

resource "aws_cloudwatch_event_target" "backup_failed" {
  rule = aws_cloudwatch_event_rule.backup_failed.name
  arn  = aws_sns_topic.alarms.arn
}

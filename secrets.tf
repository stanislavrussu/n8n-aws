# Ephemeral + write-only: these secrets never land in Terraform state or plan.
# Bumping *_wo_version would generate a NEW value; never do that for the encryption key
# (all stored n8n credentials would become unreadable).

ephemeral "random_password" "encryption_key" {
  length  = 48
  special = false
}

ephemeral "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "encryption_key" {
  name                    = "${local.name}/n8n-encryption-key"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "encryption_key" {
  secret_id                = aws_secretsmanager_secret.encryption_key.id
  secret_string_wo         = ephemeral.random_password.encryption_key.result
  secret_string_wo_version = 1
}

resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name}/db-password"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id                = aws_secretsmanager_secret.db.id
  secret_string_wo         = ephemeral.random_password.db.result
  secret_string_wo_version = 1
}

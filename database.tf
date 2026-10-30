resource "aws_db_parameter_group" "n8n" {
  name   = "${local.name}-pg17"
  family = "postgres17"

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "2000"
  }
}

resource "aws_db_instance" "n8n" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = "17"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name             = "n8n"
  username            = "n8n"
  password_wo         = ephemeral.random_password.db.result
  password_wo_version = 1

  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  parameter_group_name   = aws_db_parameter_group.n8n.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period    = 7
  backup_window              = "01:00-02:00"
  maintenance_window         = "sun:02:30-sun:03:30"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = "${local.name}-final"
}

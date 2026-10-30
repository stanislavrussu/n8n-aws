output "url" {
  value = "https://${var.hostname}/"
}

output "alb_dns_name" {
  value = aws_lb.n8n.dns_name
}

output "route53_name_servers" {
  description = "Parent zone must delegate var.domain_zone to these."
  value       = data.aws_route53_zone.this.name_servers
}

output "ecs_cluster" {
  value = aws_ecs_cluster.n8n.name
}

output "log_group" {
  value = aws_cloudwatch_log_group.n8n.name
}

output "db_endpoint" {
  value = aws_db_instance.n8n.address
}

output "shell_into_main" {
  description = "ECS Exec replaces SSH (needs the session-manager-plugin)."
  value       = "aws ecs execute-command --cluster ${aws_ecs_cluster.n8n.name} --container n8n --interactive --command /bin/sh --task $(aws ecs list-tasks --cluster ${aws_ecs_cluster.n8n.name} --service-name ${aws_ecs_service.main.name} --query 'taskArns[0]' --output text)"
}

output "cognito_user_pool_id" {
  description = "Add users: aws cognito-idp admin-create-user --user-pool-id <id> --username <email>"
  value       = one(aws_cognito_user_pool.n8n[*].id)
}

output "backup_vault" {
  value = aws_backup_vault.n8n.name
}

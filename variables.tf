variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  type    = string
  default = "n8n"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "domain_zone" {
  description = "Public Route53 hosted zone."
  type        = string
}

variable "hostname" {
  description = "FQDN under which n8n is served."
  type        = string
}

variable "certificate_mode" {
  description = "acm = DNS-validated ACM cert (needs NS delegation of domain_zone); self_signed = temporary fallback."
  type        = string
  default     = "acm"

  validation {
    condition     = contains(["acm", "self_signed"], var.certificate_mode)
    error_message = "certificate_mode must be acm or self_signed."
  }
}

variable "alarm_email" {
  type = string
}

variable "n8n_image" {
  description = "Pinned n8n image; bump deliberately, never use :latest."
  type        = string
  default     = "docker.n8n.io/n8nio/n8n:2.43.8"
}

variable "timezone" {
  type    = string
  default = "Europe/Berlin"
}

variable "vpc_cidr" {
  type    = string
  default = "10.40.0.0/16"
}

variable "single_nat_gateway" {
  description = "One NAT for all AZs (cheaper, not AZ-resilient)."
  type        = bool
  default     = true
}

variable "task_cpu" {
  type    = number
  default = 1024
}

variable "task_memory" {
  type    = number
  default = 2048
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "deletion_protection" {
  description = "Protect ALB/RDS from deletion and keep a final DB snapshot."
  type        = bool
  default     = false
}

variable "enable_queue_mode" {
  description = "Redis + dedicated worker and webhook services."
  type        = bool
  default     = false
}

variable "enable_alb_auth" {
  description = "Require a Cognito login at the ALB for everything except /webhook/* and /webhook-test/*."
  type        = bool
  default     = false
}

variable "auth_users" {
  description = "Emails that get a Cognito account (invitation with temporary password is emailed)."
  type        = list(string)
  default     = []
}

variable "redis_ha" {
  type    = bool
  default = false
}

variable "worker_min" {
  type    = number
  default = 1
}

variable "worker_peak_min" {
  description = "Minimum workers during worker_peak_windows."
  type        = number
  default     = 3
}

variable "worker_peak_windows" {
  description = "Known peak windows (cron in var.timezone): workers are pre-scaled to worker_peak_min at start and back to worker_min at end."
  type        = map(object({ start = string, end = string }))
  default = {
    morning = { start = "cron(0 7 * * ? *)", end = "cron(0 10 * * ? *)" }
    evening = { start = "cron(0 17 * * ? *)", end = "cron(0 20 * * ? *)" }
  }
}

variable "worker_max" {
  type    = number
  default = 6
}

variable "webhook_min" {
  description = "At least 2 (one per AZ) so partner webhooks survive a task/AZ failure and rolling deploys."
  type        = number
  default     = 2
}

variable "webhook_max" {
  type    = number
  default = 4
}

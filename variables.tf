variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-west-3"
}

variable "project_name" {
  description = "Prefix applied to all resource names/tags"
  type        = string
  default     = "cv-project"
}

variable "environment" {
  description = "Deployment environment (dev/prod)"
  type        = string
  default     = "dev"
}

variable "db_name" {
  description = "Name of the MySQL database created on the RDS instance"
  type        = string
  default     = "cv"
}

variable "db_username" {
  description = "Master username for the RDS instance"
  type        = string
  default     = "cv"
}

variable "db_password" {
  description = "Master password for the RDS instance"
  type        = string
  sensitive   = true
}

variable "domain_service_instance_type" {
  description = "EC2 instance type for cv-domain-service (Free Tier: t2.micro/t3.micro)"
  type        = string
  default     = "t3.micro"
}

variable "drone_instance_type" {
  # T-002 (H1, ratified 2026-08-04): Free Tier already covers one t3.micro
  # (this account runs two -> domain_service + drone -> so ~710 h/month was
  # already billable before this change, ~$8/mo). t3.micro (1 GB) cannot
  # host Jenkins + Maven alongside Drone without OOM risk, so this box is
  # sized up. t3.small (2 GB) ~= $16.60/mo, a net +$8/mo over today. This is
  # a deliberate, recorded exception to the workspace's Free-Tier-only rule
  # for this resource only (see terraform.tfvars.example and the T-002 PR
  # body for the same figure) -- the docs correction itself is T-003.
  description = "EC2 instance type for the Drone + Jenkins CI host"
  type        = string
  default     = "t3.small"
}

variable "drone_admin_username" {
  description = "GitHub username granted Drone admin and allowed to log in"
  type        = string
  default     = "erfeamor"
}

variable "drone_rpc_secret" {
  description = "Shared secret between the Drone server and runner (openssl rand -hex 16)"
  type        = string
  sensitive   = true
}

variable "drone_github_client_id" {
  description = "Client ID of the GitHub OAuth app used by Drone"
  type        = string
}

variable "drone_github_client_secret" {
  description = "Client secret of the GitHub OAuth app used by Drone"
  type        = string
  sensitive   = true
}

variable "jenkins_admin_username" {
  description = "Local Jenkins admin username configured via JCasC on first boot (not a secret, mirrors drone_admin_username)"
  type        = string
  default     = "erfeamor"
}

variable "jenkins_admin_password" {
  description = "Local Jenkins admin password, read from SSM by the provisioning script and injected via env var only -- never written to a file on the host or committed to tfvars (openssl rand -base64 24)"
  type        = string
  sensitive   = true
}

variable "github_pat_ci" {
  description = "GitHub PAT Jenkins uses to check out branches and post commit statuses on cv-domain-service and cv-database. Least privilege: repo:status (classic) or fine-grained Commit-statuses:read/write scoped to just those two repos -- never bare 'repo' scope."
  type        = string
  sensitive   = true
}

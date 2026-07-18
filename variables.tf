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
  description = "EC2 instance type for the Drone CI host (Free Tier: t2.micro/t3.micro)"
  type        = string
  default     = "t3.micro"
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

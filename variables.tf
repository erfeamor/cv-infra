variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
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

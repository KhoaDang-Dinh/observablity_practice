variable "aws_region" {
  description = "AWS region for the lab."
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "day3-observe"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR for the Day 3 lab VPC."
  type        = string
  default     = "10.60.0.0/16"
}

variable "node_instance_types" {
  description = "Allowed instance types for the managed node group. Keep this small for the lab."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_min_size" {
  description = "Keep two workers so rolling updates and observability pods have scheduling headroom."
  type        = number
  default     = 2
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_disk_size_gib" {
  description = "Encrypted gp3 root disk size per worker."
  type        = number
  default     = 20
}

variable "ecr_repository_name" {
  type    = string
  default = "day3-backend"
}

variable "enable_control_plane_logs" {
  description = "Enable EKS API/audit/authenticator logs. Useful for learning but adds CloudWatch ingestion/storage cost."
  type        = bool
  default     = false
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class. db.t3.large provides 8 GiB RAM."
  type        = string
  default     = "db.t3.large"
}

variable "db_allocated_storage_gib" {
  description = "Initial PostgreSQL gp3 storage size."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage_gib" {
  description = "Maximum autoscaled PostgreSQL storage size."
  type        = number
  default     = 100
}

variable "db_name" {
  description = "Application database name."
  type        = string
  default     = "observability"
}

variable "db_username" {
  description = "RDS master username. Password is managed by AWS Secrets Manager."
  type        = string
  default     = "appadmin"
}


variable "enable_aws_finops" {
  description = "Create AWS cost-allocation tag activation and the monthly project budget. Disabled by default until the Terraform role has Billing permissions."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for the day3-cicd-lgtm project."
  type        = number
  default     = 400
}

variable "budget_alert_email" {
  description = "Optional email for AWS Budget notifications. Leave empty to create the budget without email notifications."
  type        = string
  default     = ""
}

variable "enable_cur2_export" {
  description = "Create a CUR 2.0 Data Export with hourly resource-level cost data in a dedicated S3 bucket."
  type        = bool
  default     = false
}

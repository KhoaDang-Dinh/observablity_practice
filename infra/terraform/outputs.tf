output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "db_endpoint" {
  value = aws_db_instance.postgres.address
}

output "db_port" {
  value = aws_db_instance.postgres.port
}

output "db_name" {
  value = aws_db_instance.postgres.db_name
}

output "db_master_secret_arn" {
  value     = try(aws_db_instance.postgres.master_user_secret[0].secret_arn, null)
  sensitive = true
}

output "telemetry_bucket_name" {
  value = data.aws_s3_bucket.telemetry.bucket
}

output "telemetry_prefixes" {
  value = local.telemetry_prefixes
}

output "telemetry_pod_identity_role_arns" {
  value = { for name, role in aws_iam_role.telemetry_s3 : name => role.arn }
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "selected_node_instance_type" {
  value = var.selected_node_instance_type
}

output "benchmark_mode" {
  value = var.benchmark_mode
}

output "availability_zones" {
  description = "The two AZs available to the recoverable EKS/RDS design."
  value       = local.azs
}

output "db_backup_retention_days" {
  description = "Automated RDS backup/PITR retention configured for Single-AZ recovery."
  value       = aws_db_instance.postgres.backup_retention_period
}

output "recovery_profile" {
  description = "Summary of the low-cost recovery posture."
  value = {
    eks_normal_workers = var.node_desired_size
    eks_max_workers    = var.node_max_size
    eks_subnets        = module.vpc.public_subnets
    rds_multi_az       = aws_db_instance.postgres.multi_az
    rds_backup_days    = aws_db_instance.postgres.backup_retention_period
  }
}

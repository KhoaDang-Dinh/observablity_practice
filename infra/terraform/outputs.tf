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

output "ecr_repository_url" {
  value = aws_ecr_repository.backend.repository_url
}

output "github_actions_role_arn" {
  description = "Store this ARN in GitHub Actions as AWS_ROLE_ARN."
  value       = aws_iam_role.github_ecr.arn
}

output "update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}
# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "eks_secrets_manager_role_arn" {
  description = "ARN of the EKS Secrets Manager IAM role"
  value       = aws_iam_role.eks_secrets_role.arn
}

output "vpc_peering_connection_id" {
  description = "ID of the VPC peering connection to MongoDB"
  value       = aws_vpc_peering_connection.eks_to_mongodb.id
}
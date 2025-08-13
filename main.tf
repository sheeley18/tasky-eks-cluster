provider "aws" {
  region = var.region
}

resource "aws_vpc" "new_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.new_vpc.id
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.new_vpc.id
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.new_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
}

resource "aws_route_table_association" "public_subnet_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.new_vpc.id
  cidr_block = "10.0.4.0/24"
  availability_zone = "us-east-1a"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.new_vpc.id
  cidr_block = "10.0.5.0/24"
  availability_zone = "us-east-1b"
}

locals {
  cluster_name = "pse-tasky-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_subnet.id
  tags = { Name = "pse-tasky-nat-gateway" }
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.new_vpc.id
  tags = { Name = "pse-tasky-private-rt" }
}

resource "aws_route" "private_nat_route" {
  route_table_id         = aws_route_table.private_rt.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_subnet_assoc_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_subnet_assoc_2" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_rt.id
}

# Data source to get MongoDB VPC by actual ID
data "aws_vpc" "mongodb_vpc" {
  id = "vpc-0828a5cb74c8482ff"  
}

# Data source to get MongoDB private route table
data "aws_route_tables" "mongodb_private" {
  vpc_id = data.aws_vpc.mongodb_vpc.id
  filter {
    name   = "association.main"
    values = ["false"]
  }
}

# VPC Peering Connection
resource "aws_vpc_peering_connection" "eks_to_mongodb" {
  peer_vpc_id = data.aws_vpc.mongodb_vpc.id
  vpc_id      = aws_vpc.new_vpc.id
  auto_accept = true

  tags = {
    Name = "EKS-to-MongoDB-Peering"
  }
}

# Route for EKS private subnets to reach MongoDB VPC
resource "aws_route" "eks_to_mongodb" {
  route_table_id            = aws_route_table.private_rt.id
  destination_cidr_block    = "192.168.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.eks_to_mongodb.id
}

# Routes for MongoDB VPC to reach EKS VPC
resource "aws_route" "mongodb_to_eks" {
  count                     = length(data.aws_route_tables.mongodb_private.ids)
  route_table_id            = data.aws_route_tables.mongodb_private.ids[count.index]
  destination_cidr_block    = "10.0.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.eks_to_mongodb.id
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = aws_vpc.new_vpc.id
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"
  }

  eks_managed_node_groups = {
    one = {
      name = "node-group-1"
      instance_types = ["t3.small"]
      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
    two = {
      name = "node-group-2"
      instance_types = ["t3.small"]
      min_size     = 1
      max_size     = 2
      desired_size = 1
    }
  }
}

data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

# IAM role for EKS to access Secrets Manager
resource "aws_iam_role" "eks_secrets_role" {
  name = "eks-secrets-manager-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${replace(module.eks.oidc_provider, "https://", "")}:sub": "system:serviceaccount:default:tasky-service-account"
            "${replace(module.eks.oidc_provider, "https://", "")}:aud": "sts.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Policy to access the MongoDB secrets
resource "aws_iam_role_policy" "eks_secrets_policy" {
  name = "eks-secrets-manager-policy"
  role = aws_iam_role.eks_secrets_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:us-east-1:442042553076:secret:tasky/database/credentials-*"
      }
    ]
  })
}

# Install AWS Secrets Store CSI Driver
resource "helm_release" "secrets_store_csi_driver" {
  name       = "secrets-store-csi-driver"
  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"
  namespace  = "kube-system"

  set {
    name  = "syncSecret.enabled"
    value = "true"
  }

  depends_on = [module.eks]
}

# Install AWS Secrets Store CSI Driver Provider
resource "helm_release" "aws_secrets_provider" {
  name       = "secrets-store-csi-driver-provider-aws"
  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"
  namespace  = "kube-system"

  depends_on = [helm_release.secrets_store_csi_driver]
}

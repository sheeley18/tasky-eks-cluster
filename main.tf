provider "aws" {
  region = var.region
}

# VPC with proper DNS settings
resource "aws_vpc" "new_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name = "tasky-eks-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.new_vpc.id
  
  tags = {
    Name = "tasky-igw"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.new_vpc.id
  
  tags = {
    Name = "tasky-public-rt"
  }
}

resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Generate cluster name
locals {
  cluster_name = "tasky-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

# Public subnet with proper tags
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.new_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"
  
  tags = {
    Name                     = "tasky-public-subnet"
    "kubernetes.io/role/elb" = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
  }
}

resource "aws_route_table_association" "public_subnet_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Private subnets with proper tags
resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.new_vpc.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "us-east-1a"
  
  tags = {
    Name                              = "tasky-private-subnet-1"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
  }
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.new_vpc.id
  cidr_block        = "10.0.5.0/24"
  availability_zone = "us-east-1b"
  
  tags = {
    Name                              = "tasky-private-subnet-2"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
  }
}

# Create NEW EIP instead of using existing one
resource "aws_eip" "nat_eip" {
  domain = "vpc"
  
  tags = {
    Name = "tasky-nat-eip"
  }
  
  depends_on = [aws_internet_gateway.igw]
}

# NAT Gateway with the new EIP
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
  
  tags = {
    Name = "tasky-nat-gateway"
  }
  
  depends_on = [aws_internet_gateway.igw]
}

# Private route table
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.new_vpc.id
  
  tags = {
    Name = "tasky-private-rt"
  }
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

# MongoDB VPC peering (keeping your existing setup)
data "aws_vpc" "mongodb_vpc" {
  id = "vpc-0828a5cb74c8482ff"
}

data "aws_route_tables" "mongodb_private" {
  vpc_id = data.aws_vpc.mongodb_vpc.id
  filter {
    name   = "association.main"
    values = ["false"]
  }
}

resource "aws_vpc_peering_connection" "eks_to_mongodb" {
  peer_vpc_id = data.aws_vpc.mongodb_vpc.id
  vpc_id      = aws_vpc.new_vpc.id
  auto_accept = true

  tags = {
    Name = "EKS-to-MongoDB-Peering"
  }
}

resource "aws_route" "eks_to_mongodb" {
  route_table_id            = aws_route_table.private_rt.id
  destination_cidr_block    = "192.168.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.eks_to_mongodb.id
}

resource "aws_route" "mongodb_to_eks" {
  count                     = length(data.aws_route_tables.mongodb_private.ids)
  route_table_id            = data.aws_route_tables.mongodb_private.ids[count.index]
  destination_cidr_block    = "10.0.0.0/16"
  vpc_peering_connection_id = aws_vpc_peering_connection.eks_to_mongodb.id
}

# Simplified EKS cluster
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
    vpc-cni = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  vpc_id     = aws_vpc.new_vpc.id
  subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]

  eks_managed_node_group_defaults = {
    ami_type       = "AL2_x86_64"
    instance_types = ["t3.small"]
    disk_size      = 20
  }

  # Start with single node group for faster deployment
  eks_managed_node_groups = {
    primary = {
      name = "primary-node-group"
      instance_types = ["t3.small"]
      
      min_size     = 1
      max_size     = 3
      desired_size = 2
      
      # Ensure proper subnet distribution
      subnet_ids = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
    }
  }
  
  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

# EBS CSI Driver IAM role
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

# Secrets Manager IAM role
resource "aws_iam_role" "eks_secrets_role" {
  name = "eks-secrets-manager-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
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

resource "aws_iam_role" "eks_secrets_role" {
  name = "eks-secrets-manager-role-${random_string.suffix.result}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"  # This was the problem!
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

# Note: Helm charts removed to avoid conflicts
# Install manually after cluster is ready:
# 
# helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
# helm install secrets-store-csi-driver secrets-store-csi-driver/secrets-store-csi-driver \
#   --namespace kube-system --set syncSecret.enabled=true
#
# helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws  
# helm install aws-secrets-provider aws-secrets-manager/secrets-store-csi-driver-provider-aws \
#   --namespace kube-system
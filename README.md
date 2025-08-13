# Tasky EKS Cluster

This repository contains Terraform configuration to provision an EKS cluster for the Tasky application with AWS Secrets Manager integration.

## Architecture

- **EKS Cluster**: Kubernetes 1.29 with managed node groups
- **VPC**: Custom VPC with public/private subnets across 2 AZs
- **NAT Gateway**: For private subnet internet access
- **VPC Peering**: Connection to MongoDB VPC (192.168.0.0/16)
- **Secrets Manager**: IAM role for accessing Tasky database credentials
- **CSI Driver**: AWS Secrets Store CSI Driver for mounting secrets

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.3
- kubectl
- Helm 3

## Deployment

### 1. Deploy Infrastructure

```bash
# Initialize Terraform
terraform init

# Plan deployment
terraform plan

# Apply configuration
terraform apply
```

### 2. Configure kubectl

```bash
# Update kubeconfig
aws eks update-kubeconfig --name $(terraform output -raw cluster_name)

# Verify connection
kubectl get nodes
```

### 3. Install AWS Secrets Store CSI Driver

```bash
# Install CSI driver
helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install secrets-store-csi-driver secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system --set syncSecret.enabled=true

# Install AWS provider
curl -s https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml | kubectl apply -f -

# Verify installation
kubectl get pods -n kube-system | grep -E "(secrets|aws)"
```

## Outputs

After successful deployment, note these important values:

```bash
terraform output
```

Key outputs:
- `cluster_name`: EKS cluster name
- `cluster_endpoint`: Kubernetes API endpoint
- `eks_secrets_manager_role_arn`: IAM role ARN for Tasky service account
- `vpc_peering_connection_id`: Connection to MongoDB VPC

## Tasky Application Setup

1. **Update service-account.yaml** in your Tasky repository with the `eks_secrets_manager_role_arn`
2. **Deploy Tasky** using the configured cluster
3. **Verify secrets access** through the CSI driver

## Cleanup

```bash
terraform destroy
```

## Troubleshooting

### Common Issues

1. **EIP Association Error**: The configuration creates a new EIP to avoid conflicts
2. **Helm Conflicts**: CSI driver installed via Helm, AWS provider via kubectl manifests
3. **DNS Resolution**: Ensure VPC has DNS hostnames/support enabled (configured automatically)

### Verification Commands

```bash
# Check cluster status
kubectl get nodes

# Check CSI driver
kubectl get pods -n kube-system | grep secrets

# Check AWS provider
kubectl get pods -n kube-system | grep aws

# Test secrets access (after Tasky deployment)
kubectl describe secretproviderclass -n default
```

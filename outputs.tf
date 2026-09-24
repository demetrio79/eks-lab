# ============================================================
# VPC
# ============================================================
output "vpc_id" {
  description = "ID da VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ip" {
  description = "IP público do NAT Gateway"
  value       = aws_eip.nat.public_ip
}

# ============================================================
# EKS
# ============================================================
output "cluster_name" {
  description = "Nome do cluster EKS"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint do API server do EKS"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Versão do Kubernetes"
  value       = aws_eks_cluster.main.version
}

output "cluster_certificate_authority" {
  description = "Certificado CA do cluster (base64)"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "oidc_provider_arn" {
  description = "ARN do OIDC provider (usado para criar IRSA)"
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  description = "URL do OIDC provider"
  value       = aws_iam_openid_connect_provider.eks.url
}

output "node_group_role_arn" {
  description = "ARN da IAM role dos nós"
  value       = aws_iam_role.node_group.arn
}

# ============================================================
# Karpenter
# ============================================================
output "karpenter_role_arn" {
  description = "ARN da IAM role do Karpenter"
  value       = aws_iam_role.karpenter.arn
}

output "karpenter_queue_url" {
  description = "URL da fila SQS de interrupção do Karpenter"
  value       = aws_sqs_queue.karpenter.url
}

# ============================================================
# Comando para configurar o kubectl
# ============================================================
output "configure_kubectl" {
  description = "Comando para configurar o kubectl"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}

# ============================================================
# OIDC — GitHub Actions
# ============================================================
output "github_actions_role_arn" {
  description = "ARN da IAM Role assumida pelo GitHub Actions via OIDC. Configure como secret AWS_ROLE_ARN no repositório GitHub."
  value       = aws_iam_role.github_actions.arn
}

output "github_oidc_provider_arn" {
  description = "ARN do OIDC provider do GitHub criado na AWS"
  value       = aws_iam_openid_connect_provider.github.arn
}

output "github_actions_setup_instructions" {
  description = "Instruções para configurar o GitHub após o apply"
  value       = <<-EOT
    Configure os seguintes secrets no repositório GitHub
    (Settings → Secrets → Actions):

      AWS_ACCOUNT_ID = ${data.aws_caller_identity.current.account_id}

    O ARN da role para os workflows é:
      ${aws_iam_role.github_actions.arn}

    Após configurar, remova os secrets AWS_ACCESS_KEY_ID e
    AWS_SECRET_ACCESS_KEY caso existam — não são mais necessários.
  EOT
}

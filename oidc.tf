# ============================================================
# OIDC Identity Provider — GitHub Actions
#
# Permite que o GitHub Actions assuma roles na AWS sem
# precisar de chaves de acesso estáticas (AWS_ACCESS_KEY_ID).
# O GitHub gera um JWT por execução; a AWS valida e emite
# credenciais temporárias via STS.
# ============================================================

# Thumbprint oficial do GitHub OIDC
# Ref: https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # Thumbprint do certificado raiz da CA do GitHub (fixo)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name    = "github-actions-oidc"
    Project = var.project
  }
}

# ============================================================
# IAM Role — assumida pelo GitHub Actions via OIDC
#
# A condition garante que SOMENTE o repositório e branches
# corretos podem assumir essa role. Sem isso, qualquer
# repositório do GitHub poderia tentar assumir a role.
# ============================================================
resource "aws_iam_role" "github_actions" {
  name        = "${var.project}-github-actions"
  description = "Role assumida pelo GitHub Actions via OIDC para gerenciar a infraestrutura"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowGitHubOIDC"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # Garante que o token é destinado à AWS
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Permite qualquer sub originado do repositório eks-lab.
            # Cobre: branches, PRs, environments, workflow_dispatch, etc.
            "token.actions.githubusercontent.com:sub" = "repo:demetrio79/eks-lab:*"
          }
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project}-github-actions"
    Project = var.project
  }
}

# ============================================================
# Política de permissões para o GitHub Actions
#
# Permissões necessárias para criar/destruir toda a infra:
# EKS, EC2, VPC, IAM, S3 (state), CloudWatch, SQS, EventBridge
# ============================================================
resource "aws_iam_policy" "github_actions" {
  name        = "${var.project}-github-actions"
  description = "Permissões do GitHub Actions para gerenciar a infraestrutura do lab EKS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # S3 — leitura e escrita do state do Terraform
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketVersioning",
          "s3:GetBucketLocation",
        ]
        Resource = [
          "arn:aws:s3:::${var.tf_state_bucket}",
          "arn:aws:s3:::${var.tf_state_bucket}/*",
        ]
      },
      # EC2 e VPC — gerenciamento completo para criar/destruir VPC e nós
      {
        Sid      = "EC2Full"
        Effect   = "Allow"
        Action   = ["ec2:*"]
        Resource = ["*"]
      },
      # EKS — gerenciamento completo do cluster
      {
        Sid      = "EKSFull"
        Effect   = "Allow"
        Action   = ["eks:*"]
        Resource = ["*"]
      },
      # IAM — criação de roles e políticas para EKS e Karpenter
      {
        Sid    = "IAMManagement"
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:ListRoles",
          "iam:UpdateRole",
          "iam:UpdateAssumeRolePolicy",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:ListPolicies",
          "iam:ListPolicyVersions",
          "iam:CreatePolicyVersion",
          "iam:DeletePolicyVersion",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:ListInstanceProfiles",
          "iam:ListInstanceProfilesForRole",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider",
          "iam:ListOpenIDConnectProviders",
          "iam:TagOpenIDConnectProvider",
          "iam:TagRole",
          "iam:TagPolicy",
          "iam:TagInstanceProfile",
          "iam:PassRole",
        ]
        Resource = ["*"]
      },
      # CloudWatch Logs — logs do EKS control plane
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:DeleteLogGroup",
          "logs:DescribeLogGroups",
          "logs:PutRetentionPolicy",
          "logs:DeleteRetentionPolicy",
          "logs:TagLogGroup",
          "logs:ListTagsLogGroup",
          "logs:ListTagsForResource",
          "logs:TagResource",
        ]
        Resource = ["*"]
      },
      # SQS — fila de interrupção do Karpenter
      {
        Sid    = "SQSKarpenter"
        Effect = "Allow"
        Action = ["sqs:*"]
        Resource = ["*"]
      },
      # EventBridge — regras de eventos para o Karpenter
      {
        Sid    = "EventBridge"
        Effect = "Allow"
        Action = [
          "events:PutRule",
          "events:DeleteRule",
          "events:DescribeRule",
          "events:ListRules",
          "events:PutTargets",
          "events:RemoveTargets",
          "events:ListTargetsByRule",
          "events:TagResource",
          "events:ListTagsForResource",
        ]
        Resource = ["*"]
      },
      # SSM — parâmetros de AMI para o Karpenter
      {
        Sid    = "SSMRead"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.github_actions.arn
}

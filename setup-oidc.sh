#!/usr/bin/env bash
# =============================================================================
# setup-oidc.sh — Configura o OIDC do GitHub Actions na AWS via CLI
#
# Execute UMA VEZ antes de rodar o Terraform pela primeira vez.
# Estes recursos ficam FORA do ciclo de vida do Terraform:
#   - não são alterados pelo terraform apply
#   - não são destruídos pelo terraform destroy
#
# Pré-requisitos:
#   - AWS CLI v2 configurado com permissões de IAM
#   - jq instalado (apt install jq / brew install jq)
#
# Uso:
#   chmod +x setup-oidc.sh
#   ./setup-oidc.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURAÇÃO — edite estas variáveis antes de executar
# =============================================================================

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
PROJECT="eks-lab"
GITHUB_REPO="demetrio79@18690185/eks-lab@1384428715"   # formato: user@userID/repo@repoID

# Thumbprints oficiais do GitHub OIDC (atualizados em 2024)
# Ref: https://docs.github.com/en/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
THUMBPRINT_1="6938fd4d98bab03faadb97b34396831e3780aea1"
THUMBPRINT_2="1c58a3a8518e8759bf075b76b750d4f2df264fcd"

OIDC_URL="https://token.actions.githubusercontent.com"
ROLE_NAME="${PROJECT}-github-actions"
POLICY_NAME="${PROJECT}-github-actions"
TF_STATE_BUCKET="${PROJECT}-tfstate-${AWS_ACCOUNT_ID}"

echo "============================================="
echo "  Configurando OIDC GitHub Actions na AWS"
echo "============================================="
echo "Conta AWS : ${AWS_ACCOUNT_ID}"
echo "Repositório: ${GITHUB_REPO}"
echo "Role       : ${ROLE_NAME}"
echo ""

# =============================================================================
# 1. OIDC Identity Provider
# =============================================================================
echo ">>> [1/3] Verificando OIDC Provider..."

OIDC_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" \
    > /dev/null 2>&1; then
  echo "    ✅ OIDC Provider já existe — nenhuma alteração necessária."
else
  echo "    Criando OIDC Provider..."
  aws iam create-open-id-connect-provider \
    --url "${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT_1}" "${THUMBPRINT_2}" \
    --tags "Key=Name,Value=github-actions-oidc" "Key=Project,Value=${PROJECT}"
  echo "    ✅ OIDC Provider criado: ${OIDC_ARN}"
fi

# =============================================================================
# 2. IAM Role
# =============================================================================
echo ""
echo ">>> [2/3] Verificando IAM Role..."

ASSUME_ROLE_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGitHubOIDC",
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF
)

if aws iam get-role --role-name "${ROLE_NAME}" > /dev/null 2>&1; then
  echo "    ✅ IAM Role já existe — nenhuma alteração necessária."
  ROLE_ARN="$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text)"
else
  echo "    Criando IAM Role..."
  ROLE_ARN="$(aws iam create-role \
    --role-name "${ROLE_NAME}" \
    --description "Role assumida pelo GitHub Actions via OIDC para gerenciar a infraestrutura" \
    --assume-role-policy-document "${ASSUME_ROLE_POLICY}" \
    --tags "Key=Name,Value=${ROLE_NAME}" "Key=Project,Value=${PROJECT}" \
    --query 'Role.Arn' --output text)"
  echo "    ✅ IAM Role criada: ${ROLE_ARN}"
fi

# =============================================================================
# 3. IAM Policy e attachment
# =============================================================================
echo ""
echo ">>> [3/3] Verificando IAM Policy..."

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

POLICY_DOC=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::${TF_STATE_BUCKET}",
        "arn:aws:s3:::${TF_STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "EC2Full",
      "Effect": "Allow",
      "Action": ["ec2:*"],
      "Resource": ["*"]
    },
    {
      "Sid": "EKSFull",
      "Effect": "Allow",
      "Action": ["eks:*"],
      "Resource": ["*"]
    },
    {
      "Sid": "IAMManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:ListRoles",
        "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy",
        "iam:GetPolicyVersion", "iam:ListPolicies", "iam:ListPolicyVersions",
        "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile", "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile", "iam:ListInstanceProfiles",
        "iam:ListInstanceProfilesForRole",
        "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider", "iam:ListOpenIDConnectProviders",
        "iam:TagOpenIDConnectProvider",
        "iam:TagRole", "iam:TagPolicy", "iam:TagInstanceProfile",
        "iam:PassRole"
      ],
      "Resource": ["*"]
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:DescribeLogGroups",
        "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy",
        "logs:TagLogGroup", "logs:ListTagsLogGroup",
        "logs:ListTagsForResource", "logs:TagResource"
      ],
      "Resource": ["*"]
    },
    {
      "Sid": "SQSKarpenter",
      "Effect": "Allow",
      "Action": ["sqs:*"],
      "Resource": ["*"]
    },
    {
      "Sid": "EventBridge",
      "Effect": "Allow",
      "Action": [
        "events:PutRule", "events:DeleteRule", "events:DescribeRule",
        "events:ListRules", "events:PutTargets", "events:RemoveTargets",
        "events:ListTargetsByRule", "events:TagResource", "events:ListTagsForResource"
      ],
      "Resource": ["*"]
    },
    {
      "Sid": "SSMRead",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters"],
      "Resource": ["*"]
    }
  ]
}
EOF
)

if aws iam get-policy --policy-arn "${POLICY_ARN}" > /dev/null 2>&1; then
  echo "    ✅ IAM Policy já existe — nenhuma alteração necessária."
else
  echo "    Criando IAM Policy..."
  aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --description "Permissões do GitHub Actions para gerenciar a infraestrutura do lab EKS" \
    --policy-document "${POLICY_DOC}" \
    --tags "Key=Name,Value=${POLICY_NAME}" "Key=Project,Value=${PROJECT}" \
    > /dev/null
  echo "    ✅ IAM Policy criada: ${POLICY_ARN}"
fi

# Verificar se a policy já está attached à role
ATTACHED=$(aws iam list-attached-role-policies \
  --role-name "${ROLE_NAME}" \
  --query "AttachedPolicies[?PolicyArn=='${POLICY_ARN}'].PolicyArn" \
  --output text)

if [ -n "${ATTACHED}" ]; then
  echo "    ✅ Policy já está attached à role."
else
  aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}"
  echo "    ✅ Policy attached à role."
fi

# =============================================================================
# Resumo
# =============================================================================
echo ""
echo "============================================="
echo "  ✅ Configuração concluída!"
echo "============================================="
echo ""
echo "Configure o secret abaixo no repositório GitHub:"
echo "  Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo "  Nome : AWS_ROLE_ARN"
echo "  Valor: ${ROLE_ARN}"
echo ""
echo "⚠️  Estes recursos NÃO estão no Terraform state."
echo "    Para removê-los use o script teardown-oidc.sh"
echo "    ou apague manualmente via console/CLI."
echo "============================================="

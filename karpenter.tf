# ============================================================
# Data sources
# ============================================================
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition
}

# ============================================================
# SQS — Fila de interrupção para Spot e eventos de instância
# Permite ao Karpenter reagir a notificações de interrupção Spot,
# rebalanceamento, etc., antes que a instância seja encerrada.
# ============================================================
resource "aws_sqs_queue" "karpenter" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name    = "${var.cluster_name}-karpenter"
    Project = var.project
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2InterruptionPolicy"
        Effect = "Allow"
        Principal = {
          Service = [
            "events.amazonaws.com",
            "sqs.amazonaws.com",
          ]
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter.arn
      },
    ]
  })
}

# ============================================================
# EventBridge Rules — envia eventos de interrupção para o SQS
# ============================================================
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "Eventos de interrupção de instâncias Spot"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "${var.cluster_name}-rebalance"
  description = "Eventos de rebalanceamento de instâncias"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.karpenter.arn
}

resource "aws_cloudwatch_event_rule" "instance_state" {
  name        = "${var.cluster_name}-instance-state"
  description = "Mudanças de estado de instâncias EC2"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "instance_state" {
  rule = aws_cloudwatch_event_rule.instance_state.name
  arn  = aws_sqs_queue.karpenter.arn
}

# ============================================================
# IAM Role para o Karpenter (IRSA)
# ============================================================
data "aws_iam_policy_document" "karpenter_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter" {
  name               = "${var.cluster_name}-karpenter"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role.json

  tags = {
    Name    = "${var.cluster_name}-karpenter"
    Project = var.project
  }
}

# Política com permissões necessárias para o Karpenter
resource "aws_iam_policy" "karpenter" {
  name        = "${var.cluster_name}-karpenter"
  description = "Permissões do Karpenter para gerenciar instâncias EC2"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
        ]
        Resource = [
          "arn:${local.partition}:ec2:${var.region}::image/*",
          "arn:${local.partition}:ec2:${var.region}::snapshot/*",
          "arn:${local.partition}:ec2:${var.region}:*:spot-instances-request/*",
          "arn:${local.partition}:ec2:${var.region}:*:security-group/*",
          "arn:${local.partition}:ec2:${var.region}:*:subnet/*",
          "arn:${local.partition}:ec2:${var.region}:*:launch-template/*",
          "arn:${local.partition}:ec2:${var.region}:*:capacity-reservation/*",
          "arn:${local.partition}:ec2:${var.region}:*:fleet/*",
          "arn:${local.partition}:ec2:${var.region}:*:network-interface/*",
          "arn:${local.partition}:ec2:${var.region}:*:placement-group/*",
          "arn:${local.partition}:ec2:${var.region}:*:volume/*",
        ]
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Action = [
          "ec2:RunInstances",
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
        ]
        Resource = [
          "arn:${local.partition}:ec2:${var.region}:*:fleet/*",
          "arn:${local.partition}:ec2:${var.region}:*:instance/*",
          "arn:${local.partition}:ec2:${var.region}:*:volume/*",
          "arn:${local.partition}:ec2:${var.region}:*:network-interface/*",
          "arn:${local.partition}:ec2:${var.region}:*:launch-template/*",
          "arn:${local.partition}:ec2:${var.region}:*:spot-instances-request/*",
        ]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Action = ["ec2:CreateTags"]
        Resource = [
          "arn:${local.partition}:ec2:${var.region}:*:fleet/*",
          "arn:${local.partition}:ec2:${var.region}:*:instance/*",
          "arn:${local.partition}:ec2:${var.region}:*:volume/*",
          "arn:${local.partition}:ec2:${var.region}:*:network-interface/*",
          "arn:${local.partition}:ec2:${var.region}:*:launch-template/*",
          "arn:${local.partition}:ec2:${var.region}:*:spot-instances-request/*",
        ]
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = ["arn:${local.partition}:ec2:${var.region}:*:instance/*"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["karpenter.sh/nodeclaim", "Name"]
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Action = [
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
        ]
        Resource = [
          "arn:${local.partition}:ec2:${var.region}:*:instance/*",
          "arn:${local.partition}:ec2:${var.region}:*:launch-template/*",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowRegionalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.region
          }
        }
      },
      {
        Sid    = "AllowGlobalReadActions"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstanceAttribute",
          "iam:GetInstanceProfile",
          "pricing:GetProducts",
          "ssm:GetParameter",
        ]
        Resource = ["*"]
      },
      {
        Sid    = "AllowInterruptionQueueActions"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = [aws_sqs_queue.karpenter.arn]
      },
      {
        Sid    = "AllowPassingInstanceRole"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [aws_iam_role.node_group.arn]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileCreation"
        Effect = "Allow"
        Action = ["iam:CreateInstanceProfile"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileTagActions"
        Effect = "Allow"
        Action = ["iam:TagInstanceProfile"]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"              = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileActions"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
        ]
        Resource = ["*"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Action   = ["iam:GetInstanceProfile"]
        Resource = ["*"]
      },
      {
        Sid    = "AllowAPIServerEndpointDiscovery"
        Effect = "Allow"
        Action = ["eks:DescribeCluster"]
        Resource = ["arn:${local.partition}:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}"]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter.arn
}

# ============================================================
# Instance Profile para os nós provisionados pelo Karpenter
# ============================================================
resource "aws_iam_instance_profile" "karpenter" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.node_group.name

  tags = {
    Name    = "${var.cluster_name}-karpenter-node"
    Project = var.project
  }
}

# ============================================================
# aws-auth ConfigMap via kubectl
# Permite que os nós do Karpenter se registrem no cluster.
# Usa local-exec para evitar conexão ao cluster durante o plan.
# ============================================================
resource "terraform_data" "aws_auth" {
  triggers_replace = [
    aws_iam_role.node_group.arn,
    aws_iam_role.karpenter.arn,
    aws_eks_cluster.main.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}

      kubectl apply -f - <<EOF
      apiVersion: v1
      kind: ConfigMap
      metadata:
        name: aws-auth
        namespace: kube-system
      data:
        mapRoles: |
          - rolearn: ${aws_iam_role.node_group.arn}
            username: system:node:{{EC2PrivateDNSName}}
            groups:
              - system:bootstrappers
              - system:nodes
          - rolearn: ${aws_iam_role.karpenter.arn}
            username: system:node:{{EC2PrivateDNSName}}
            groups:
              - system:bootstrappers
              - system:nodes
      EOF
    EOT
  }

  depends_on = [aws_eks_node_group.main]
}

# ============================================================
# Helm Release — Karpenter
# ============================================================
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  wait             = true
  timeout          = 300

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter.name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter.arn
  }

  set {
    name  = "controller.resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "controller.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "controller.resources.limits.cpu"
    value = "1"
  }

  set {
    name  = "controller.resources.limits.memory"
    value = "1Gi"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.karpenter,
    terraform_data.aws_auth,
  ]
}

# ============================================================
# EC2NodeClass e NodePool via kubectl
#
# kubernetes_manifest tenta conectar ao cluster durante o plan,
# o que falha quando o cluster ainda não existe.
# Usamos null_resource + local-exec com kubectl apply para
# aplicar os manifests somente após o cluster e o Karpenter
# estarem prontos.
# ============================================================
resource "terraform_data" "karpenter_manifests" {
  triggers_replace = [
    aws_eks_cluster.main.id,
    helm_release.karpenter.id,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}

      kubectl apply -f - <<EOF
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: default
      spec:
        amiFamily: AL2
        role: ${aws_iam_role.node_group.name}
        subnetSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${var.cluster_name}
        securityGroupSelectorTerms:
          - tags:
              aws:eks:cluster-name: ${var.cluster_name}
        tags:
          kubernetes.io/cluster/${var.cluster_name}: owned
          Project: ${var.project}
      ---
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: default
      spec:
        template:
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: default
            requirements:
              - key: kubernetes.io/arch
                operator: In
                values: ["amd64"]
              - key: kubernetes.io/os
                operator: In
                values: ["linux"]
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["spot", "on-demand"]
              - key: node.kubernetes.io/instance-category
                operator: In
                values: ["t", "m", "c"]
              - key: node.kubernetes.io/instance-generation
                operator: Gt
                values: ["2"]
        limits:
          cpu: "10"
          memory: 40Gi
        disruption:
          consolidationPolicy: WhenEmptyOrUnderutilized
          consolidateAfter: 30s
      EOF
    EOT
  }

  depends_on = [helm_release.karpenter]
}

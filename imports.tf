# ============================================================
# Import blocks — recursos criados manualmente ou em runs
# anteriores que precisam ser importados para o state.
# Após o primeiro apply bem-sucedido, este arquivo pode ser
# removido (os recursos já estarão no state).
# ============================================================

import {
  to = aws_iam_openid_connect_provider.github
  id = "arn:aws:iam::688066489200:oidc-provider/token.actions.githubusercontent.com"
}

import {
  to = aws_iam_role.github_actions
  id = "eks-lab-github-actions"
}

import {
  to = aws_iam_openid_connect_provider.eks
  id = "arn:aws:iam::688066489200:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/20EA3604630A97E17B03475684C30DC8"
}

import {
  to = aws_eks_cluster.main
  id = "eks-lab"
}

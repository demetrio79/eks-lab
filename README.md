# EKS Lab — Terraform

Lab de EKS com Karpenter, VPC dedicada e infraestrutura como código.

## Arquitetura

```
us-east-1
└── VPC (10.0.0.0/16)
    ├── Subnet Pública  us-east-1a (10.0.0.0/24)  ─┐
    ├── Subnet Pública  us-east-1b (10.0.1.0/24)    ├─ Internet Gateway
    ├── Subnet Privada  us-east-1a (10.0.10.0/24) ─┐│
    └── Subnet Privada  us-east-1b (10.0.11.0/24)  ├┘ NAT Gateway (us-east-1a)
                                                    │
                                              EKS Cluster
                                          (node group + Karpenter)
```

## Pré-requisitos

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) v2
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/) >= 3
- Credenciais AWS configuradas (`~/.aws/credentials`)

## 1. Criar o bucket S3 para o state

```bash
# Crie o bucket (nome deve ser globalmente único)
aws s3api create-bucket \
  --bucket meu-tfstate-eks-lab \
  --region us-east-1

# Habilite versionamento (recomendado)
aws s3api put-bucket-versioning \
  --bucket meu-tfstate-eks-lab \
  --versioning-configuration Status=Enabled

# Bloqueie acesso público
aws s3api put-public-access-block \
  --bucket meu-tfstate-eks-lab \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

## 2. Configurar o backend

Edite `backend.tf` e substitua `SEU-BUCKET-TFSTATE` pelo nome do bucket criado:

```hcl
terraform {
  backend "s3" {
    bucket = "meu-tfstate-eks-lab"   # <-- seu bucket
    key    = "eks-lab/terraform.tfstate"
    region = "us-east-1"
  }
}
```

## 3. Inicializar e aplicar

```bash
# Inicializa providers e backend
terraform init

# Revisa o plano (nenhum recurso criado ainda)
terraform plan

# Aplica a infraestrutura (~15-20 minutos)
terraform apply
```

## 4. Configurar o kubectl

Após o `apply`, execute o comando exibido no output:

```bash
# O comando exato estará no output "configure_kubectl"
aws eks update-kubeconfig --region us-east-1 --name eks-lab

# Verifique os nós
kubectl get nodes

# Verifique o Karpenter
kubectl get pods -n karpenter
kubectl get nodepools
kubectl get ec2nodeclasses
```

## 5. Variáveis customizáveis

Crie um arquivo `terraform.tfvars` (ignorado pelo git) para sobrescrever defaults:

```hcl
project         = "eks-lab"
cluster_name    = "eks-lab"
cluster_version = "1.30"

# Instância do node group inicial (onde o Karpenter roda)
node_instance_type = "t3.micro"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 3

# Versão do Karpenter
karpenter_version = "0.37.0"
```

## Estrutura do projeto

```
eks-lab/
├── versions.tf     # Providers e versões requeridas
├── backend.tf      # Backend S3 para o state
├── variables.tf    # Todas as variáveis
├── vpc.tf          # VPC, subnets, IGW, NAT, route tables
├── eks.tf          # Cluster EKS, OIDC, node group, add-ons
├── karpenter.tf    # IAM, SQS, EventBridge, Helm, NodePool
├── outputs.tf      # Outputs úteis
└── .gitignore      # Exclui state e secrets do git
```

## Recursos criados

| Recurso | Descrição |
|---|---|
| VPC | 10.0.0.0/16 com DNS habilitado |
| Subnets | 2 públicas + 2 privadas em AZs diferentes |
| Internet Gateway | Para tráfego público |
| NAT Gateway | Único, para saída das subnets privadas |
| EKS Cluster | Kubernetes 1.30, endpoint público + privado |
| Node Group | 2x t3.micro nas subnets privadas |
| Add-ons | CoreDNS, kube-proxy, VPC CNI, EKS Pod Identity |
| OIDC Provider | Para IRSA |
| Karpenter | v0.37.0 via Helm, com NodePool e EC2NodeClass |
| SQS Queue | Interruption queue para Spot |
| EventBridge | Regras para eventos de interrupção/rebalanceamento |

## Destruir a infraestrutura

```bash
# Remove todos os recursos (cuidado: irreversível)
terraform destroy
```

> **Atenção:** O NAT Gateway e o EKS cluster geram custo mesmo parados.
> Destrua o ambiente quando não estiver em uso.

## Git

```bash
# Inicializar repositório
git init
git add .
git commit -m "feat: infraestrutura EKS lab com Karpenter"

# Conectar a um repositório remoto
git remote add origin https://github.com/seu-usuario/eks-lab.git
git push -u origin main
```
# eks-lab

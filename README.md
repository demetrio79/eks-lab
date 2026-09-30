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

---

## 0. Configurar o OIDC do GitHub Actions (uma única vez)

O OIDC provider, a IAM role e a policy do GitHub Actions ficam **fora do Terraform**.
Isso garante que:
- `terraform apply` não os sobrescreve
- `terraform destroy` não os apaga

Execute o script **uma vez** antes de qualquer outra etapa:

```bash
chmod +x setup-oidc.sh
./setup-oidc.sh
```

O script é idempotente — pode ser executado novamente sem efeitos colaterais.

Ao final, ele exibe o ARN da role. Configure como secret no repositório GitHub:

```
Settings → Secrets and variables → Actions → New repository secret

  Nome : AWS_ROLE_ARN
  Valor: arn:aws:iam::<ACCOUNT_ID>:role/eks-lab-github-actions
```

---

## 1. Criar o bucket S3 para o state

```bash
aws s3api create-bucket \
  --bucket meu-tfstate-eks-lab \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket meu-tfstate-eks-lab \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket meu-tfstate-eks-lab \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

## 2. Configurar o backend

Edite `backend.tf` e substitua pelo nome do bucket criado:

```hcl
terraform {
  backend "s3" {
    bucket = "meu-tfstate-eks-lab"
    key    = "eks-lab/terraform.tfstate"
    region = "us-east-1"
  }
}
```

## 3. Inicializar e aplicar

```bash
terraform init
terraform plan
terraform apply   # ~15-20 minutos
```

## 4. Configurar o kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name eks-lab

kubectl get nodes
kubectl get pods -n karpenter
kubectl get nodepools
kubectl get ec2nodeclasses
```

## 5. Variáveis customizáveis

Crie um arquivo `terraform.tfvars` (ignorado pelo git):

```hcl
project            = "eks-lab"
cluster_name       = "eks-lab"
cluster_version    = "1.30"
node_instance_type = "t3.micro"
node_desired_size  = 2
node_min_size      = 1
node_max_size      = 3
karpenter_version  = "0.37.0"
```

---

## Estrutura do projeto

```
eks-lab/
├── setup-oidc.sh   # Configura OIDC GitHub Actions via AWS CLI (rodar uma vez)
├── versions.tf     # Providers e versões requeridas
├── backend.tf      # Backend S3 para o state
├── variables.tf    # Todas as variáveis
├── vpc.tf          # VPC, subnets, IGW, NAT, route tables
├── eks.tf          # Cluster EKS, OIDC, node group, add-ons
├── karpenter.tf    # IAM, SQS, EventBridge, Helm, NodePool
├── outputs.tf      # Outputs úteis
└── .gitignore      # Exclui state e secrets do git
```

## Recursos gerenciados pelo Terraform

| Recurso | Descrição |
|---|---|
| VPC | 10.0.0.0/16 com DNS habilitado |
| Subnets | 2 públicas + 2 privadas em AZs diferentes |
| Internet Gateway | Para tráfego público |
| NAT Gateway | Único, para saída das subnets privadas |
| EKS Cluster | Kubernetes 1.30, endpoint público + privado |
| Node Group | 2x t3.micro nas subnets privadas |
| Add-ons | CoreDNS, kube-proxy, VPC CNI, EKS Pod Identity |
| OIDC Provider (EKS) | Para IRSA do Karpenter |
| Karpenter | v0.37.0 via Helm, com NodePool e EC2NodeClass |
| SQS Queue | Interruption queue para Spot |
| EventBridge | Regras para eventos de interrupção/rebalanceamento |

## Recursos fora do Terraform (gerenciados pelo setup-oidc.sh)

| Recurso | Descrição |
|---|---|
| OIDC Provider (GitHub) | `token.actions.githubusercontent.com` |
| IAM Role `eks-lab-github-actions` | Assumida pelo GitHub Actions via OIDC |
| IAM Policy `eks-lab-github-actions` | Permissões para criar/destruir a infra |

> Estes recursos **não são destruídos** pelo `terraform destroy`.
> Para removê-los, use o console AWS ou a CLI manualmente.

---

## Fluxo de CI/CD

```
push em branch  →  auto-pr.yml cria PR automaticamente
                           ↓
              PR aberto  →  terraform-apply.yml executa plan
                              (resultado comentado no PR)
                           ↓
              merge na main  →  terraform-apply.yml executa apply

              workflow_dispatch  →  terraform-destroy.yml
                                    (requer confirmação "destruir")
```

Autenticação: **OIDC** — sem `AWS_ACCESS_KEY_ID` ou `AWS_SECRET_ACCESS_KEY`.

---

## Destruir a infraestrutura

```bash
terraform destroy
```

> **Atenção:** O NAT Gateway e o EKS cluster geram custo mesmo parados.
> Destrua o ambiente quando não estiver em uso.
>
> Os recursos de OIDC do GitHub Actions **não serão destruídos** — foram criados
> fora do Terraform intencionalmente.

variable "region" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Nome do projeto, usado como prefixo nos recursos"
  type        = string
  default     = "eks-lab"
}

variable "vpc_cidr" {
  description = "CIDR block da VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas (uma por AZ)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas (uma por AZ)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "azs" {
  description = "Zonas de disponibilidade a usar"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "cluster_name" {
  description = "Nome do cluster EKS"
  type        = string
  default     = "eks-lab"
}

variable "cluster_version" {
  description = "Versão do Kubernetes"
  type        = string
  default     = "1.30"
}

variable "node_instance_type" {
  description = "Tipo de instância para o node group inicial (usado pelo Karpenter)"
  type        = string
  default     = "t3.micro"
}

variable "node_desired_size" {
  description = "Número desejado de nós no node group inicial"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Número mínimo de nós"
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Número máximo de nós"
  type        = number
  default     = 3
}

variable "karpenter_version" {
  description = "Versão do chart Helm do Karpenter"
  type        = string
  default     = "0.37.0"
}

variable "tf_state_bucket" {
  description = "Nome do bucket S3 que armazena o state do Terraform (usado na política OIDC)"
  type        = string
  default     = "SEU-BUCKET-TFSTATE"
}

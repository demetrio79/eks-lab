# Antes de rodar terraform init, crie o bucket manualmente:
#
#   aws s3api create-bucket --bucket SEU-BUCKET-TFSTATE --region us-east-1
#
#   aws s3api put-bucket-versioning \
#     --bucket SEU-BUCKET-TFSTATE \
#     --versioning-configuration Status=Enabled
#
#   aws s3api put-public-access-block \
#     --bucket SEU-BUCKET-TFSTATE \
#     --public-access-block-configuration \
#       BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
#
# Substitua "SEU-BUCKET-TFSTATE" pelo nome real do seu bucket.
# Atualize também a variável tf_state_bucket em variables.tf.

terraform {
  backend "s3" {
    bucket = "SEU-BUCKET-TFSTATE"
    key    = "eks-lab/terraform.tfstate"
    region = "us-east-1"
  }
}

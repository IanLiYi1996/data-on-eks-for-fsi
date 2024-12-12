provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.example.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", local.eks_cluster]
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", local.eks_cluster]
    }
  }
}

data "aws_eks_cluster" "this" {
  name = local.eks_cluster
}

locals {
  region      = var.region
  name        = "xgboost"
  eks_cluster = "jark-stack"
}

module "xgboost_cluster" {
  source = "../../modules/ray-cluster"

  namespace        = local.name
  ray_cluster_name = local.name
  eks_cluster_name = local.eks_cluster

  helm_values = [
    yamlencode({
      image = {
        repository = "rayproject/ray-ml"
        tag        = "2.40.0"
        pullPolicy = "IfNotPresent"
      }
      head = {
        enableInTreeAutoscaling = "True"
        resources = {
          limits = {
            cpu               = "1"
            memory            = "4Gi"
          }
          requests = {
            cpu               = "1"
            memory            = "4Gi"
          }
        }
        # nodeSelector = {
        #   "NodeGroupType" = "x86-cpu-karpenter"  # 选择 CPU 节点
        # }
        tolerations = [
          {
            key      = local.name
            effect   = "NoSchedule"
            operator = "Exists"
          },
          {
            key      = "nvidia.com/gpu"  # 容忍 GPU 节点的污点
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
        containerEnv = [
          {
            name  = "RAY_LOG_TO_STDERR"
            value = "1"
          }
        ]
      }
      worker = {
        resources = {
          limits = {
            cpu               = "2"
            memory            = "16Gi"
            ephemeral-storage = "50Gi"
          }
          requests = {
            cpu               = "2"
            memory            = "16Gi"
            ephemeral-storage = "50Gi"
          }
        }
        tolerations = [
          {
            key      = local.name
            effect   = "NoSchedule"
            operator = "Exists"
          }
        ]
        replicas    = "0"
        minReplicas = "0"
        maxReplicas = "9"
        containerEnv = [
          {
            name  = "RAY_LOG_TO_STDERR"
            value = "1"
          }
        ]
      }
    })
  ]
}

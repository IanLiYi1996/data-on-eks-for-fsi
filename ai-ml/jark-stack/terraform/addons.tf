#---------------------------------------------------------------
# GP3 Encrypted Storage Class
#---------------------------------------------------------------
resource "kubernetes_annotations" "disable_gp2" {
  annotations = {
    "storageclass.kubernetes.io/is-default-class" : "false"
  }
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  force = true

  depends_on = [module.eks.eks_cluster_id]
}

resource "kubernetes_storage_class" "default_gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "ext4"
    encrypted = true
    type      = "gp3"
  }

  depends_on = [kubernetes_annotations.disable_gp2]
}

#---------------------------------------------------------------
# IRSA for EBS CSI Driver
#---------------------------------------------------------------
module "ebs_csi_driver_irsa" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version               = "~> 5.20"
  role_name_prefix      = format("%s-%s-", local.name, "ebs-csi-driver")
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = local.tags
}

module "efs_csi_driver_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"
  role_name_prefix      = format("%s-%s-", local.name, "efs-csi-driver")
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }
}

#---------------------------------------------------------------
# EKS Blueprints Addons
#---------------------------------------------------------------
module "eks_blueprints_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------
  # Amazon EKS Managed Add-ons
  #---------------------------------------
  eks_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    aws-efs-csi-driver = {
      service_account_role_arn = module.efs_csi_driver_irsa.iam_role_arn
    }
    coredns = {
      preserve = true
    }
    kube-proxy = {
      preserve = true
    }
    # VPC CNI uses worker node IAM role policies
    vpc-cni = {
      preserve = true
    }
  }

  #---------------------------------------
  # AWS Load Balancer Controller Add-on
  #---------------------------------------
  enable_aws_load_balancer_controller = true
  # turn off the mutating webhook for services because we are using
  # service.beta.kubernetes.io/aws-load-balancer-type: external
  aws_load_balancer_controller = {
    set = [{
      name  = "enableServiceMutatorWebhook"
      value = "false"
    }]
  }

  #---------------------------------------
  # Ingress Nginx Add-on
  #---------------------------------------
  enable_ingress_nginx = true
  ingress_nginx = {
    values = [templatefile("${path.module}/helm-values/ingress-nginx-values.yaml", {})]
  }

  #---------------------------------------
  # Karpenter Autoscaler for EKS Cluster
  #---------------------------------------
  enable_karpenter                  = true
  karpenter_enable_spot_termination = true
  karpenter_node = {
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }
  }
  karpenter = {
    chart_version       = "0.37.0"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
    source_policy_documents = [
      data.aws_iam_policy_document.karpenter_controller_policy.json
    ]
  }

  #---------------------------------------
  # Enable FSx for Lustre CSI Driver
  #---------------------------------------
  enable_aws_fsx_csi_driver = var.enable_fsx_for_lustre
  aws_fsx_csi_driver = {
    # INFO: fsx node daemonset won't be placed on Karpenter nodes with taints without the following toleration
    values = [
      <<-EOT
        node:
          tolerations:
            - operator: Exists
      EOT
    ]
  }

  #---------------------------------------
  # Argo Workflows & Argo Events
  #---------------------------------------
  enable_argo_workflows = true
  argo_workflows = {
    name       = "argo-workflows"
    namespace  = "argo-workflows"
    repository = "https://argoproj.github.io/argo-helm"
    values     = [templatefile("${path.module}/helm-values/argo-workflows-values.yaml", {})]
  }

  enable_argo_events = true
  argo_events = {
    name       = "argo-events"
    namespace  = "argo-events"
    repository = "https://argoproj.github.io/argo-helm"
    values     = [templatefile("${path.module}/helm-values/argo-events-values.yaml", {})]
  }

  #---------------------------------------
  # Prommetheus and Grafana stack
  #---------------------------------------
  #---------------------------------------------------------------
  # 1- Grafana port-forward `kubectl port-forward svc/kube-prometheus-stack-grafana 8080:80 -n kube-prometheus-stack`
  # 2- Grafana Admin user: admin
  # 3- Get sexret name from Terrafrom output: `terraform output grafana_secret_name`
  # 3- Get admin user password: `aws secretsmanager get-secret-value --secret-id <REPLACE_WIRTH_SECRET_ID> --region $AWS_REGION --query "SecretString" --output text`
  #---------------------------------------------------------------
  enable_kube_prometheus_stack = true
  kube_prometheus_stack = {
    values = [
      templatefile("${path.module}/helm-values/kube-prometheus.yaml", {
        storage_class_type = kubernetes_storage_class.default_gp3.id
      })
    ]
    chart_version = "48.1.1"
    set_sensitive = [
      {
        name  = "grafana.adminPassword"
        value = data.aws_secretsmanager_secret_version.admin_password_version.secret_string
      }
    ],
  }

  #---------------------------------------
  # CloudWatch metrics for EKS
  #---------------------------------------
  enable_aws_cloudwatch_metrics = true
  aws_cloudwatch_metrics = {
    values = [templatefile("${path.module}/helm-values/aws-cloudwatch-metrics-values.yaml", {})]
  }

  #---------------------------------------
  # Cluster Autoscaler
  #---------------------------------------
  enable_cluster_autoscaler = true
  cluster_autoscaler = {
    timeout     = "300"
    create_role = true
    values = [templatefile("${path.module}/helm-values/cluster-autoscaler/values.yaml", {
      aws_region     = var.region,
      eks_cluster_id = module.eks.cluster_name
    })]
  }

}

#---------------------------------------------------------------
# Data on EKS Kubernetes Addons
#---------------------------------------------------------------

module "data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "1.33.0"

  oidc_provider_arn = module.eks.oidc_provider_arn

  #---------------------------------------------------------------
  # JupyterHub Add-on
  #---------------------------------------------------------------
  enable_jupyterhub = true
  jupyterhub_helm_config = {
    namespace        = kubernetes_namespace_v1.jupyterhub.id
    create_namespace = false
    values           = [file("${path.module}/helm-values/jupyterhub-values.yaml")]
  }

  #---------------------------------------------------------------
  # Enable Neuron Device Plugin
  #---------------------------------------------------------------
  enable_aws_neuron_device_plugin = true

  # #---------------------------------------------------------------
  # # JupyterHub Add-on
  # #---------------------------------------------------------------
  # enable_jupyterhub = true
  # jupyterhub_helm_config = {
  #   values = [templatefile("${path.module}/helm/jupyterhub/jupyterhub-values-${var.jupyter_hub_auth_mechanism}.yaml", {
  #     ssl_cert_arn                = try(data.aws_acm_certificate.issued[0].arn, "")
  #     jupyterdomain               = try("https://${var.jupyterhub_domain}/hub/oauth_callback", "")
  #     authorize_url               = var.oauth_domain != "" ? "${var.oauth_domain}/auth" : try("https://${local.cognito_custom_domain}.auth.${local.region}.amazoncognito.com/oauth2/authorize", "")
  #     token_url                   = var.oauth_domain != "" ? "${var.oauth_domain}/token" : try("https://${local.cognito_custom_domain}.auth.${local.region}.amazoncognito.com/oauth2/token", "")
  #     userdata_url                = var.oauth_domain != "" ? "${var.oauth_domain}/userinfo" : try("https://${local.cognito_custom_domain}.auth.${local.region}.amazoncognito.com/oauth2/userInfo", "")
  #     username_key                = try(var.oauth_username_key, "")
  #     client_id                   = var.oauth_jupyter_client_id != "" ? var.oauth_jupyter_client_id : try(aws_cognito_user_pool_client.user_pool_client[0].id, "")
  #     client_secret               = var.oauth_jupyter_client_secret != "" ? var.oauth_jupyter_client_secret : try(aws_cognito_user_pool_client.user_pool_client[0].client_secret, "")
  #     user_pool_id                = try(aws_cognito_user_pool.pool[0].id, "")
  #     identity_pool_id            = try(aws_cognito_identity_pool.identity_pool[0].id, "")
  #     jupyter_single_user_sa_name = kubernetes_service_account_v1.jupyterhub_single_user_sa.metadata[0].name
  #     region                      = var.region
  #   })]
  #   version = "3.2.1"
  # }


  enable_volcano = true
  #---------------------------------------
  # Kuberay Operator
  #---------------------------------------
  enable_kuberay_operator = true
  kuberay_operator_helm_config = {
    version = "1.1.1"
    # Enabling Volcano as Batch scheduler for KubeRay Operator
    values = [
      <<-EOT
      batchScheduler:
        enabled: true
    EOT
    ]
  }

  #---------------------------------------------------------------
  # NVIDIA Device Plugin Add-on
  #---------------------------------------------------------------
  enable_nvidia_device_plugin = true
  nvidia_device_plugin_helm_config = {
    version = "v0.16.1"
    name    = "nvidia-device-plugin"
    values = [
      <<-EOT
        gfd:
          enabled: true
        nfd:
          worker:
            tolerations:
              - key: nvidia.com/gpu
                operator: Exists
                effect: NoSchedule
              - operator: "Exists"
      EOT
    ]
  }

  #---------------------------------------
  # EFA Device Plugin Add-on
  #---------------------------------------
  # IMPORTANT: Enable EFA only on nodes with EFA devices attached.
  # Otherwise, you'll encounter the "No devices found..." error. Restart the pod after attaching an EFA device, or use a node selector to prevent incompatible scheduling.
  enable_aws_efa_k8s_device_plugin = var.enable_aws_efa_k8s_device_plugin
  aws_efa_k8s_device_plugin_helm_config = {
    values = [file("${path.module}/helm-values/aws-efa-k8s-device-plugin-values.yaml")]
  }

  #---------------------------------------------------------------
  # Kubecost Add-on
  #---------------------------------------------------------------
  enable_kubecost = var.enable_kubecost
  kubecost_helm_config = {
    values              = [templatefile("${path.module}/helm-values/kubecost-values.yaml", {})]
    version             = "2.2.2"
    repository_username = data.aws_ecrpublic_authorization_token.token.user_name
    repository_password = data.aws_ecrpublic_authorization_token.token.password
  }

  #---------------------------------------------------------------
  # Karpenter Resources Add-on
  #---------------------------------------------------------------
  enable_karpenter_resources = true
  karpenter_resources_helm_config = {

       inf2-resources-karpenter = {
      values = [
        <<-EOT
      name: inferentia
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0

      nodePool:
        labels:
          - type: karpenter
          - NodePool: inferentia
        taints:
          - key: aws.amazon.com/neuroncore
            value: "true"
            effect: "NoSchedule"
          - key: aws.amazon.com/neuron
            value: "true"
            effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["inf2"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: ["8xlarge", "24xlarge"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }

    trn1-resources-karpenter = {
      values = [
        <<-EOT
      name: trainium
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0

      nodePool:
        labels:
          - type: karpenter
          - NodePool: trainium
        taints:
          - key: aws.amazon.com/neuroncore
            value: "true"
            effect: "NoSchedule"
          - key: aws.amazon.com/neuron
            value: "true"
            effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["trn1"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: ["2xlarge", "32xlarge"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }

    g6-gpu-karpenter = {
      values = [
        <<-EOT
      name: g6-gpu-karpenter
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        amiFamily: AL2
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0
        blockDeviceMappings:
          # Root device
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 50Gi
              volumeType: gp3
              encrypted: true
          # Data device: Container resources such as images and logs
          - deviceName: /dev/xvdb
            ebs:
              volumeSize: 300Gi
              volumeType: gp3
              encrypted: true
              ${var.bottlerocket_data_disk_snpashot_id != null ? "snapshotID: ${var.bottlerocket_data_disk_snpashot_id}" : ""}

      nodePool:
        labels:
          - type: karpenter
          - NodeGroupType: g5-gpu-karpenter
          - hub.jupyter.org/node-purpose: user
        taints:
          - key: nvidia.com/gpu
            value: "Exists"
            effect: "NoSchedule"
#           - key: hub.jupyter.org/dedicated
#             operator: "Equal"
#             value: "user"
#             effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["g6"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: [ "2xlarge", "4xlarge", "8xlarge", "12xlarge" ]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }

    g6e-gpu-karpenter-ts = {
      values = [
        <<-EOT
      name: g6e-gpu-karpenter-ts
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        amiFamily: AL2
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0
        blockDeviceMappings:
          # Root device
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 50Gi
              volumeType: gp3
              encrypted: true
          # Data device: Container resources such as images and logs
          - deviceName: /dev/xvdb
            ebs:
              volumeSize: 300Gi
              volumeType: gp3
              encrypted: true
              ${var.bottlerocket_data_disk_snpashot_id != null ? "snapshotID: ${var.bottlerocket_data_disk_snpashot_id}" : ""}

      nodePool:
        labels:
          - type: karpenter
          - NodeGroupType: g5-gpu-karpenter
          - hub.jupyter.org/node-purpose: user
        taints:
          - key: nvidia.com/gpu
            value: "Exists"
            effect: "NoSchedule"
#           - key: hub.jupyter.org/dedicated
#             operator: "Equal"
#             value: "user"
#             effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["g6e"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: [ "2xlarge", "4xlarge", "8xlarge", "12xlarge" ]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }

    g6e-gpu-karpenter = {
      values = [
        <<-EOT
      name: g6e-gpu-karpenter
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        amiFamily: AL2
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0
        blockDeviceMappings:
          # Root device
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 50Gi
              volumeType: gp3
              encrypted: true
          # Data device: Container resources such as images and logs
          - deviceName: /dev/xvdb
            ebs:
              volumeSize: 300Gi
              volumeType: gp3
              encrypted: true
              ${var.bottlerocket_data_disk_snpashot_id != null ? "snapshotID: ${var.bottlerocket_data_disk_snpashot_id}" : ""}

      nodePool:
        labels:
          - type: karpenter
          - NodeGroupType: g5-gpu-karpenter
          - hub.jupyter.org/node-purpose: user
        taints:
          - key: nvidia.com/gpu
            value: "Exists"
            effect: "NoSchedule"
#           - key: hub.jupyter.org/dedicated
#             operator: "Equal"
#             value: "user"
#             effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["g6e"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: [ "2xlarge", "4xlarge", "8xlarge", "12xlarge" ]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }

    g5-gpu-karpenter = {
      values = [
        <<-EOT
      name: g5-gpu-karpenter
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        amiFamily: AL2
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0
        blockDeviceMappings:
          # Root device
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 50Gi
              volumeType: gp3
              encrypted: true
          # Data device: Container resources such as images and logs
          - deviceName: /dev/xvdb
            ebs:
              volumeSize: 300Gi
              volumeType: gp3
              encrypted: true
              ${var.bottlerocket_data_disk_snpashot_id != null ? "snapshotID: ${var.bottlerocket_data_disk_snpashot_id}" : ""}

      nodePool:
        labels:
          - type: karpenter
          - NodeGroupType: g5-gpu-karpenter
          - hub.jupyter.org/node-purpose: user
        taints:
          - key: nvidia.com/gpu
            value: "Exists"
            effect: "NoSchedule"
#           - key: hub.jupyter.org/dedicated
#             operator: "Equal"
#             value: "user"
#             effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["g5"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: [ "2xlarge", "4xlarge", "8xlarge", "12xlarge" ]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["on-demand"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }


    g4dn-gpu-karpenter = {
      values = [
        <<-EOT
      name: g4dn-gpu-karpenter
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        amiFamily: AL2
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[2]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        instanceStorePolicy: RAID0
        blockDeviceMappings:
          # Root device
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 50Gi
              volumeType: gp3
              encrypted: true
          # Data device: Container resources such as images and logs
          - deviceName: /dev/xvdb
            ebs:
              volumeSize: 300Gi
              volumeType: gp3
              encrypted: true
              ${var.bottlerocket_data_disk_snpashot_id != null ? "snapshotID: ${var.bottlerocket_data_disk_snpashot_id}" : ""}

      nodePool:
        labels:
          - type: karpenter
          - NodeGroupType: g4dn-gpu-karpenter
          - hub.jupyter.org/node-purpose: user
        taints:
          - key: nvidia.com/gpu
            value: "Exists"
            effect: "NoSchedule"
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["g4dn"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: [ "2xlarge", "4xlarge", "8xlarge", "12xlarge" ]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["spot", "on-demand"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }
    x86-cpu-karpenter = {
      values = [
        <<-EOT
      name: x86-cpu-karpenter
      clusterName: ${module.eks.cluster_name}
      ec2NodeClass:
        amiFamily: AL2
        karpenterRole: ${split("/", module.eks_blueprints_addons.karpenter.node_iam_role_arn)[1]}
        subnetSelectorTerms:
          id: ${module.vpc.private_subnets[3]}
        securityGroupSelectorTerms:
          tags:
            Name: ${module.eks.cluster_name}-node
        # instanceStorePolicy: RAID0
        blockDeviceMappings:
          # Root device
          - deviceName: /dev/xvda
            ebs:
              volumeSize: 100Gi
              volumeType: gp3
              encrypted: true
          # Data device: Container resources such as images and logs
          - deviceName: /dev/xvdb
            ebs:
              volumeSize: 300Gi
              volumeType: gp3
              encrypted: true
              ${var.bottlerocket_data_disk_snpashot_id != null ? "snapshotID: ${var.bottlerocket_data_disk_snpashot_id}" : ""}

      nodePool:
        labels:
          - type: karpenter
          - NodeGroupType: x86-cpu-karpenter
          - hub.jupyter.org/node-purpose: user
        requirements:
          - key: "karpenter.k8s.aws/instance-family"
            operator: In
            values: ["m5"]
          - key: "karpenter.k8s.aws/instance-size"
            operator: In
            values: [ "xlarge", "2xlarge", "4xlarge", "8xlarge"]
          - key: "kubernetes.io/arch"
            operator: In
            values: ["amd64"]
          - key: "karpenter.sh/capacity-type"
            operator: In
            values: ["spot", "on-demand"]
        limits:
          cpu: 1000
        disruption:
          consolidationPolicy: WhenEmpty
          consolidateAfter: 300s
          expireAfter: 720h
        weight: 100
      EOT
      ]
    }
  }

  depends_on = [
    kubernetes_secret_v1.huggingface_token,
    kubernetes_config_map_v1.notebook
  ]
}


#---------------------------------------------------------------
# Additional Resources
#---------------------------------------------------------------

resource "kubernetes_namespace_v1" "jupyterhub" {
  metadata {
    name = "jupyterhub"
  }
}

resource "kubernetes_namespace_v1" "raycluster" {
  metadata {
    name = "fsi-ray"
  }
}

resource "kubernetes_secret_v1" "huggingface_token" {
  metadata {
    name      = "hf-token"
    namespace = kubernetes_namespace_v1.jupyterhub.id
  }

  data = {
    token = var.huggingface_token
  }
}

resource "kubernetes_config_map_v1" "notebook" {
  metadata {
    name      = "notebook"
    namespace = kubernetes_namespace_v1.jupyterhub.id
  }

  data = {
    # "01_Data-Handling.ipynb" = file("${path.module}/src/notebook/01_Data-Handling.ipynb")
    # "02_Stock-Screener.ipynb" = file("${path.module}/src/notebook/02_Stock-Screener.ipynb")
    # "03_Trading-Strategies-Paradigms.ipynb" = file("${path.module}/src/notebook/03_Trading-Strategies-Paradigms.ipynb")
    # "04_Regression-Recap-and-Asset-Pricing-Models.ipynb" = file("${path.module}/src/notebook/04_Regression-Recap-and-Asset-Pricing-Models.ipynb")
    # "05_Time-Series-Forecasting.ipynb" = file("${path.module}/src/notebook/05_Time-Series-Forecasting.ipynb")
    # "07_Strategy-Testing.ipynb" = file("${path.module}/src/notebook/07_Strategy-Testing.ipynb")
    # "08_Connect-to-a-trading-API.ipynb" = file("${path.module}/src/notebook/08_Connect-to-a-trading-API.ipynb")
    # "Introduction-to-Algorithmic-Trading.ipynb" = file("${path.module}/src/notebook/Introduction-to-Algorithmic-Trading.ipynb")
    # "Introduction-to-Python.ipynb" = file("${path.module}/src/notebook/Introduction-to-Python.ipynb")
    # "Machine-Learning-for-Algo-Trading.ipynb" = file("${path.module}/src/notebook/Machine-Learning-for-Algo-Trading.ipynb")
    "backtesting-parallel.py" = file("${path.module}/src/scripts/backtesting-parallel.py")
    "install-ray-on-jupyterhub-by-conda.sh" = file("${path.module}/src/scripts/install-ray-on-jupyterhub-by-conda.sh")
    "ray-job-backtesting-qstrader.ipynb" = file("${path.module}/src/notebook/ray-job-backtesting-qstrader.ipynb")
    "ray-job-backtesting-backtrader.ipynb" = file("${path.module}/src/notebook/ray-job-backtesting-backtrader.ipynb")
    "requirements.txt" = file("${path.module}/src/scripts/requirements.txt")
    "verify-ray-enviorment.ipynb" = file("${path.module}/src/notebook/verify-ray-enviorment.ipynb")
  }
}

#---------------------------------------------------------------
# Grafana Admin credentials resources
# Login to AWS secrets manager with the same role as Terraform to extract the Grafana admin password with the secret name as "grafana"
#---------------------------------------------------------------
data "aws_secretsmanager_secret_version" "admin_password_version" {
  secret_id  = aws_secretsmanager_secret.grafana.id
  depends_on = [aws_secretsmanager_secret_version.grafana]
}

resource "random_password" "grafana" {
  length           = 16
  special          = true
  override_special = "@_"
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "grafana" {
  name_prefix             = "${local.name}-oss-grafana"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = random_password.grafana.result
}

data "aws_iam_policy_document" "karpenter_controller_policy" {
  statement {
    actions = [
      "ec2:RunInstances",
      "ec2:CreateLaunchTemplate",
    ]
    resources = ["*"]
    effect    = "Allow"
    sid       = "KarpenterControllerAdditionalPolicy"
  }
}

#-----------------------------------------------------------------------------------------
# JupyterHub Sinlgle User IRSA, maybe that block could be incorporated in add-on registry
#-----------------------------------------------------------------------------------------
module "jupyterhub_single_user_irsa" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name = "${module.eks.cluster_name}-jupyterhub-single-user-sa"

  role_policy_arns = {
    policy = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess" # Policy needs to be defined based in what you need to give access to your notebook instances.
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${kubernetes_namespace_v1.jupyterhub.metadata[0].name}:jupyterhub-single-user"]
    }
  }
}

resource "kubernetes_service_account_v1" "jupyterhub_single_user_sa" {
  metadata {
    name        = "${module.eks.cluster_name}-jupyterhub-single-user"
    namespace   = kubernetes_namespace_v1.jupyterhub.metadata[0].name
    annotations = { "eks.amazonaws.com/role-arn" : module.jupyterhub_single_user_irsa.iam_role_arn }
  }

  automount_service_account_token = true
}

resource "kubernetes_secret_v1" "jupyterhub_single_user" {
  metadata {
    name      = "${module.eks.cluster_name}-jupyterhub-single-user-secret"
    namespace = kubernetes_namespace_v1.jupyterhub.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name"      = kubernetes_service_account_v1.jupyterhub_single_user_sa.metadata[0].name
      "kubernetes.io/service-account.namespace" = kubernetes_namespace_v1.jupyterhub.metadata[0].name
    }
  }

  type = "kubernetes.io/service-account-token"
}

#---------------------------------------------------------------
# EFS Filesystem for private volumes per user
# This will be replaced with Dynamic EFS provision using EFS CSI Driver
#---------------------------------------------------------------
resource "aws_efs_file_system" "efs" {
  encrypted = true

  tags = local.tags
}

#---------------------------------------------------------------
# module.vpc.private_subnets = [AZ1_10.x, AZ2_10.x, AZ1_100.x, AZ2_100.x]
# We use index 2 and 3 to select the subnet in AZ1 with the 100.x CIDR:
# Create EFS mount targets for the 3rd  subnet
resource "aws_efs_mount_target" "efs_mt_1" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = module.vpc.private_subnets[2]
  security_groups = [aws_security_group.efs.id]
}

# Create EFS mount target for the 4th subnet
resource "aws_efs_mount_target" "efs_mt_2" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = module.vpc.private_subnets[3]
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${local.name}-efs"
  description = "Allow inbound NFS traffic from private subnets of the VPC"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow NFS 2049/tcp"
    cidr_blocks = module.vpc.vpc_secondary_cidr_blocks
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
  }

  tags = local.tags
}

#---------------------------------------------------------------
# EFS Storage Class
#---------------------------------------------------------------
resource "kubernetes_storage_class" "efs_storage_class" {
  metadata {
    name = "efs-fc"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner = "efs.csi.aws.com" # AWS EFS CSI 驱动
  reclaim_policy      = "Retain"         # EFS 通常是保留数据
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap" # Access Point 模式
    fileSystemId     = aws_efs_file_system.efs.id # 替换为你的 EFS 文件系统 ID
    directoryPerms   = "700"    # 目录权限
  }

  depends_on = [aws_efs_file_system.efs]
}

#---------------------------------------
# EFS Configuration
#---------------------------------------
module "efs_config" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  helm_releases = {
    efs = {
      name             = "efs"
      description      = "A Helm chart for storage configurations"
      namespace        = "jupyterhub"
      create_namespace = false
      chart            = "${path.module}/helm-values/efs"
      chart_version    = "0.0.1"
      values = [
        <<-EOT
          pv:
            name: efs-persist
            dnsName: ${aws_efs_file_system.efs.dns_name}
          pvc:
            name: efs-persist
        EOT
      ]
    }
    efs-shared = {
      name             = "efs-shared"
      description      = "A Helm chart for shared storage configurations"
      namespace        = "jupyterhub"
      create_namespace = false
      chart            = "${path.module}/helm-values/efs"
      chart_version    = "0.0.1"
      values = [
        <<-EOT
          pv:
            name: efs-persist-shared
            dnsName: ${aws_efs_file_system.efs.dns_name}
          pvc:
            name: efs-persist-shared
        EOT
      ]
    }
    efs-shared-ray = {
      name             = "efs-shared-ray"
      description      = "A Helm chart for shared storage configurations"
      namespace        = "fsi-ray"
      create_namespace = false
      chart            = "${path.module}/helm-values/efs"
      chart_version    = "0.0.1"
      values = [
        <<-EOT
          pv:
            name: efs-shared-ray
            dnsName: ${aws_efs_file_system.efs.dns_name}
          pvc:
            name: efs-shared-ray
        EOT
      ]
    }
  }

  depends_on = [kubernetes_namespace_v1.jupyterhub, kubernetes_namespace_v1.raycluster]
}

#---------------------------------------
# Ray Cluster Config
#---------------------------------------
module "ray_cluster" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.2"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  helm_releases = {
    ray_cluster = {
      name             = "ray-cluster"
      description      = "A Helm chart for RayCluster"
      namespace        = "fsi-ray"
      create_namespace = false
      chart            = "${path.module}/helm-values/raycluster"  # 更新路径
      chart_version    = "0.1.0"
      values           = [file("${path.module}/helm-values/raycluster/values.yaml")]
    }
  }

  depends_on = [kubernetes_storage_class.default_gp3, kubernetes_namespace_v1.raycluster, module.efs_config]
}
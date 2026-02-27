terraform {
  required_version = ">= 1.7.0"
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12.0"
    }
  }
}

# ── Providers ─────────────────────────────────────────────────────────────────

provider "kind" {}

provider "kubernetes" {
  config_path = kind_cluster.search_cluster.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = kind_cluster.search_cluster.kubeconfig_path
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "search-cluster"
}

variable "es_namespace" {
  description = "Kubernetes namespace for Elasticsearch"
  type        = string
  default     = "elasticsearch"
}

variable "app_namespace" {
  description = "Kubernetes namespace for application services"
  type        = string
  default     = "search-app"
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace for monitoring stack"
  type        = string
  default     = "monitoring"
}

# ── Kind Cluster ──────────────────────────────────────────────────────────────

resource "kind_cluster" "search_cluster" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    # 1 control plane + 3 worker nodes
    node {
      role = "control-plane"
      kubeadm_config_patches = [
        <<-EOT
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
        EOT
      ]
      extra_port_mappings {
        container_port = 80
        host_port      = 80
        protocol       = "TCP"
      }
      extra_port_mappings {
        container_port = 443
        host_port      = 443
        protocol       = "TCP"
      }
    }

    # Worker node 1 - Elasticsearch
    node {
      role = "worker"
      labels = {
        workload = "elasticsearch"
      }
      extra_mounts {
        host_path      = "/tmp/es-data-01"
        container_path = "/var/local-path-provisioner"
      }
    }

    # Worker node 2 - Elasticsearch
    node {
      role = "worker"
      labels = {
        workload = "elasticsearch"
      }
      extra_mounts {
        host_path      = "/tmp/es-data-02"
        container_path = "/var/local-path-provisioner"
      }
    }

    # Worker node 3 - Application workloads
    node {
      role = "worker"
      labels = {
        workload = "application"
      }
    }
  }
}

# ── Namespaces ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "elasticsearch" {
  metadata {
    name = var.es_namespace
    labels = {
      name = var.es_namespace
    }
  }
  depends_on = [kind_cluster.search_cluster]
}

resource "kubernetes_namespace" "search_app" {
  metadata {
    name = var.app_namespace
    labels = {
      name = var.app_namespace
    }
  }
  depends_on = [kind_cluster.search_cluster]
}

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
    labels = {
      name = var.monitoring_namespace
    }
  }
  depends_on = [kind_cluster.search_cluster]
}

# ── Elasticsearch via Helm (ECK Operator) ─────────────────────────────────────

resource "helm_release" "eck_operator" {
  name             = "elastic-operator"
  repository       = "https://helm.elastic.co"
  chart            = "eck-operator"
  version          = "2.11.1"
  namespace        = "elastic-system"
  create_namespace = true

  depends_on = [kubernetes_namespace.elasticsearch]
}

# ── Prometheus + Grafana via kube-prometheus-stack ────────────────────────────

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "57.2.0"
  namespace  = var.monitoring_namespace

  values = [
    file("${path.module}/helm-values/prometheus-stack-values.yml")
  ]

  depends_on = [kubernetes_namespace.monitoring]
}

# ── Ingress Controller (nginx) ────────────────────────────────────────────────

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = "4.10.0"
  namespace        = "ingress-nginx"
  create_namespace = true

  set {
    name  = "controller.hostPort.enabled"
    value = "true"
  }
  set {
    name  = "controller.nodeSelector.ingress-ready"
    value = "true"
  }
  set {
    name  = "controller.tolerations[0].key"
    value = "node-role.kubernetes.io/control-plane"
  }
  set {
    name  = "controller.tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [kind_cluster.search_cluster]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "kubeconfig_path" {
  description = "Path to the kubeconfig for the kind cluster"
  value       = kind_cluster.search_cluster.kubeconfig_path
}

output "cluster_name" {
  description = "Name of the kind cluster"
  value       = kind_cluster.search_cluster.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = kind_cluster.search_cluster.endpoint
}

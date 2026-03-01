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
  config_path    = "~/.kube/config"
  config_context = "kind-kind"
}

provider "helm" {
  kubernetes {
    config_path    = "~/.kube/config"
    config_context = "kind-kind"
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the kind cluster"
  type        = string
  default     = "kind"
}

variable "monitoring_namespace" {
  description = "Kubernetes namespace for monitoring stack"
  type        = string
  default     = "monitoring"
}

variable "es_host" {
  description = "Elasticsearch host IP reachable from Kind network"
  type        = string
  default     = "172.18.0.1"
}

variable "es_password" {
  description = "Elasticsearch password"
  type        = string
  default     = "changeme"
  sensitive   = true
}

# ── Kind Cluster ──────────────────────────────────────────────────────────────

resource "kind_cluster" "search_cluster" {
  name           = var.cluster_name
  wait_for_ready = true

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

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
  }
}

# ── Namespaces ────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = var.monitoring_namespace
    labels = {
      name = var.monitoring_namespace
    }
  }
  depends_on = [kind_cluster.search_cluster]
}

# ── Ingress Controller ────────────────────────────────────────────────────────

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

# ── Prometheus + Grafana ──────────────────────────────────────────────────────

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

# ── Elasticsearch external service ────────────────────────────────────────────

resource "kubernetes_service" "elasticsearch" {
  metadata {
    name      = "elasticsearch"
    namespace = "default"
  }
  spec {
    port {
      port        = 9200
      target_port = 9200
    }
  }
  depends_on = [kind_cluster.search_cluster]
}

resource "kubernetes_endpoints" "elasticsearch" {
  metadata {
    name      = "elasticsearch"
    namespace = "default"
  }
  subset {
    address {
      ip = var.es_host
    }
    port {
      port = 9200
    }
  }
  depends_on = [kind_cluster.search_cluster]
}

# ── Elasticsearch credentials secret ─────────────────────────────────────────

resource "kubernetes_secret" "elasticsearch_credentials" {
  metadata {
    name      = "elasticsearch-credentials"
    namespace = "default"
  }
  data = {
    password = var.es_password
  }
  depends_on = [kind_cluster.search_cluster]
}

# ── Load images + deploy apps ─────────────────────────────────────────────────

resource "null_resource" "load_images" {
  provisioner "local-exec" {
    command = <<-EOT
      kind load docker-image search-api:latest --name ${var.cluster_name}
      kind load docker-image search-ui:latest --name ${var.cluster_name}
    EOT
  }
  depends_on = [kind_cluster.search_cluster]
}

resource "null_resource" "deploy_apps" {
  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f ${path.module}/../k8s-configs/apps/ --context kind-${var.cluster_name}
      kubectl apply -f ${path.module}/../k8s-configs/ingress/search-ingress.yaml --context kind-${var.cluster_name}
    EOT
  }
  depends_on = [
    null_resource.load_images,
    helm_release.ingress_nginx,
    kubernetes_secret.elasticsearch_credentials,
    kubernetes_endpoints.elasticsearch,
  ]
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "cluster_name" {
  value = kind_cluster.search_cluster.name
}

output "grafana_url" {
  value = "http://localhost/grafana"
}

output "prometheus_note" {
  value = "kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090"
}

output "search_ui_url" {
  value = "http://localhost"
}

output "search_api_url" {
  value = "http://localhost/api/v1/search"
}

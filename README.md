# search-infra

Infrastructure-as-code and Kubernetes configuration for the SearchX platform. Contains Helm charts, ArgoCD app definitions, Kubernetes manifests, Terraform, and a startup script for the full local Kind cluster.

---

## What's in Here

```
search-infra/
├── helm-charts/
│   ├── search-api/                # Helm chart for search-api
│   │   ├── Chart.yaml
│   │   ├── values.yaml            # image tag updated by GitHub Actions CI/CD
│   │   └── templates/
│   │       ├── deployment.yaml    # 2 replicas, ES env vars, readiness/liveness probes
│   │       ├── service.yaml
│   │       ├── hpa.yaml           # Horizontal Pod Autoscaler
│   │       └── servicemonitor.yaml # Prometheus scrape config
│   └── search-ui/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           ├── deployment.yaml
│           └── service.yaml
├── k8s-configs/
│   ├── argocd/                    # ArgoCD app definitions
│   │   ├── search-api-app.yaml
│   │   └── search-ui-app.yaml
│   ├── elasticsearch/             # ECK Elasticsearch and Kibana CRs
│   │   ├── elasticsearch.yaml     # ECK Elasticsearch cluster (single node, 10Gi PVC)
│   │   └── kibana.yaml            # ECK Kibana
│   ├── ingress/                   # Nginx ingress rules
│   │   ├── search-ingress.yaml    # / → search-ui, /api → search-api
│   │   ├── kibana-ingress.yaml    # /kibana → Kibana (HTTPS backend)
│   │   └── argocd-ingress.yaml    # /argocd → ArgoCD server
│   ├── prometheus-mcp/            # prometheus-mcp deployment and service
│   │   └── deployment.yaml
│   └── observability-console/     # observability-console deployment and ingress
│       ├── deployment.yaml
│       └── ingress.yaml           # /ops → console, /mcp → prometheus-mcp
├── terraform/
│   ├── main.tf                    # Kind cluster, Helm releases (prometheus-stack, nginx-ingress)
│   └── helm-values/
│       └── prometheus-stack-values.yml  # Grafana subpath, Prometheus retention
└── Makefile                       # cluster-create, ingress-install, apps-deploy, load-images
```

---

## Cluster Overview

Everything runs in a single-node Kind cluster on a local Fedora Linux VM (ARM aarch64).

| Namespace | What's Running |
|---|---|
| `default` | search-api (2 replicas), search-ui, prometheus-mcp, observability-console |
| `elasticsearch` | ECK operator, Elasticsearch (single node), Kibana |
| `monitoring` | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| `argocd` | ArgoCD (7 pods) |
| `ingress-nginx` | Nginx ingress controller |
| `elastic-system` | ECK operator |

---

## Ingress Routes

All traffic enters through nginx ingress on port 80:

| Path | Service |
|---|---|
| `/` | search-ui |
| `/api/v1/` | search-api |
| `/grafana` | Grafana (monitoring namespace) |
| `/argocd` | ArgoCD server |
| `/kibana` | Kibana (HTTPS backend, ECK) |
| `/ops` | observability-console |
| `/mcp` | prometheus-mcp |

---

## GitOps Flow

```
git push to search-api or search-ui
        │
        ▼
GitHub Actions
  - Build JAR / npm build
  - Build Docker image
  - Push to ghcr.io
  - Update helm-charts/<app>/values.yaml with new image tag
  - Push to search-infra
        │
        ▼
ArgoCD detects change in search-infra
  - Renders Helm chart
  - Applies to Kind cluster
  - Pods rolling update
```

ArgoCD is configured with auto-sync, self-heal, and auto-prune. It watches the `main` branch of this repo.

---

## Elasticsearch (ECK)

Elasticsearch runs via the Elastic Cloud on Kubernetes (ECK) operator version 2.11.1. Key configuration:

- Single node, version 8.12.2
- `node.store.allow_mmap: false` (required for Kind)
- Resources: 1.5Gi request / 2Gi limit, `-Xms1g -Xmx1g`
- PVC: 10Gi ReadWriteOnce
- TLS enabled (ECK self-signed cert)
- Password stored in ECK-generated secret `searchx-es-elastic-user`

In-cluster URL: `https://searchx-es-http.elasticsearch.svc.cluster.local:9200`

---

## Observability Stack

Deployed via `kube-prometheus-stack` Helm chart. Includes:

- **Prometheus** — scrapes search-api via `ServiceMonitor`, retains 15 days
- **Grafana** — accessible at `http://localhost/grafana` (admin/admin123), subpath configured
- **Alertmanager** — installed but not configured
- **prometheus-mcp** — custom Node.js server that wraps Prometheus as AI tool endpoints
- **observability-console** — standalone React app at `http://localhost/ops`, AI chat powered by Ollama with live Prometheus context

---

## Helm Charts

The Helm charts for `search-api` and `search-ui` are simple single-service charts. The image tag in `values.yaml` is the primary thing that changes — GitHub Actions updates it on every push to trigger ArgoCD deploys.

Note: ArgoCD application specs must not have hardcoded `helm.parameters` overrides for `image.tag`, as these override `values.yaml` and break the CI/CD flow. If you see pods not updating, check:

```bash
kubectl get application <app> -n argocd -o jsonpath='{.spec.source.helm}'
```

---

## Startup

After a VM reboot, run:

```bash
~/searchx-start.sh
```

This checks the Kind cluster, Ollama, ECK Elasticsearch health, and all pod namespaces. It also restarts `argocd-repo-server` if it comes up in `Unknown` state (a known post-reboot issue).

---

## Terraform

The Terraform config in `terraform/` provisions the Kind cluster and installs the prometheus-stack and nginx-ingress Helm releases. It was used for initial cluster setup. The cluster is named `kind` (single control plane node with host port mappings for 80/443).

For day-to-day operations, `kubectl` and `helm` are used directly rather than going through Terraform.

---

## Part of SearchX

This repo contains the infrastructure for:

- [search-api](https://github.com/anupanupranjan-gif/search-api) — Spring Boot hybrid search service
- [search-ui](https://github.com/anupanupranjan-gif/search-ui) — React eCommerce frontend
- [search-catalog-indexer](https://github.com/anupanupranjan-gif/search-catalog-indexer) — Product indexing pipeline
- [prometheus-mcp](https://github.com/anupanupranjan-gif/prometheus-mcp) — Prometheus MCP server
- [observability-console](https://github.com/anupanupranjan-gif/observability-console) — AI-powered ops console

# Phase 1 - Elasticsearch Local Setup

Everything you need to get Elasticsearch 8.x + Kibana running locally with the correct index mapping.

## Prerequisites

- Docker + Docker Compose v2
- `make` (optional but recommended)
- Ansible (for index management via playbook)
- Terraform >= 1.7 + kind (for k8s cluster)

## Quick Start (Local Dev)

```bash
# 1. Copy env file (change passwords if you want)
cp .env.example .env

# 2. Start Elasticsearch + Kibana
make up
# or: docker compose up -d

# 3. Wait ~60s for ES to be healthy, then check
make es-health

# 4. Open Kibana
open http://localhost:5601
# Login: elastic / changeme
```

The `es-setup` container runs automatically and:
- Sets the `kibana_system` user password
- Creates the `search_user` role and user (used by Spring Boot)
- Creates the `products` index with the full mapping

## Index Design Decisions

### Analyzers

| Analyzer | Used For | What it does |
|---|---|---|
| `product_analyzer` | Index-time on title/description | Strips HTML, lowercases, removes stop words, stems, applies synonyms |
| `product_search_analyzer` | Search-time on title/description | Same as above (synonyms expand at search time) |
| `autocomplete_index_analyzer` | Index-time on title.autocomplete | Edge ngram (min 2, max 20) for prefix matching |
| `autocomplete_search_analyzer` | Search-time on title.autocomplete | Standard lowercase only (don't ngram the query) |
| `brand_analyzer` | Brand field | Keyword tokenizer + lowercase (exact brand matching) |

### Field Design

- `title` has 3 sub-fields: full text (product_analyzer), autocomplete (edge ngram), keyword (for sorting/aggregations)
- `category` is keyword for faceting + text sub-field for full-text search on category names
- `price` uses `scaled_float` with scaling factor 100 (stores as integer internally, efficient)
- `product_vector` is `dense_vector` with 384 dims (all-MiniLM-L6-v2 output), HNSW index for fast kNN
- `suggest` is a `completion` type with category context (powers the typeahead API)
- `image_url` has `index: false, doc_values: false` - stored but never searched or aggregated

### Synonym Handling

Synonyms are in `elasticsearch/synonyms.txt`. They're loaded at index creation time. To update synonyms on a live index you need to either:
- Close/open the index (causes brief downtime)
- Use the ES Synonyms API (ES 8.10+) for zero-downtime updates - recommended for production

## Running with Ansible

```bash
# Apply index mapping via Ansible
make ansible-apply

# Dry run first
make ansible-check
```

## Running on kind (Kubernetes)

```bash
# Initialize Terraform
make tf-init

# See what will be created
make tf-plan

# Create the cluster (takes 3-5 minutes)
make tf-apply
```

This creates:
- 1 control plane + 3 worker nodes
- ECK (Elastic Cloud on Kubernetes) operator for managing ES
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
- nginx ingress controller

## Useful Commands

```bash
make es-health       # Cluster health
make es-stats        # Doc count + index size
make es-mapping      # Show current mapping
make es-test-search  # Test a basic search
make es-test-fuzzy   # Test fuzzy matching (typo: "televison")
make logs            # Follow docker compose logs
make clean           # Remove everything including volumes
```

## Credentials

| Service | URL | User | Password |
|---|---|---|---|
| Elasticsearch | http://localhost:9200 | elastic | changeme |
| Kibana | http://localhost:5601 | elastic | changeme |
| Search App User | - | search_user | search_password_123 |

Change these in `.env` before deploying anywhere beyond your laptop.

## Next Steps

Once this is running, move to **Phase 2** - the catalog indexer which will:
1. Download the Amazon Products 2023 dataset from Hugging Face
2. Generate embeddings using all-MiniLM-L6-v2 via DJL
3. Bulk index ~117K products into the `products` index

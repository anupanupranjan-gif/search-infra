.PHONY: help up down restart logs kibana es-health es-index es-stats \
        ansible-apply tf-init tf-plan tf-apply tf-destroy clean

# ── Config ────────────────────────────────────────────────────────────────────
ES_URL      := http://localhost:9200
ES_USER     := elastic
ES_PASS     := changeme
INDEX       := products

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Docker Compose ────────────────────────────────────────────────────────────
up: ## Start Elasticsearch + Kibana locally
	docker compose up -d
	@echo "Waiting for services to be ready..."
	@sleep 5
	@echo "Kibana:        http://localhost:5601  (elastic/changeme)"
	@echo "Elasticsearch: http://localhost:9200  (elastic/changeme)"

down: ## Stop all services
	docker compose down

restart: down up ## Restart all services

logs: ## Tail logs from all services
	docker compose logs -f

logs-es: ## Tail Elasticsearch logs only
	docker compose logs -f elasticsearch

# ── Elasticsearch ─────────────────────────────────────────────────────────────
es-health: ## Check ES cluster health
	@curl -s -u $(ES_USER):$(ES_PASS) $(ES_URL)/_cluster/health?pretty

es-index: ## Show index info
	@curl -s -u $(ES_USER):$(ES_PASS) $(ES_URL)/$(INDEX)?pretty

es-stats: ## Show index stats (doc count, size)
	@curl -s -u $(ES_USER):$(ES_PASS) $(ES_URL)/$(INDEX)/_stats?pretty | \
		python3 -c "import sys,json; s=json.load(sys.stdin); \
		print(f\"Docs: {s['_all']['total']['docs']['count']}\"); \
		print(f\"Size: {s['_all']['total']['store']['size_in_bytes']//1024//1024}MB\")"

es-mapping: ## Show current index mapping
	@curl -s -u $(ES_USER):$(ES_PASS) $(ES_URL)/$(INDEX)/_mapping?pretty

es-delete-index: ## Delete the products index (careful!)
	@read -p "Delete index '$(INDEX)'? [y/N] " confirm; \
	[ "$$confirm" = "y" ] && curl -s -X DELETE -u $(ES_USER):$(ES_PASS) $(ES_URL)/$(INDEX)?pretty || echo "Aborted"

es-test-search: ## Run a quick test search
	@curl -s -u $(ES_USER):$(ES_PASS) \
		-H "Content-Type: application/json" \
		-X GET $(ES_URL)/$(INDEX)/_search \
		-d '{"query":{"match_all":{}},"size":1}' | python3 -m json.tool

es-test-fuzzy: ## Test fuzzy search (q=televison - intentional typo)
	@curl -s -u $(ES_USER):$(ES_PASS) \
		-H "Content-Type: application/json" \
		-X GET $(ES_URL)/$(INDEX)/_search \
		-d '{"query":{"multi_match":{"query":"televison","fields":["title","description"],"fuzziness":"AUTO"}},"highlight":{"fields":{"title":{},"description":{}}},"size":3}' \
		| python3 -m json.tool

es-test-vector: ## Test kNN vector search (needs indexed docs with vectors)
	@echo "Run this from search-api once the model is loaded"

# ── Ansible ───────────────────────────────────────────────────────────────────
ansible-apply: ## Apply ES index configuration via Ansible
	cd ansible && ansible-playbook \
		-i inventory/local.yml \
		playbooks/configure-elasticsearch.yml \
		-e "es_password=$(ES_PASS)"

ansible-check: ## Dry-run Ansible playbook
	cd ansible && ansible-playbook \
		-i inventory/local.yml \
		playbooks/configure-elasticsearch.yml \
		--check

# ── Terraform (kind cluster) ──────────────────────────────────────────────────
tf-init: ## Initialize Terraform
	cd terraform && terraform init

tf-plan: ## Plan Terraform changes
	cd terraform && terraform plan

tf-apply: ## Apply Terraform (creates kind cluster)
	cd terraform && terraform apply -auto-approve
	@echo "Kind cluster created. Kubeconfig at: $$(cd terraform && terraform output -raw kubeconfig_path)"

tf-destroy: ## Destroy kind cluster
	cd terraform && terraform destroy -auto-approve

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean: ## Remove volumes and stop everything
	docker compose down -v
	@echo "Volumes removed"

reset: clean up ## Full reset (destroys all ES data!)
	@echo "WARNING: All Elasticsearch data has been deleted"

# ── Kubernetes ────────────────────────────────────────────────────────────────

cluster-create:
	kind create cluster --config k8s-configs/kind/cluster.yaml

cluster-delete:
	kind delete cluster

ingress-install:
	kubectl apply -f k8s-configs/ingress/nginx-ingress-controller.yaml
	kubectl wait --namespace ingress-nginx \
	  --for=condition=ready pod \
	  --selector=app.kubernetes.io/component=controller \
	  --timeout=90s

ingress-apply:
	kubectl apply -f k8s-configs/ingress/search-ingress.yaml

apps-deploy:
	kubectl apply -f k8s-configs/apps/

cluster-bootstrap: cluster-create ingress-install ingress-apply apps-deploy
	@echo "Cluster ready."

load-images:
	kind load docker-image search-api:latest
	kind load docker-image search-ui:latest

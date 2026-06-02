#!/bin/bash
set -e
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'
echo -e "${GREEN}=== SearchX Startup ===${NC}"
# STEP 1: Kind cluster
echo -e "\n${YELLOW}[1/6] Checking Kind cluster...${NC}"
if ! kubectl get nodes &>/dev/null; then
  echo -e "${RED}Kind cluster not running. Please start Docker and recreate the cluster.${NC}"
  exit 1
fi
echo -e "${GREEN}Kind cluster: Ready${NC}"
# STEP 1.5: Fix inotify limits for Promtail
sudo sysctl -w fs.inotify.max_user_instances=512 2>/dev/null || true
sudo sysctl -w fs.inotify.max_user_watches=524288 2>/dev/null || true
# STEP 2: Ollama
echo -e "\n${YELLOW}[2/6] Checking Ollama...${NC}"
if ! systemctl is-active --quiet ollama; then
  sudo systemctl start ollama
  sleep 3
fi
if ollama list | grep -q "gemma3:1b"; then
  echo -e "${GREEN}Ollama: Running with gemma3:1b${NC}"
else
  echo -e "${YELLOW}Ollama: Running but gemma3:1b not found - pulling...${NC}"
  ollama pull gemma3:1b
fi
# STEP 2.5: Warm up Ollama model
echo -e "\n${YELLOW}[2.5/6] Warming up Ollama model...${NC}"
WARMUP_RESPONSE=$(curl -s --max-time 30 http://localhost:11434/api/generate \
  -d '{"model":"gemma3:1b","prompt":"hello","stream":false}' \
  | grep -o '"done":true' || true)
if [[ "$WARMUP_RESPONSE" == '"done":true' ]]; then
  echo -e "${GREEN}Ollama: gemma3:1b warmed up${NC}"
else
  echo -e "${YELLOW}Ollama: warmup timed out or failed — model may be slow on first query${NC}"
fi
# STEP 3: Wait for ECK Elasticsearch
echo -e "\n${YELLOW}[3/6] Checking Elasticsearch (ECK)...${NC}"
for i in $(seq 1 20); do
  STATUS=$(kubectl get elasticsearch searchx -n elasticsearch \
    -o jsonpath='{.status.health}' 2>/dev/null)
  if [[ "$STATUS" == "green" || "$STATUS" == "yellow" ]]; then
    echo -e "${GREEN}Elasticsearch: $STATUS${NC}"
    break
  fi
  echo "  Waiting for ES... ($i/20)"
  sleep 5
done
# STEP 4: Check all pods
echo -e "\n${YELLOW}[4/6] Checking application pods...${NC}"
NAMESPACES=("default" "elasticsearch" "monitoring" "argocd" "ingress-nginx" "kafka" "kong")
for ns in "${NAMESPACES[@]}"; do
  NOT_READY=$(kubectl get pods -n $ns --no-headers 2>/dev/null | \
    grep -v "Running\|Completed" | grep -v "^$" | wc -l)
  if [ "$NOT_READY" -gt 0 ]; then
    echo -e "${YELLOW}  $ns: $NOT_READY pods not ready${NC}"
    kubectl get pods -n $ns --no-headers | grep -v "Running\|Completed"
  else
    echo -e "${GREEN}  $ns: OK${NC}"
  fi
done
# Restart stuck argocd-repo-server if needed
ARGOCD_REPO=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server \
  --no-headers | grep -v "Running" | wc -l)
if [ "$ARGOCD_REPO" -gt 0 ]; then
  echo -e "${YELLOW}  Restarting argocd-repo-server...${NC}"
  kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
fi
# STEP 5: Start Kibana port-forward
echo -e "\n${YELLOW}[5/6] Starting Kibana port-forward...${NC}"
pkill -f "kubectl port-forward.*searchx-kb-http" 2>/dev/null || true
kubectl port-forward svc/searchx-kb-http 5601:5601 -n elasticsearch &>/dev/null &
sleep 2
echo -e "${GREEN}Kibana port-forward: Ready${NC}"
# STEP 6: Warm up search-api
echo -e "\n${YELLOW}[6/6] Warming up search-api...${NC}"
for i in $(seq 1 10); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    "http://localhost/api/v1/search?q=test" \
    -H "X-API-Key: searchx-dev-key-2026" || true)
  if [[ "$HTTP_CODE" == "200" ]]; then
    echo -e "${GREEN}search-api: Warmed up (HTTP 200)${NC}"
    break
  fi
  echo "  Waiting for search-api... ($i/10)"
  sleep 3
done
# Summary
echo -e "\n${GREEN}=== SearchX is Ready ===${NC}"
echo ""
echo "  Search UI      → http://localhost"
echo "  Search API     → http://localhost/api/v1/search?q=headphones"
echo "  Grafana        → http://localhost/grafana          (admin/admin123)"
echo "  ArgoCD         → http://localhost/argocd           (admin/O6U3kGNcFDY7-0ib)"
echo "  Kibana         → https://localhost:5601            (elastic/<ES_PASSWORD>)"
echo "  Prometheus     → http://localhost/prometheus/graph"
echo "  Observability  → http://localhost/ops"
echo "  NexaRank UI    → http://localhost/nexarank         (admin/admin123)"
  echo "  NexaRank API   → http://localhost/nexarank/api/v1"
  echo "  Click Intel    → http://localhost/nexarank/api/v1/click-intelligence/summary"
  echo "  Search Quality → http://localhost/nexarank/api/v1/search-quality"
echo ""
kubectl top nodes 2>/dev/null || echo "  Metrics server warming up..."
echo ""
echo "  ES Password  → $(kubectl get secret searchx-es-elastic-user \
    -n elasticsearch -o jsonpath='{.data.elastic}' | base64 -d)"

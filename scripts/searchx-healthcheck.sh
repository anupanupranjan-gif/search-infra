#!/bin/bash
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== SearchX Health Check ===${NC}"
echo -e "$(date)"
echo ""

check_http() {
  local name=$1
  local url=$2
  local expected=$3
  local code=$(curl -s -o /dev/null -w "%{http_code}" -L --max-time 5 "$url" 2>/dev/null)
  if [ "$code" == "$expected" ]; then
    echo -e "${GREEN}  OK${NC}     $name ($code) — $url"
  else
    echo -e "${RED}  FAIL${NC}   $name (got $code, expected $expected) — $url"
  fi
}

check_pod_namespace() {
  local ns=$1
  local not_ready=$(kubectl get pods -n $ns --no-headers 2>/dev/null | \
    grep -v "Running\|Completed" | grep -v "^$" | wc -l)
  local total=$(kubectl get pods -n $ns --no-headers 2>/dev/null | wc -l)
  if [ "$not_ready" -eq 0 ]; then
    echo -e "${GREEN}  OK${NC}     $ns ($total pods running)"
  else
    echo -e "${RED}  FAIL${NC}   $ns ($not_ready/$total pods not ready)"
    kubectl get pods -n $ns --no-headers | grep -v "Running\|Completed"
  fi
}

echo -e "${YELLOW}--- HTTP Endpoints ---${NC}"
check_http "SearchX UI"          "http://localhost"                        "200"
check_http "Search API"          "http://localhost/api/v1/search?q=test"  "200"
check_http "Grafana"             "http://localhost/grafana"                "200"
check_http "ArgoCD"              "http://localhost/argocd"                 "200"
check_http "Prometheus"          "http://localhost/prometheus/graph"       "200"
check_http "NexaRank UI"         "http://localhost/nexarank-ui/"           "200"
check_http "NexaRank API"        "http://localhost/nexarank/api/v1/rules"  "403"
check_http "Observability"       "http://localhost/ops"                    "200"
check_http "Kibana"              "https://localhost:5601/kibana"           "302"

echo ""
echo -e "${YELLOW}--- Pod Health ---${NC}"
check_pod_namespace "default"
check_pod_namespace "elasticsearch"
check_pod_namespace "monitoring"
check_pod_namespace "argocd"
check_pod_namespace "ingress-nginx"
check_pod_namespace "kafka"
check_pod_namespace "kong"

echo ""
echo -e "${YELLOW}--- Prometheus Alerts ---${NC}"
FIRING=$(curl -s "http://localhost/prometheus/api/v1/alerts" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); \
  alerts=[a for a in d['data']['alerts'] if a['state']=='firing']; \
  print(f'{len(alerts)} alerts firing') if alerts else print('No alerts firing'); \
  [print(f\"  FIRING: {a['labels']['alertname']}\") for a in alerts]" 2>/dev/null)
echo -e "  $FIRING"

echo ""
echo -e "${YELLOW}--- ArgoCD Sync Status ---${NC}"
kubectl get applications -n argocd --no-headers 2>/dev/null | \
  awk '{
    if ($2=="Synced" && $3=="Healthy") print "\033[0;32m  OK\033[0m     " $1 " (Synced/Healthy)"
    else print "\033[0;31m  WARN\033[0m   " $1 " (Sync=" $2 " Health=" $3 ")"
  }'

echo ""
echo -e "${YELLOW}--- Disk Usage ---${NC}"
DISK=$(df -h / | tail -1 | awk '{print $5}')
DISK_NUM=${DISK%\%}
if [ "$DISK_NUM" -lt 85 ]; then
  echo -e "${GREEN}  OK${NC}     Disk usage: $DISK"
else
  echo -e "${RED}  WARN${NC}   Disk usage: $DISK — consider running: docker system prune -f"
fi

echo ""
echo -e "${GREEN}=== Health Check Complete ===${NC}"

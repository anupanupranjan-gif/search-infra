#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Flushing search cache...${NC}"
KEYS=$(kubectl exec -n default redis-master-0 -- redis-cli SCAN 0 MATCH "search:*" COUNT 100 | grep "search:")
if [ -z "$KEYS" ]; then
  echo -e "${GREEN}Cache already empty${NC}"
  exit 0
fi
echo "$KEYS" | xargs kubectl exec -n default redis-master-0 -- redis-cli DEL
echo -e "${GREEN}Done${NC}"

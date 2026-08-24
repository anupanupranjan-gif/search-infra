#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Flushing search cache...${NC}"
# Redis is TLS-only as of the NR-155 hardening work (tls.enabled=true,
# tls.authClients=false) - plain redis-cli gets "Connection reset by peer"
# immediately, so every invocation below must pass --tls + the pod's own
# mounted cert/key/CA (client cert isn't verified, but the handshake still
# needs one presented).
REDIS_CLI=(kubectl exec -n default redis-master-0 -- redis-cli --tls \
  --cert /opt/bitnami/redis/certs/tls.crt \
  --key /opt/bitnami/redis/certs/tls.key \
  --cacert /opt/bitnami/redis/certs/ca.crt)

# A single SCAN call only returns a page plus a cursor to continue from - it does
# NOT guarantee returning every matching key in one pass, even for a small
# keyspace (Redis docs: the only iteration guarantee is across a FULL cursor
# loop back to 0). A single-shot call here was empirically confirmed to leave
# stale search:* entries behind, letting a rule change appear to have no effect
# on the next search until this script (or a later one) happened to catch the
# key it missed - loop until the cursor returns to 0 to actually guarantee a
# full flush.
CURSOR=0
DELETED=0
while :; do
  RESULT=$("${REDIS_CLI[@]}" SCAN "$CURSOR" MATCH "search:*" COUNT 100) || {
    echo -e "${YELLOW}redis-cli failed - aborting instead of looping${NC}" >&2
    exit 1
  }
  CURSOR=$(echo "$RESULT" | head -1)
  KEYS=$(echo "$RESULT" | tail -n +2 | grep "search:")
  if [ -n "$KEYS" ]; then
    COUNT=$(echo "$KEYS" | xargs "${REDIS_CLI[@]}" DEL)
    DELETED=$((DELETED + COUNT))
  fi
  [ "$CURSOR" = "0" ] && break
done
if [ "$DELETED" -eq 0 ]; then
  echo -e "${GREEN}Cache already empty${NC}"
else
  echo -e "${GREEN}Deleted $DELETED key(s)${NC}"
fi
echo -e "${GREEN}Done${NC}"

#!/bin/sh
set -e

ES_URL="http://elasticsearch:9200"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-changeme}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:-changeme}"
INDEX_NAME="products"

echo "==> Waiting for Elasticsearch to be ready..."
until curl -s -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL}/_cluster/health" | grep -q '"status"'; do
  echo "    ...still waiting"
  sleep 5
done
echo "==> Elasticsearch is up"

# ── Set kibana_system password ────────────────────────────────────────────────
echo "==> Setting kibana_system password..."
curl -s -X POST \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${ES_URL}/_security/user/kibana_system/_password" \
  -d "{\"password\": \"${KIBANA_PASSWORD}\"}"
echo ""
echo "==> kibana_system password set"

# ── Create search user (used by Spring Boot app) ─────────────────────────────
echo "==> Creating search_user..."
curl -s -X PUT \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${ES_URL}/_security/user/search_user" \
  -d '{
    "password": "search_password_123",
    "roles": ["search_role"],
    "full_name": "Search Application User"
  }'
echo ""

# ── Create search role ────────────────────────────────────────────────────────
echo "==> Creating search_role..."
curl -s -X PUT \
  -u "elastic:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${ES_URL}/_security/role/search_role" \
  -d '{
    "cluster": ["monitor"],
    "indices": [
      {
        "names": ["products*"],
        "privileges": ["read", "write", "create_index", "manage"]
      }
    ]
  }'
echo ""
echo "==> search_role created"

# ── Upload synonyms file ──────────────────────────────────────────────────────
echo "==> Uploading synonyms file..."
# Note: In production use ES synonyms API or file-based approach
# For local dev we mount the file directly to ES config directory
# This creates the analysis directory entry via the synonyms API (ES 8.x)
echo "==> Synonyms handled via mounted file in elasticsearch.yml"

# ── Create index with mapping ─────────────────────────────────────────────────
echo "==> Checking if index '${INDEX_NAME}' exists..."
INDEX_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "elastic:${ELASTIC_PASSWORD}" \
  "${ES_URL}/${INDEX_NAME}")

if [ "$INDEX_EXISTS" = "200" ]; then
  echo "==> Index '${INDEX_NAME}' already exists, skipping creation"
else
  echo "==> Creating index '${INDEX_NAME}' with mapping..."
  curl -s -X PUT \
    -u "elastic:${ELASTIC_PASSWORD}" \
    -H "Content-Type: application/json" \
    "${ES_URL}/${INDEX_NAME}" \
    --data-binary @/home/curl_user/index-mapping.json
  echo ""
  echo "==> Index '${INDEX_NAME}' created"
fi

# ── Verify cluster health ─────────────────────────────────────────────────────
echo ""
echo "==> Final cluster health:"
curl -s -u "elastic:${ELASTIC_PASSWORD}" "${ES_URL}/_cluster/health?pretty"

echo ""
echo "==> Setup complete!"
echo "    Kibana:        http://localhost:5601  (elastic / ${ELASTIC_PASSWORD})"
echo "    Elasticsearch: http://localhost:9200  (elastic / ${ELASTIC_PASSWORD})"
echo "    Index:         ${INDEX_NAME}"

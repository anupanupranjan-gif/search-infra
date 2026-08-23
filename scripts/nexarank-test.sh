#!/bin/bash
# NexaRank Quality Test Suite
# Tests core functionality against whatever tenants/data actually exist in this
# environment (post-VM-rebuild 2026-08-19: only `default` and `avinoshop` tenants,
# one group "Super Admin", no fleetpride/expedia/merch1 fixtures - those were from
# a pre-rebuild demo dataset that no longer exists).
# Usage: ./nexarank-test.sh

BASE="http://localhost/nexarank/api/v1"
PASS=0
FAIL=0
SKIP=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

section() { echo -e "\n${BLUE}--- $1 ---${NC}"; }
pass()    { echo -e "  ${GREEN}PASS${NC}  $1"; ((PASS++)); }
fail()    { echo -e "  ${RED}FAIL${NC}  $1 — $2"; ((FAIL++)); }
skip()    { echo -e "  ${YELLOW}SKIP${NC}  $1 — $2"; ((SKIP++)); }

check() {
  local desc="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    pass "$desc"
  else
    fail "$desc" "expected '$expected' in: $actual"
  fi
}

echo "========================================"
echo "  NexaRank Quality Test Suite"
echo "  $(date)"
echo "========================================"

# ── AUTH ──────────────────────────────────
section "Authentication"

ADMIN_RESP=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}')
TOKEN=$(echo "$ADMIN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token','').strip())" 2>/dev/null)

if [ -n "$TOKEN" ]; then
  pass "Admin login returns token"
  check "Admin login has tenantId=default" "\"tenantId\":\"default\"" "$ADMIN_RESP"
  check "Admin login has permissions" "RULES_VIEW" "$ADMIN_RESP"
else
  fail "Admin login" "no token returned: $ADMIN_RESP"
fi

AVINO_RESP=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"avinoshop_admin","password":"admin123"}')
AVINO_TOKEN=$(echo "$AVINO_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)

if [ -n "$AVINO_TOKEN" ]; then
  pass "avinoshop_admin login returns token"
  check "avinoshop_admin login has tenantId=avinoshop" "\"tenantId\":\"avinoshop\"" "$AVINO_RESP"
else
  fail "avinoshop_admin login" "no token: $AVINO_RESP"
fi

BAD_RESP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"wrong-password"}')
if [ "$BAD_RESP" = "401" ]; then
  pass "Bad password rejected (401)"
else
  fail "Bad password rejection" "expected 401, got $BAD_RESP"
fi

# ── TENANT ISOLATION ──────────────────────
section "Tenant Data Isolation"

if [ -n "$AVINO_TOKEN" ]; then
  ISO_RULE=$(curl -s -X POST "$BASE/rules" \
    -H "Content-Type: application/json" -H "Authorization: Bearer ${AVINO_TOKEN}" \
    -d '{"type":"BOOST","query":"isolation-test","boostField":"category.keyword","boostValue":"test","boostFactor":1.0}')
  ISO_RULE_ID=$(echo "$ISO_RULE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

  if [ -n "$ISO_RULE_ID" ]; then
    pass "avinoshop tenant can create rule"
    DEFAULT_RULES=$(curl -s "$BASE/rules" -H "Authorization: Bearer ${TOKEN}")
    if echo "$DEFAULT_RULES" | grep -q "isolation-test"; then
      fail "Tenant isolation" "default tenant can see avinoshop's rule!"
    else
      pass "Default tenant cannot see avinoshop's rules"
    fi
    curl -s -o /dev/null -X DELETE "$BASE/rules/$ISO_RULE_ID" -H "Authorization: Bearer ${AVINO_TOKEN}"
  else
    fail "avinoshop rule creation" "$ISO_RULE"
  fi
else
  skip "Tenant isolation" "no avinoshop token"
fi

# ── TENANTS ────────────────────────────────
section "Tenants"

TENANTS=$(curl -s "$BASE/admin/tenants" -H "Authorization: Bearer ${TOKEN}")
check "Tenant list returns default" "\"id\":\"default\"" "$TENANTS"
check "Tenant list returns avinoshop" "\"id\":\"avinoshop\"" "$TENANTS"

# ── RULES CRUD ────────────────────────────
section "Rules CRUD"

NEW_RULE=$(curl -s -X POST "$BASE/rules" \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
  -d '{"type":"BOOST","query":"test-quality","boostField":"category.keyword","boostValue":"Test","boostFactor":2.0}')
RULE_ID=$(echo "$NEW_RULE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$RULE_ID" ]; then
  pass "Create rule returns id"
  check "Rule has tenantId=default" "\"tenantId\":\"default\"" "$NEW_RULE"
  check "Rule starts in DRAFT" "\"status\":\"DRAFT\"" "$NEW_RULE"

  APPROVE=$(curl -s -X PATCH "$BASE/rules/$RULE_ID/approve" \
    -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
    -d '{"comment":"QA approved"}')
  # Tenant auto-publish (default true) cascades APPROVED straight to LIVE - see
  # CLAUDE.md "Rule Approval Workflow". Not a bug if you land on LIVE here.
  check "Rule approved and auto-published to LIVE" "\"status\":\"LIVE\"" "$APPROVE"

  DEL=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/rules/$RULE_ID" -H "Authorization: Bearer ${TOKEN}")
  if [ "$DEL" = "204" ] || [ "$DEL" = "200" ]; then
    pass "Rule can be deleted"
  else
    fail "Rule deletion" "HTTP $DEL"
  fi
else
  fail "Rule creation" "$NEW_RULE"
fi

# ── FACET CONFIG ──────────────────────────
section "Facet Config"

FACETS=$(curl -s "$BASE/facets" -H "Authorization: Bearer ${TOKEN}")
FACET_COUNT=$(echo "$FACETS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d))" 2>/dev/null)
if [ -n "$FACET_COUNT" ] && [ "$FACET_COUNT" -gt "0" ] 2>/dev/null; then
  pass "Facets endpoint returns $FACET_COUNT configured facets"
  check "Category facet uses .keyword field" "category.keyword" "$FACETS"
  check "Brand facet uses .keyword field" "brand.keyword" "$FACETS"
else
  fail "Facets endpoint" "$FACETS"
fi

FIELDS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/engine-config/fields" -H "Authorization: Bearer ${TOKEN}")
if [ "$FIELDS" = "200" ]; then
  pass "Fetch Fields from Engine (GET /engine-config/fields) returns 200"
else
  fail "Facet field discovery" "expected HTTP 200, got $FIELDS"
fi

# ── ENGINE CONFIG ─────────────────────────
section "Engine Config"

ENGINE=$(curl -s "$BASE/engine-config" -H "Authorization: Bearer ${TOKEN}")
check "Engine config configured for ELASTICSEARCH" "ELASTICSEARCH" "$ENGINE"

ENGINE_TEST=$(curl -s -X POST "$BASE/engine-config/test" -H "Authorization: Bearer ${TOKEN}")
check "Engine config test connection succeeds" "\"success\":true" "$ENGINE_TEST"

# ── LLM CONFIG ─────────────────────────────
section "LLM Config"

LLM=$(curl -s "$BASE/llm-config" -H "Authorization: Bearer ${TOKEN}")
check "LLM config configured for OLLAMA" "OLLAMA" "$LLM"

LLM_TEST=$(curl -s -X POST "$BASE/llm-config/test" -H "Authorization: Bearer ${TOKEN}")
if echo "$LLM_TEST" | grep -q '"success":true'; then
  pass "LLM config test connection succeeds (Ollama reachable)"
else
  fail "LLM config test connection" "$LLM_TEST — check Ollama is running with OLLAMA_HOST=0.0.0.0 (see searchx-start.sh)"
fi

# ── PIPELINE ───────────────────────────────
section "Pipeline / Rule Enrichment"

ENRICH=$(curl -s "$BASE/rules/enrich" \
  -X POST -H "Content-Type: application/json" \
  -d '{"query":"laptop"}')
check "Enrich endpoint returns response" "originalQuery" "$ENRICH"

# ── USER GROUPS ───────────────────────────
section "User Groups and Permissions"

GROUPS_RESP=$(curl -s "${BASE}/groups" -H "Authorization: Bearer ${TOKEN}")
check "Groups endpoint returns Super Admin group" "Super Admin" "$GROUPS_RESP"

PERMS=$(curl -s "$BASE/groups/permissions" -H "Authorization: Bearer ${TOKEN}")
check "Permissions endpoint returns RULES_VIEW" "RULES_VIEW" "$PERMS"
check "Permissions endpoint returns AUDIT_LOG_VIEW" "AUDIT_LOG_VIEW" "$PERMS"

# ── AUDIT LOG ─────────────────────────────
section "Audit Log"

AUDIT=$(curl -s "$BASE/audit" -H "Authorization: Bearer ${TOKEN}")
AUDIT_COUNT=$(echo "$AUDIT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('totalElements',0))" 2>/dev/null)

if [ -n "$AUDIT_COUNT" ] && [ "$AUDIT_COUNT" -gt "0" ] 2>/dev/null; then
  pass "Audit log has $AUDIT_COUNT events"
  check "Audit log has RULE_CREATED events" "RULE_CREATED" "$AUDIT"
else
  fail "Audit log" "no events found: $AUDIT"
fi

# ── AI SUGGESTIONS ────────────────────────
section "AI Suggestions"

BOOST_SUGGESTIONS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/suggestions/boost" -H "Authorization: Bearer ${TOKEN}")
if [ "$BOOST_SUGGESTIONS" = "200" ]; then
  pass "Boost suggestions endpoint returns 200"
else
  fail "Boost suggestions endpoint" "expected HTTP 200, got $BOOST_SUGGESTIONS"
fi

WQ_ADD=$(curl -s -X POST "$BASE/suggestions/watched-queries" \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
  -d '{"query":"qa-watched-query-test","expectedMinCtr":0.05,"expectedMaxPosition":3}')
WQ_ID=$(echo "$WQ_ADD" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$WQ_ID" ]; then
  pass "Watched query created"
  # Regression: WatchedQueryService.delete() used a derived JPA delete
  # query with no @Transactional wrapping it, which 500'd unconditionally
  # (not a permission issue - happened for admin too). See nexarank-api
  # commit "Fix Watched Queries delete: missing @Transactional".
  WQ_DEL=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/suggestions/watched-queries/$WQ_ID" -H "Authorization: Bearer ${TOKEN}")
  if [ "$WQ_DEL" = "204" ]; then
    pass "Watched query deleted (regression: used to 500 for everyone)"
  else
    fail "Watched query deletion" "expected HTTP 204, got $WQ_DEL"
  fi
else
  fail "Watched query creation" "$WQ_ADD"
fi

# ── CLICK INTELLIGENCE ────────────────────
section "Click Intelligence"

CLICK_BOOST=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/click-intelligence/boost-candidates?limit=20" -H "Authorization: Bearer ${TOKEN}")
if [ "$CLICK_BOOST" = "200" ]; then
  pass "Click Intelligence boost-candidates endpoint returns 200"
else
  fail "Click Intelligence boost-candidates endpoint" "expected HTTP 200, got $CLICK_BOOST"
fi

# ── TENANT BRANDING ───────────────────────
section "Tenant Branding"

DEFAULT_BRAND=$(curl -s "$BASE/admin/public/tenants/default/branding")
check "Default tenant branding returns fallback color" "0077ff" "$DEFAULT_BRAND"

AVINO_BRAND=$(curl -s "$BASE/admin/public/tenants/avinoshop/branding")
check "avinoshop branding (no auth) returns displayName" "AvinoShop" "$AVINO_BRAND"

# ── SUMMARY ───────────────────────────────
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  Total:  $TOTAL tests"
echo -e "  ${GREEN}Passed: $PASS${NC}"
if [ $FAIL -gt 0 ]; then
  echo -e "  ${RED}Failed: $FAIL${NC}"
else
  echo -e "  Failed: $FAIL"
fi
if [ $SKIP -gt 0 ]; then
  echo -e "  ${YELLOW}Skipped: $SKIP${NC}"
fi
echo "========================================"
if [ $FAIL -eq 0 ]; then
  echo -e "  ${GREEN}ALL TESTS PASSED${NC}"
else
  echo -e "  ${RED}$FAIL TEST(S) FAILED${NC}"
fi
echo "========================================"

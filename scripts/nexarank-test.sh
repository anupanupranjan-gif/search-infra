#!/bin/bash
# NexaRank Quality Test Suite
# Tests all Phase 20 functionality: auth, tenants, projects, rules, groups, audit, branding
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
  check "Admin login has tenantId" "default" "$ADMIN_RESP"
  check "Admin login has projectId" "main" "$ADMIN_RESP"
  check "Admin login has permissions" "RULES_VIEW" "$ADMIN_RESP"
else
  fail "Admin login" "no token returned: $ADMIN_RESP"
fi

MERCH_RESP=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"merch1","password":"merch123"}')
MERCH_TOKEN=$(echo "$MERCH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)
MERCH_PERMS=$(echo "$MERCH_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('permissions',[])))" 2>/dev/null)

if [ -n "$MERCH_TOKEN" ]; then
  pass "merch1 login returns token"
  if [ "$MERCH_PERMS" -ge "4" ] 2>/dev/null; then
    pass "merch1 has multiple group permissions ($MERCH_PERMS permissions)"
  else
    fail "merch1 permissions" "expected >=4, got $MERCH_PERMS"
  fi
else
  fail "merch1 login" "no token: $MERCH_RESP"
fi

FP_RESP=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"fleetpride_admin","password":"admin123"}')
FP_TOKEN=$(echo "$FP_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null)
check "fleetpride_admin login has tenantId=fleetpride" "fleetpride" "$FP_RESP"

# ── TENANT ISOLATION ──────────────────────
section "Tenant Data Isolation"

# Headers built inline to avoid variable expansion issues

# Create a FleetPride rule
FP_RULE=$(curl -s -X POST "$BASE/rules" \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${FP_TOKEN}" \
  -d '{"type":"BOOST","query":"isolation-test","boostField":"cat","boostValue":"test","boostFactor":1.0}')
FP_RULE_ID=$(echo "$FP_RULE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$FP_RULE_ID" ]; then
  pass "FleetPride can create rule"
  # Admin (default tenant) should NOT see fleetpride rule
  DEFAULT_RULES=$(curl -s "$BASE/rules" -H "Authorization: Bearer ${TOKEN}")
  if echo "$DEFAULT_RULES" | grep -q "isolation-test"; then
    fail "Tenant isolation" "default tenant can see fleetpride rule!"
  else
    pass "Default tenant cannot see FleetPride rules"
  fi
else
  fail "FleetPride rule creation" "$FP_RULE"
fi

# ── TENANTS AND PROJECTS ──────────────────
section "Tenants and Projects"

TENANTS=$(curl -s "$BASE/admin/tenants" -H "Authorization: Bearer ${TOKEN}")
check "Tenant list returns tenants" "default" "$TENANTS"
check "FleetPride tenant exists" "fleetpride" "$TENANTS"
check "Expedia tenant exists" "expedia" "$TENANTS"

FP_PROJECTS=$(curl -s "$BASE/admin/tenants/fleetpride/projects" -H "Authorization: Bearer ${TOKEN}")
check "FleetPride has Main project" "Main" "$FP_PROJECTS"
check "FleetPride has Heavy Duty Parts" "Heavy Duty" "$FP_PROJECTS"

EX_PROJECTS=$(curl -s "$BASE/admin/tenants/expedia/projects" -H "Authorization: Bearer ${TOKEN}")
check "Expedia has Vrbo project" "Vrbo" "$EX_PROJECTS"
check "Expedia has Hotels project" "Hotels" "$EX_PROJECTS"

# ── RULES CRUD ────────────────────────────
section "Rules CRUD"

NEW_RULE=$(curl -s -X POST "$BASE/rules" \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
  -d '{"type":"BOOST","query":"test-quality","boostField":"category","boostValue":"Test","boostFactor":2.0}')
RULE_ID=$(echo "$NEW_RULE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)

if [ -n "$RULE_ID" ]; then
  pass "Create rule returns id"
  check "Rule has tenantId=default" "default" "$NEW_RULE"
  check "Rule has status=PENDING_REVIEW" "PENDING_REVIEW" "$NEW_RULE"

  # Approve rule
  APPROVE=$(curl -s -X PATCH "$BASE/rules/$RULE_ID/approve" \
    -H "Content-Type: application/json" -H "Authorization: Bearer ${TOKEN}" \
    -d '{"comment":"QA approved"}')
  check "Rule can be approved" "APPROVED" "$APPROVE"

  # Delete rule
  DEL=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$BASE/rules/$RULE_ID" -H "Authorization: Bearer ${TOKEN}")
  if [ "$DEL" = "204" ] || [ "$DEL" = "200" ]; then
    pass "Rule can be deleted"
  else
    fail "Rule deletion" "HTTP $DEL"
  fi
else
  fail "Rule creation" "$NEW_RULE"
fi

# ── USER GROUPS ───────────────────────────
section "User Groups and Permissions"
GROUP_COUNT=$(curl -s "${BASE}/groups" -H "Authorization: Bearer ${TOKEN}" | python3 -c "import sys,json; d=json.load(sys.stdin); names=[g['name'] for g in d]; print('|'.join(names))" 2>/dev/null)
check "Groups endpoint returns groups" "Super Admin" "$GROUP_COUNT"
check "Merchandiser group exists" "Merchandiser" "$GROUP_COUNT"
check "Analyst group exists" "Analyst" "$GROUP_COUNT"

PERMS=$(curl -s "$BASE/groups/permissions" -H "Authorization: Bearer ${TOKEN}")
check "Permissions endpoint returns RULES_VIEW" "RULES_VIEW" "$PERMS"
check "Permissions endpoint returns AUDIT_LOG_VIEW" "AUDIT_LOG_VIEW" "$PERMS"

# merch1 group memberships
MERCH1_ID=$(kubectl exec -n default nexarank-postgres-postgresql-0 -- bash -c \
  "PGPASSWORD=nexarank2026 psql -U nexarank -d nexarank -t -c \"SELECT id FROM users WHERE username='merch1';\"" 2>/dev/null | tr -d ' \n')

if [ -n "$MERCH1_ID" ]; then
  MERCH1_GROUPS=$(curl -s "$BASE/users/$MERCH1_ID/groups" -H "Authorization: Bearer ${TOKEN}")
  if echo "$MERCH1_GROUPS" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if len(d)>=2 else 1)" 2>/dev/null; then
    pass "merch1 belongs to multiple groups"
  else
    fail "merch1 group memberships" "expected >=2 groups: $MERCH1_GROUPS"
  fi
else
  skip "merch1 group memberships" "could not get merch1 id"
fi

# ── AUDIT LOG ─────────────────────────────
section "Audit Log"

AUDIT=$(curl -s "$BASE/audit" -H "Authorization: Bearer ${TOKEN}")
AUDIT_COUNT=$(echo "$AUDIT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('totalElements',0))" 2>/dev/null)

if [ "$AUDIT_COUNT" -gt "0" ] 2>/dev/null; then
  pass "Audit log has $AUDIT_COUNT events"
  check "Audit log has RULE_CREATED events" "RULE_CREATED" "$AUDIT"
else
  fail "Audit log" "no events found: $AUDIT"
fi

# ── TENANT BRANDING ───────────────────────
section "Tenant Branding"

BRANDING=$(curl -s "$BASE/admin/public/tenants/fleetpride/branding")
check "Branding endpoint (no auth) returns displayName" "FleetPride" "$BRANDING"
check "FleetPride has brand color" "f97316" "$BRANDING"

DEFAULT_BRAND=$(curl -s "$BASE/admin/public/tenants/default/branding")
check "Default tenant branding returns fallback" "0077ff" "$DEFAULT_BRAND"

# ── RULE ENRICHMENT ───────────────────────
section "Rule Enrichment"

ENRICH=$(curl -s "$BASE/rules/enrich" \
  -X POST -H "Content-Type: application/json" \
  -d '{"query":"battery"}')
check "Enrich endpoint returns response" "originalQuery" "$ENRICH"

# ── FACET CONFIG ──────────────────────────
section "Facet Config"

FACETS=$(curl -s "$BASE/facets" -H "Authorization: Bearer ${TOKEN}")
if echo "$FACETS" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if isinstance(d,list) else 1)" 2>/dev/null; then
  pass "Facets endpoint returns list"
else
  fail "Facets endpoint" "$FACETS"
fi

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

#!/bin/bash
# NexaRank Seed Data Script
# Run after install.sh and after nexarank-api has started (Flyway runs migrations)
# This seeds tenant admins and assigns them to Super Admin groups

echo "=== NexaRank Seed Data ==="
echo "Waiting for nexarank-api to be ready..."

# Wait for API to be ready
for i in $(seq 1 30); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/nexarank/api/v1/actuator/health 2>/dev/null)
  if [ "$STATUS" = "200" ]; then
    echo "API is ready"
    break
  fi
  echo "Waiting... ($i/30)"
  sleep 5
done

BASE="http://localhost/nexarank/api/v1"

# Login as default admin
TOKEN=$(curl -s -X POST "$BASE/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | \
  python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

if [ -z "$TOKEN" ]; then
  echo "ERROR: Could not login as admin. Make sure nexarank-api is running."
  exit 1
fi
echo "Logged in as admin"

# Seed default groups for default tenant
echo "Seeding default groups..."
curl -s -X POST "$BASE/groups/seed?tenantId=default" \
  -H "Authorization: Bearer $TOKEN" > /dev/null

# Create FleetPride tenant
echo "Creating FleetPride tenant..."
curl -s -X POST "$BASE/admin/tenants" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"id":"fleetpride","displayName":"FleetPride"}' > /dev/null

curl -s -X POST "$BASE/admin/tenants/fleetpride/projects" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"Heavy Duty Parts"}' > /dev/null

curl -s -X PUT "$BASE/admin/tenants/fleetpride/branding" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"brandColor":"#f97316","logoUrl":""}' > /dev/null

curl -s -X POST "$BASE/groups/seed?tenantId=fleetpride" \
  -H "Authorization: Bearer $TOKEN" > /dev/null

# Create Expedia tenant
echo "Creating Expedia tenant..."
curl -s -X POST "$BASE/admin/tenants" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"id":"expedia","displayName":"Expedia Group"}' > /dev/null

curl -s -X POST "$BASE/admin/tenants/expedia/projects" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"Vrbo"}' > /dev/null

curl -s -X POST "$BASE/admin/tenants/expedia/projects" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"name":"Hotels"}' > /dev/null

curl -s -X POST "$BASE/groups/seed?tenantId=expedia" \
  -H "Authorization: Bearer $TOKEN" > /dev/null

# Create tenant admin users using bcrypt via Python
echo "Creating tenant admin users..."
python3 << 'PYEOF'
import bcrypt, subprocess, json

def create_user_and_assign_superadmin(username, tenant_id, password='admin123'):
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=10, prefix=b'2a')).decode()
    sql = f"""
INSERT INTO users (id, tenant_id, username, password, role, enabled)
VALUES ('{username}', '{tenant_id}', '{username}', '{hashed}', 'ADMIN', true)
ON CONFLICT (tenant_id, username) DO NOTHING;
"""
    with open('/tmp/seed_user.sql', 'w') as f:
        f.write(sql)
    subprocess.run(['kubectl', 'cp', '/tmp/seed_user.sql',
        'default/nexarank-postgres-postgresql-0:/tmp/seed_user.sql'])
    subprocess.run(['kubectl', 'exec', '-n', 'default', 'nexarank-postgres-postgresql-0',
        '--', 'bash', '-c',
        'PGPASSWORD=nexarank2026 psql -U nexarank -d nexarank -f /tmp/seed_user.sql'],
        capture_output=True)
    print(f"  Created {username}")

create_user_and_assign_superadmin('fleetpride_admin', 'fleetpride')
create_user_and_assign_superadmin('expedia_admin', 'expedia')
PYEOF

# Assign super admin groups via API
echo "Assigning Super Admin groups..."
python3 << 'PYEOF'
import subprocess, json

def get_super_admin_group(tenant_id):
    result = subprocess.run(['kubectl', 'exec', '-n', 'default', 'nexarank-postgres-postgresql-0',
        '--', 'bash', '-c',
        f"PGPASSWORD=nexarank2026 psql -U nexarank -d nexarank -t -c \"SELECT id FROM user_groups WHERE tenant_id='{tenant_id}' AND name='Super Admin';\""],
        capture_output=True, text=True)
    return result.stdout.strip()

def get_user_id(username):
    result = subprocess.run(['kubectl', 'exec', '-n', 'default', 'nexarank-postgres-postgresql-0',
        '--', 'bash', '-c',
        f"PGPASSWORD=nexarank2026 psql -U nexarank -d nexarank -t -c \"SELECT id FROM users WHERE username='{username}';\""],
        capture_output=True, text=True)
    return result.stdout.strip()

def assign_group(user_id, group_id):
    sql = f"INSERT INTO user_group_memberships (id, user_id, group_id) VALUES (gen_random_uuid()::text, '{user_id}', '{group_id}') ON CONFLICT DO NOTHING;"
    with open('/tmp/assign_group.sql', 'w') as f:
        f.write(sql)
    subprocess.run(['kubectl', 'cp', '/tmp/assign_group.sql',
        'default/nexarank-postgres-postgresql-0:/tmp/assign_group.sql'])
    subprocess.run(['kubectl', 'exec', '-n', 'default', 'nexarank-postgres-postgresql-0',
        '--', 'bash', '-c',
        'PGPASSWORD=nexarank2026 psql -U nexarank -d nexarank -f /tmp/assign_group.sql'],
        capture_output=True)

for username, tenant in [('admin', 'default'), ('fleetpride_admin', 'fleetpride'), ('expedia_admin', 'expedia')]:
    user_id = get_user_id(username)
    group_id = get_super_admin_group(tenant)
    if user_id and group_id:
        assign_group(user_id, group_id)
        print(f"  {username} -> Super Admin ({tenant})")
PYEOF

# Create merch1 test user
echo "Creating merch1 test user..."
curl -s -X POST "$BASE/auth/register" \
  -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
  -d '{"username":"merch1","password":"merch123","role":"VIEWER"}' > /dev/null

echo ""
echo "=== Seed Complete ==="
echo "Tenants: default, fleetpride, expedia"
echo "Users: admin/admin123, fleetpride_admin/admin123, expedia_admin/admin123, merch1/merch123"
echo "Run nexarank-test.sh to verify"

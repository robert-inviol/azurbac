#!/usr/bin/env bash
#
# Stubbed-Graph test harness for azurbac.sh's PIM sync.
#
# No network, no tenant: `curl` and `az` are PATH-shimmed (see stubs/) and
# serve canned responses keyed by exact URL, so the paths that are hard to
# exercise live — pagination, abort-preserves-snapshot, 403 handling, stale
# cleanup, name collisions — are asserted deterministically.
#
# Usage: tests/run.sh

set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AZURBAC="$TESTS_DIR/../azurbac.sh"
STUBS="$TESTS_DIR/stubs"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

t() {
    local desc="$1"; shift
    if "$@"; then
        echo "  ok   - $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL - $desc"; FAIL=$((FAIL + 1))
    fi
}

out_has()   { grep -qF "$1" "$WORK/out.log"; }
out_lacks() { ! grep -qF "$1" "$WORK/out.log"; }

#------------------------------------------------------------------------------
# Fixture plumbing
#------------------------------------------------------------------------------

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

# make_jwt '<payload json>' — unsigned JWT; azurbac only reads the payload
make_jwt() {
    printf 'eyJhbGciOiJSUzI1NiJ9.%s.c2ln' "$(printf '%s' "$1" | b64url)"
}

# The full app-permission set, derived from the script itself so the harness
# can never drift from what `azurbac.sh permissions` actually asks for
PERMISSIONS_OUTPUT=$(bash "$AZURBAC" permissions)
FULL_TOKEN=$(make_jwt "$(printf '%s\n' "$PERMISSIONS_OUTPUT" | jq -R . | jq -sc '{roles: .}')")

scenario() {
    echo "— $1"
    WORK="$TMP_ROOT/$1"
    mkdir -p "$WORK/home"
    AZ="$WORK/azure"
    MAP="$WORK/map.tsv"
    : > "$MAP"
    BODYN=0
    TOKEN="$FULL_TOKEN"
}

# map <url> <http_status> <body_json>
map() {
    local body_file="$WORK/body.$((BODYN)).json"
    BODYN=$((BODYN + 1))
    printf '%s' "$3" > "$body_file"
    printf '%s\t%s\t%s\n' "$1" "$2" "$body_file" >> "$MAP"
}

run_pim() {
    (cd "$WORK" && env HOME="$WORK/home" AZURE_DIR="$AZ" CURL_FIXTURES="$MAP" \
        STUB_TOKEN="$TOKEN" PATH="$STUBS:$PATH" bash "$AZURBAC" pim) \
        > "$WORK/out.log" 2>&1
    RC=$?
}

seed_user() { # <name> <id>
    mkdir -p "$AZ/entra/users/Member/$1"
    echo '{"id":"'"$2"'"}' > "$AZ/entra/users/Member/$1/___$2.json"
}

no_roles_tmp() { ! compgen -G "$AZ/entra/pim/.roles-tmp.*" > /dev/null; }

# URL builders — must match azurbac.sh byte-for-byte
GROUPS_URL='https://graph.microsoft.com/v1.0/groups?$select=id,displayName,groupTypes&$top=999'
ROLE_ELIG_URL='https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances'
ROLE_ACT_URL='https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances'
ROLE_DEFS_URL='https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?$select=id,displayName'
gelig() { printf 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?$filter=groupId%%20eq%%20%%27%s%%27' "$1"; }
gact()  { printf 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?$filter=groupId%%20eq%%20%%27%s%%27' "$1"; }
dobj()  { printf 'https://graph.microsoft.com/v1.0/directoryObjects/%s' "$1"; }

map_empty_roles() {
    map "$ROLE_ELIG_URL" 200 '{"value":[]}'
    map "$ROLE_ACT_URL" 200 '{"value":[]}'
    map "$ROLE_DEFS_URL" 200 '{"value":[]}'
}

ERROR_403='{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges"}}'

#------------------------------------------------------------------------------
# 0. Lint
#------------------------------------------------------------------------------
scenario lint
t "bash -n azurbac.sh" bash -n "$AZURBAC"

#------------------------------------------------------------------------------
# 1. Happy path: pagination, sorted output, eligible/ + active/ views,
#    non-PIM group left dirless, leftover temp tree swept
#------------------------------------------------------------------------------
scenario happy
seed_user Alice u1
mkdir -p "$AZ/entra/pim/.roles-tmp.LEFTOVER"
PAGE2_URL='https://graph.microsoft.com/v1.0/groups?page=2'
map "$GROUPS_URL" 200 '{"@odata.nextLink":"'"$PAGE2_URL"'","value":[{"id":"g1","displayName":"Ops Team","groupTypes":[]}]}'
map "$PAGE2_URL" 200 '{"value":[{"id":"g2","displayName":"Platform Admins","groupTypes":[]}]}'
map "$(gelig g1)" 200 '{"value":[]}'
map "$(gact g1)" 200 '{"value":[]}'
map "$(gelig g2)" 200 '{"value":[{"id":"e1","principalId":"u1","groupId":"g2"}]}'
map "$(gact g2)" 200 '{"value":[{"id":"a1","principalId":"u1","groupId":"g2"}]}'
map "$(dobj u1)" 200 '{"id":"u1","displayName":"Alice","@odata.type":"#microsoft.graph.user"}'
map "$ROLE_ELIG_URL" 200 '{"value":[{"id":"re2","principalId":"u1","roleDefinitionId":"rd1"},{"id":"re1","principalId":"u1","roleDefinitionId":"rd1"}]}'
map "$ROLE_ACT_URL" 200 '{"value":[]}'
map "$ROLE_DEFS_URL" 200 '{"value":[{"id":"rd1","displayName":"Global Administrator"}]}'
run_pim
t "exits 0" test "$RC" -eq 0
t "pagination reached the group on page 2" test -f "$AZ/entra/pim/groups/Platform Admins/_eligibilities.json"
t "non-PIM group gets no snapshot dir" test ! -e "$AZ/entra/pim/groups/Ops Team"
t "eligible/ symlink resolves" test -e "$AZ/entra/pim/groups/Platform Admins/eligible/Alice"
t "active/ symlink resolves" test -e "$AZ/entra/pim/groups/Platform Admins/active/Alice"
t "role snapshot written under display name" test -f "$AZ/entra/pim/roles/Global Administrator/_eligibilities.json"
t "role eligible/ symlink resolves" test -e "$AZ/entra/pim/roles/Global Administrator/eligible/Alice"
t "eligibilities sorted by id" test "$(jq -r '.[0].id' "$AZ/entra/pim/roles/Global Administrator/_eligibilities.json")" = "re1"
t "leftover .roles-tmp swept" test ! -e "$AZ/entra/pim/.roles-tmp.LEFTOVER"
t "no fresh .roles-tmp residue" no_roles_tmp
t "reports success" out_has "Sync complete!"

#------------------------------------------------------------------------------
# 2. Cleanup: dynamic-group snapshot removed, deleted/renamed group pruned,
#    sanitize_name collision suffixed instead of destructive, empty-name guard
#------------------------------------------------------------------------------
scenario cleanup
seed_user Alice u1
mkdir -p "$AZ/entra/pim/groups/DynGrp" "$AZ/entra/pim/groups/GoneGroup"
echo '[]' > "$AZ/entra/pim/groups/DynGrp/_eligibilities.json"
echo '[]' > "$AZ/entra/pim/groups/GoneGroup/_eligibilities.json"
map "$GROUPS_URL" 200 '{"value":[
  {"id":"gdyn","displayName":"DynGrp","groupTypes":["DynamicMembership"]},
  {"id":"gws","displayName":"   ","groupTypes":[]},
  {"id":"gc1","displayName":"Ops","groupTypes":[]},
  {"id":"gc2","displayName":"Ops","groupTypes":[]}]}'
map "$(gelig gws)" 200 '{"value":[]}'
map "$(gact gws)" 200 '{"value":[]}'
map "$(gelig gc1)" 200 '{"value":[{"id":"e1","principalId":"u1","groupId":"gc1"}]}'
map "$(gact gc1)" 200 '{"value":[]}'
map "$(gelig gc2)" 200 '{"value":[{"id":"e2","principalId":"u1","groupId":"gc2"}]}'
map "$(gact gc2)" 200 '{"value":[]}'
map "$(dobj u1)" 200 '{"id":"u1","displayName":"Alice","@odata.type":"#microsoft.graph.user"}'
map_empty_roles
run_pim
t "exits 0" test "$RC" -eq 0
t "dynamic group snapshot removed" test ! -e "$AZ/entra/pim/groups/DynGrp"
t "deleted group snapshot pruned" test ! -e "$AZ/entra/pim/groups/GoneGroup"
t "prune is announced" out_has "Pruning stale group snapshot: GoneGroup"
t "empty display name skipped" out_has "Skipping group gws: unusable display name"
t "first colliding group keeps its dir" test -f "$AZ/entra/pim/groups/Ops/_eligibilities.json"
t "second colliding group gets suffixed dir" test -f "$AZ/entra/pim/groups/Ops___gc2/_eligibilities.json"
t "collision is announced" out_has "Name collision on 'Ops'"
t "zero PIM roles is flagged" out_has "No PIM-managed directory roles found"

#------------------------------------------------------------------------------
# 3. Abort preserves snapshots: failed fetches leave trees untouched and
#    the run exits 1 with the right permission hints
#------------------------------------------------------------------------------
scenario abort
mkdir -p "$AZ/entra/pim/groups/KeepMe" "$AZ/entra/pim/roles/KeepRole"
echo 'ORIGINAL-GROUPS' > "$AZ/entra/pim/groups/KeepMe/_eligibilities.json"
echo 'ORIGINAL-ROLES' > "$AZ/entra/pim/roles/KeepRole/_eligibilities.json"
map "$GROUPS_URL" 403 "$ERROR_403"
map "$ROLE_ELIG_URL" 403 "$ERROR_403"
run_pim
t "exits 1" test "$RC" -eq 1
t "group snapshot untouched" grep -q 'ORIGINAL-GROUPS' "$AZ/entra/pim/groups/KeepMe/_eligibilities.json"
t "role snapshot untouched" grep -q 'ORIGINAL-ROLES' "$AZ/entra/pim/roles/KeepRole/_eligibilities.json"
t "groups 403 hints Directory.Read.All" out_has "may be missing Directory.Read.All"
t "roles 403 hints RoleEligibilitySchedule.Read.Directory" out_has "may be missing RoleEligibilitySchedule.Read.Directory"
t "failure summary printed" out_has "NOT updated"
t "no .roles-tmp residue" no_roles_tmp

#------------------------------------------------------------------------------
# 4. 403 on directoryObjects aborts loudly (no silent null principal)
#------------------------------------------------------------------------------
scenario dirobj403
map "$GROUPS_URL" 200 '{"value":[{"id":"g2","displayName":"Platform Admins","groupTypes":[]}]}'
map "$(gelig g2)" 200 '{"value":[{"id":"e1","principalId":"u1","groupId":"g2"}]}'
map "$(gact g2)" 200 '{"value":[]}'
map "$(dobj u1)" 403 "$ERROR_403"
map_empty_roles
run_pim
t "exits 1" test "$RC" -eq 1
t "names the unresolvable principal" out_has "Could not resolve principal u1"
t "group sync aborts" out_has "Aborting PIM group sync (principal resolution failed)"
t "hints Directory.Read.All" out_has "may be missing Directory.Read.All"

#------------------------------------------------------------------------------
# 5. Roles rebuild is atomic: an abort mid-loop leaves the previous roles
#    tree intact and no temp residue
#------------------------------------------------------------------------------
scenario rolesatomic
mkdir -p "$AZ/entra/pim/roles/OldRole"
echo 'ORIGINAL-ROLES' > "$AZ/entra/pim/roles/OldRole/_eligibilities.json"
map "$GROUPS_URL" 200 '{"value":[]}'
map "$ROLE_ELIG_URL" 200 '{"value":[{"id":"re1","principalId":"u9","roleDefinitionId":"rd1"}]}'
map "$ROLE_ACT_URL" 200 '{"value":[]}'
map "$ROLE_DEFS_URL" 200 '{"value":[{"id":"rd1","displayName":"Global Administrator"}]}'
map "$(dobj u9)" 403 "$ERROR_403"
run_pim
t "exits 1" test "$RC" -eq 1
t "role sync aborts" out_has "Aborting PIM role sync (principal resolution failed)"
t "previous roles tree intact" grep -q 'ORIGINAL-ROLES' "$AZ/entra/pim/roles/OldRole/_eligibilities.json"
t "partial rebuild not swapped in" test ! -e "$AZ/entra/pim/roles/Global Administrator"
t "no .roles-tmp residue" no_roles_tmp

#------------------------------------------------------------------------------
# 6. Preflight is advisory: a missing recommended permission warns but the
#    sync proceeds and the Graph responses decide
#------------------------------------------------------------------------------
scenario advisory
TOKEN=$(make_jwt "$(printf '%s\n' "$PERMISSIONS_OUTPUT" \
    | grep -vF 'RoleAssignmentSchedule.Read.Directory' | jq -R . | jq -sc '{roles: .}')")
map "$GROUPS_URL" 200 '{"value":[]}'
map_empty_roles
run_pim
t "exits 0" test "$RC" -eq 0
t "warns about the missing permission" out_has "lacks recommended Graph permission(s): RoleAssignmentSchedule.Read.Directory"
t "proceeds anyway" out_has "Proceeding anyway"
t "sync completes" out_has "Sync complete!"

#------------------------------------------------------------------------------
# 7. Delegated tokens (scp claim) skip the preflight quietly
#------------------------------------------------------------------------------
scenario delegated
TOKEN=$(make_jwt '{"scp":"PrivilegedEligibilitySchedule.Read.AzureADGroup"}')
map "$GROUPS_URL" 200 '{"value":[]}'
map_empty_roles
run_pim
t "exits 0" test "$RC" -eq 0
t "no preflight warning for delegated token" out_lacks "lacks recommended"

#------------------------------------------------------------------------------
# 8. `permissions` subcommand: pipeable, no az/login needed, no side effects
#------------------------------------------------------------------------------
scenario permissions
(cd "$WORK" && env PATH=/usr/bin:/bin bash "$AZURBAC" permissions) \
    > "$WORK/perm.out" 2> "$WORK/perm.err"
RC=$?
t "exits 0 without az on PATH" test "$RC" -eq 0
t "prints exactly the 5-permission set" test "$(cat "$WORK/perm.out")" = "Directory.Read.All
PrivilegedEligibilitySchedule.Read.AzureADGroup
PrivilegedAssignmentSchedule.Read.AzureADGroup
RoleEligibilitySchedule.Read.Directory
RoleAssignmentSchedule.Read.Directory"
t "nothing on stderr" test ! -s "$WORK/perm.err"
t "no ./azure side effect" test ! -e "$WORK/azure"

#------------------------------------------------------------------------------
echo ""
echo "passed: $PASS  failed: $FAIL"
[[ "$FAIL" -eq 0 ]]

#!/bin/bash
#
# azurbac.sh - Sync Azure/Entra resources to filesystem for git tracking
#
# Directory structure:
#   azure/
#     entra/
#       users/{Guest|Member}/{displayName}/___{id}.json
#       groups/{displayName}/___{id}.json
#         members/{memberName} -> symlink to user/group ___guid.json
#       service_principals/{Application|ManagedIdentity|...}/{displayName}/___{id}.json
#     subscriptions/{name}/___{id}.json
#       resource_groups/{name}/___{name}.json
#         roles/{roleName}/{principalName} -> symlink to entra ___guid.json
#         resources/{resourceName}/___{guid}.json
#           roles/{roleName}/{principalName} -> symlink to entra ___guid.json
#       resource_types/{type}/{resourceName} -> symlink to resource ___guid.json
#       resource_regions/{location}/{resourceName} -> symlink to resource ___guid.json
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
AZURE_DIR="${AZURE_DIR:-./azure}"
SYNC_USERS="${SYNC_USERS:-true}"
SYNC_GROUPS="${SYNC_GROUPS:-true}"
SYNC_SERVICE_PRINCIPALS="${SYNC_SERVICE_PRINCIPALS:-true}"
SYNC_SUBSCRIPTIONS="${SYNC_SUBSCRIPTIONS:-true}"
SYNC_RBAC="${SYNC_RBAC:-true}"
SYNC_RESOURCES="${SYNC_RESOURCES:-true}"

#------------------------------------------------------------------------------
# Utility Functions
#------------------------------------------------------------------------------

print_error() { echo -e "${RED}Error: $1${NC}" >&2; }
print_success() { echo -e "${GREEN}$1${NC}"; }
print_info() { echo -e "${BLUE}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }

# Sanitize name for filesystem (replace problematic chars)
sanitize_name() {
    local name="$1"
    # Replace / \ : * ? " < > | with _
    echo "$name" | sed 's/[\/\\:*?"<>|]/_/g' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//'
}

# Create directory if it doesn't exist
ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# Check dependencies
check_dependencies() {
    local missing=()
    command -v az &>/dev/null || missing+=("az (Azure CLI)")
    command -v jq &>/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        exit 1
    fi

    if ! az account show &>/dev/null; then
        print_error "Not logged in to Azure CLI. Run: az login"
        exit 1
    fi
}

#------------------------------------------------------------------------------
# Entra ID Sync Functions
#------------------------------------------------------------------------------

sync_users() {
    print_info "Syncing Entra users..."

    local users_dir="$AZURE_DIR/entra/users"
    ensure_dir "$users_dir"

    # Use Graph API to get userType (az CLI doesn't return this field properly)
    local token
    token=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null)

    if [[ -z "$token" ]]; then
        print_warning "  Could not get Graph API token, falling back to az CLI"
        # Fallback to az CLI (userType will be Unknown)
        local users
        users=$(az ad user list --query '[].{id:id,displayName:displayName,userPrincipalName:userPrincipalName,mail:mail,jobTitle:jobTitle,department:department,accountEnabled:accountEnabled}' -o json 2>/dev/null)
        echo "$users" | jq -c '.[] | . + {userType: "Unknown"}' | while read -r user; do
            process_user "$user" "$users_dir"
        done
        return
    fi

    # Fetch all users via Graph API with pagination
    local url='https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName,mail,jobTitle,department,accountEnabled,userType&$top=999'
    local count=0

    while [[ -n "$url" ]]; do
        local response
        response=$(curl -s -H "Authorization: Bearer $token" "$url" 2>/dev/null)

        # Process each user in this page
        echo "$response" | jq -c '.value[]?' | while read -r user; do
            local id display_name safe_name user_type type_dir user_dir
            id=$(echo "$user" | jq -r '.id')
            display_name=$(echo "$user" | jq -r '.displayName // .userPrincipalName // .id')
            safe_name=$(sanitize_name "$display_name")
            user_type=$(echo "$user" | jq -r '.userType // "Unknown"')

            # Organize by user type (Member, Guest, Unknown)
            type_dir="$users_dir/$user_type"
            ensure_dir "$type_dir"

            user_dir="$type_dir/$safe_name"
            ensure_dir "$user_dir"

            # Write metadata file
            echo "$user" | jq '.' > "$user_dir/___${id}.json"
        done

        count=$((count + $(echo "$response" | jq '.value | length')))

        # Get next page URL
        url=$(echo "$response" | jq -r '.["@odata.nextLink"] // empty')
    done

    print_info "  Found $count users"
    print_success "  Users synced to $users_dir"
}

sync_groups() {
    print_info "Syncing Entra groups..."

    local groups_dir="$AZURE_DIR/entra/groups"
    local users_dir="$AZURE_DIR/entra/users"
    ensure_dir "$groups_dir"

    local groups
    groups=$(az ad group list --query '[].{id:id,displayName:displayName,description:description,mailEnabled:mailEnabled,securityEnabled:securityEnabled,groupTypes:groupTypes}' -o json 2>/dev/null)

    local count
    count=$(echo "$groups" | jq 'length')
    print_info "  Found $count groups"

    echo "$groups" | jq -c '.[]' | while read -r group; do
        local id display_name safe_name group_dir
        id=$(echo "$group" | jq -r '.id')
        display_name=$(echo "$group" | jq -r '.displayName // .id')
        safe_name=$(sanitize_name "$display_name")

        group_dir="$groups_dir/$safe_name"
        ensure_dir "$group_dir"

        # Write metadata file
        echo "$group" | jq '.' > "$group_dir/___${id}.json"

        # Get group members and create symlinks
        local members_dir="$group_dir/members"
        rm -rf "$members_dir" 2>/dev/null  # Clean up old members
        ensure_dir "$members_dir"

        local members
        members=$(az ad group member list --group "$id" --query '[].{id:id,displayName:displayName,userType:userType,odataType:"@odata.type"}' -o json 2>/dev/null || echo '[]')

        echo "$members" | jq -c '.[]' 2>/dev/null | while read -r member; do
            local member_id member_name member_type safe_member_name user_type
            member_id=$(echo "$member" | jq -r '.id')
            member_name=$(echo "$member" | jq -r '.displayName // .id')
            member_type=$(echo "$member" | jq -r '.odataType // "unknown"')
            user_type=$(echo "$member" | jq -r '.userType // "Member"')
            safe_member_name=$(sanitize_name "$member_name")

            # Find the ___guid.json file and create symlink to it
            local found_file=""
            local relative_path=""

            # From: groups/{groupName}/members/
            # To:   users/{type}/{name}/___guid.json  (3 levels up: members -> groupName -> groups -> entra)
            # To:   groups/{name}/___guid.json        (2 levels up: members -> groupName -> groups)
            # To:   service_principals/{type}/{name}/ (3 levels up)
            case "$member_type" in
                "#microsoft.graph.user")
                    found_file=$(find "$AZURE_DIR/entra/users" -name "___${member_id}.json" 2>/dev/null | head -1)
                    if [[ -n "$found_file" ]]; then
                        local user_type_dir=$(basename "$(dirname "$(dirname "$found_file")")")
                        relative_path="../../../users/$user_type_dir/$safe_member_name/___${member_id}.json"
                    fi
                    ;;
                "#microsoft.graph.group")
                    found_file=$(find "$AZURE_DIR/entra/groups" -name "___${member_id}.json" 2>/dev/null | head -1)
                    if [[ -n "$found_file" ]]; then
                        local grp_name=$(basename "$(dirname "$found_file")")
                        relative_path="../../$grp_name/___${member_id}.json"
                    fi
                    ;;
                "#microsoft.graph.servicePrincipal")
                    found_file=$(find "$AZURE_DIR/entra/service_principals" -name "___${member_id}.json" 2>/dev/null | head -1)
                    if [[ -n "$found_file" ]]; then
                        local sp_type=$(basename "$(dirname "$(dirname "$found_file")")")
                        local sp_name=$(basename "$(dirname "$found_file")")
                        relative_path="../../../service_principals/$sp_type/$sp_name/___${member_id}.json"
                    fi
                    ;;
                *)
                    continue
                    ;;
            esac

            # Create symlink named by display name, pointing to ___guid.json
            if [[ -n "$found_file" ]] && [[ -f "$found_file" ]]; then
                ln -sf "$relative_path" "$members_dir/$safe_member_name" 2>/dev/null || true
            fi
        done
    done

    print_success "  Groups synced to $groups_dir"
}

sync_service_principals() {
    print_info "Syncing Entra service principals..."

    local sp_dir="$AZURE_DIR/entra/service_principals"
    ensure_dir "$sp_dir"

    # Get ALL service principals with their types
    # Types: Application, ManagedIdentity, Legacy, SocialIdp
    local sps
    sps=$(az ad sp list --all --query "[].{id:id,appId:appId,displayName:displayName,servicePrincipalType:servicePrincipalType,accountEnabled:accountEnabled,appOwnerOrganizationId:appOwnerOrganizationId}" -o json 2>/dev/null)

    local count
    count=$(echo "$sps" | jq 'length')
    print_info "  Found $count service principals"

    echo "$sps" | jq -c '.[]' | while read -r sp; do
        local id display_name safe_name sp_type type_dir sp_subdir
        id=$(echo "$sp" | jq -r '.id')
        display_name=$(echo "$sp" | jq -r '.displayName // .appId // .id')
        safe_name=$(sanitize_name "$display_name")
        sp_type=$(echo "$sp" | jq -r '.servicePrincipalType // "Unknown"')

        # Organize by service principal type
        type_dir="$sp_dir/$sp_type"
        ensure_dir "$type_dir"

        sp_subdir="$type_dir/$safe_name"
        ensure_dir "$sp_subdir"

        # Write metadata file
        echo "$sp" | jq '.' > "$sp_subdir/___${id}.json"
    done

    print_success "  Service principals synced to $sp_dir"
}

#------------------------------------------------------------------------------
# Subscription & Resource Group Sync
#------------------------------------------------------------------------------

sync_subscriptions() {
    print_info "Syncing Azure subscriptions..."

    local subs_dir="$AZURE_DIR/subscriptions"
    ensure_dir "$subs_dir"

    local subs
    subs=$(az account list --query '[].{id:id,name:name,state:state,tenantId:tenantId,isDefault:isDefault}' -o json 2>/dev/null)

    local count
    count=$(echo "$subs" | jq 'length')
    print_info "  Found $count subscriptions"

    echo "$subs" | jq -c '.[]' | while read -r sub; do
        local id name safe_name sub_dir
        id=$(echo "$sub" | jq -r '.id')
        name=$(echo "$sub" | jq -r '.name')
        safe_name=$(sanitize_name "$name")

        sub_dir="$subs_dir/$safe_name"
        ensure_dir "$sub_dir"

        # Write metadata file
        echo "$sub" | jq '.' > "$sub_dir/___${id}.json"

        # Sync resource groups for this subscription
        sync_resource_groups "$id" "$sub_dir"
    done

    print_success "  Subscriptions synced to $subs_dir"
}

sync_resource_groups() {
    local sub_id="$1"
    local sub_dir="$2"

    local rgs_dir="$sub_dir/resource_groups"
    ensure_dir "$rgs_dir"

    local rgs
    rgs=$(az group list --subscription "$sub_id" --query '[].{id:id,name:name,location:location,tags:tags}' -o json 2>/dev/null || echo '[]')

    echo "$rgs" | jq -c '.[]' | while read -r rg; do
        local rg_id name safe_name rg_dir
        rg_id=$(echo "$rg" | jq -r '.id')
        name=$(echo "$rg" | jq -r '.name')
        safe_name=$(sanitize_name "$name")

        rg_dir="$rgs_dir/$safe_name"
        ensure_dir "$rg_dir"

        # Extract just the GUID part from the full resource ID for the filename
        local rg_guid
        rg_guid=$(echo "$rg_id" | sed 's|.*/||')

        # Write metadata file (use name as identifier since RGs don't have separate GUIDs)
        echo "$rg" | jq '.' > "$rg_dir/___${safe_name}.json"

        # Sync RBAC for this resource group
        # Path from: subscriptions/{sub}/resource_groups/{rg}/roles/{role}/ -> azure/
        # That's 6 levels up: role -> roles -> rg -> resource_groups -> sub -> subscriptions -> azure
        if [[ "$SYNC_RBAC" == "true" ]]; then
            sync_rbac_for_scope "$rg_id" "$rg_dir" "$sub_id" "../../../../../../"
        fi
    done

    # After syncing all RGs, sync resources
    if [[ "$SYNC_RESOURCES" == "true" ]]; then
        sync_resources "$sub_id" "$sub_dir"
    fi
}

#------------------------------------------------------------------------------
# Resource Sync
#------------------------------------------------------------------------------

sync_resources() {
    local sub_id="$1"
    local sub_dir="$2"

    local rgs_dir="$sub_dir/resource_groups"
    local types_dir="$sub_dir/resource_types"
    local regions_dir="$sub_dir/resource_regions"

    # Clean and create type/region directories
    [[ -d "$types_dir" ]] && rm -rf "$types_dir"
    [[ -d "$regions_dir" ]] && rm -rf "$regions_dir"

    # Get all resources in this subscription
    local resources
    resources=$(az resource list --subscription "$sub_id" \
        --query '[].{id:id,name:name,type:type,location:location,resourceGroup:resourceGroup,kind:kind,sku:sku,tags:tags}' \
        -o json 2>/dev/null || echo '[]')

    local count
    count=$(echo "$resources" | jq 'length')
    [[ "$count" -eq 0 ]] && return

    print_info "    Syncing $count resources..."

    echo "$resources" | jq -c '.[]' | while read -r resource; do
        local res_id res_name res_type location rg_name
        res_id=$(echo "$resource" | jq -r '.id')
        res_name=$(echo "$resource" | jq -r '.name')
        res_type=$(echo "$resource" | jq -r '.type')
        location=$(echo "$resource" | jq -r '.location')
        rg_name=$(echo "$resource" | jq -r '.resourceGroup')

        local safe_res_name safe_rg_name safe_type safe_location
        safe_res_name=$(sanitize_name "$res_name")
        safe_rg_name=$(sanitize_name "$rg_name")
        safe_type=$(sanitize_name "$res_type")
        safe_location=$(sanitize_name "$location")

        # Extract resource GUID from the ID (last segment after last /)
        local res_guid
        res_guid=$(echo "$res_id" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1)
        [[ -z "$res_guid" ]] && res_guid=$(echo "$res_id" | md5sum | cut -c1-32)

        # Create resource directory under resource_groups/{rg}/resources/
        local rg_dir="$rgs_dir/$safe_rg_name"
        [[ ! -d "$rg_dir" ]] && continue  # Skip if RG doesn't exist

        local resources_dir="$rg_dir/resources"
        ensure_dir "$resources_dir"

        local res_dir="$resources_dir/$safe_res_name"
        ensure_dir "$res_dir"

        # Write resource metadata
        echo "$resource" | jq '.' > "$res_dir/___${res_guid}.json"

        # Sync RBAC for this resource
        # Path from: subscriptions/{sub}/resource_groups/{rg}/resources/{res}/roles/{role}/ -> azure/
        # That's 8 levels up
        if [[ "$SYNC_RBAC" == "true" ]]; then
            sync_rbac_for_scope "$res_id" "$res_dir" "$sub_id" "../../../../../../../../"
        fi

        # Create symlink in resource_types/{type}/
        ensure_dir "$types_dir/$safe_type"
        # Path from: resource_types/{type}/ to resource_groups/{rg}/resources/{name}/___guid.json
        # That's: up 2 (type -> resource_types -> sub_dir), then into resource_groups/...
        ln -sf "../../resource_groups/$safe_rg_name/resources/$safe_res_name/___${res_guid}.json" \
            "$types_dir/$safe_type/$safe_res_name" 2>/dev/null || true

        # Create symlink in resource_regions/{location}/
        ensure_dir "$regions_dir/$safe_location"
        ln -sf "../../resource_groups/$safe_rg_name/resources/$safe_res_name/___${res_guid}.json" \
            "$regions_dir/$safe_location/$safe_res_name" 2>/dev/null || true
    done
}

#------------------------------------------------------------------------------
# RBAC Sync with Symlinks
#------------------------------------------------------------------------------

sync_rbac_for_scope() {
    local scope="$1"
    local target_dir="$2"
    local sub_id="$3"
    local path_prefix="$4"  # e.g., "../../../../" for sub-level, "../../../../../../" for RG-level

    local roles_dir="$target_dir/roles"

    # Clean existing roles directory
    [[ -d "$roles_dir" ]] && rm -rf "$roles_dir"

    local assignments
    assignments=$(az role assignment list --scope "$scope" --subscription "$sub_id" \
        --query '[].{principalId:principalId,principalName:principalName,principalType:principalType,roleDefinitionName:roleDefinitionName,scope:scope}' \
        -o json 2>/dev/null || echo '[]')

    # Only create roles directory if there are assignments
    local count
    count=$(echo "$assignments" | jq 'length')
    [[ "$count" -eq 0 ]] && return

    ensure_dir "$roles_dir"

    echo "$assignments" | jq -c '.[]' | while read -r assignment; do
        local role_name principal_id principal_type safe_role
        role_name=$(echo "$assignment" | jq -r '.roleDefinitionName')
        principal_id=$(echo "$assignment" | jq -r '.principalId')
        principal_type=$(echo "$assignment" | jq -r '.principalType')

        safe_role=$(sanitize_name "$role_name")

        local role_dir="$roles_dir/$safe_role"
        ensure_dir "$role_dir"

        # Find the ___guid.json file and extract displayName from the folder structure
        local found_file=""
        local relative_path=""
        local display_name=""

        case "$principal_type" in
            "User")
                found_file=$(find "$AZURE_DIR/entra/users" -name "___${principal_id}.json" 2>/dev/null | head -1)
                if [[ -n "$found_file" ]]; then
                    local user_type=$(basename "$(dirname "$(dirname "$found_file")")")
                    local user_folder=$(basename "$(dirname "$found_file")")
                    display_name="$user_folder"
                    relative_path="${path_prefix}entra/users/$user_type/$user_folder/___${principal_id}.json"
                fi
                ;;
            "Group")
                found_file=$(find "$AZURE_DIR/entra/groups" -name "___${principal_id}.json" 2>/dev/null | head -1)
                if [[ -n "$found_file" ]]; then
                    local grp_name=$(basename "$(dirname "$found_file")")
                    display_name="$grp_name"
                    relative_path="${path_prefix}entra/groups/$grp_name/___${principal_id}.json"
                fi
                ;;
            "ServicePrincipal")
                found_file=$(find "$AZURE_DIR/entra/service_principals" -name "___${principal_id}.json" 2>/dev/null | head -1)
                if [[ -n "$found_file" ]]; then
                    local sp_type=$(basename "$(dirname "$(dirname "$found_file")")")
                    local sp_name=$(basename "$(dirname "$found_file")")
                    display_name="$sp_name"
                    relative_path="${path_prefix}entra/service_principals/$sp_type/$sp_name/___${principal_id}.json"
                fi
                ;;
        esac

        # Create symlink named by displayName (from folder), pointing to ___guid.json
        if [[ -n "$found_file" ]] && [[ -f "$found_file" ]] && [[ -n "$display_name" ]]; then
            ln -sf "$relative_path" "$role_dir/$display_name" 2>/dev/null || true
        else
            # Create a placeholder file for orphaned/unknown principals
            local principal_name
            principal_name=$(echo "$assignment" | jq -r '.principalName // .principalId')
            echo "{\"principalId\": \"$principal_id\", \"principalName\": \"$principal_name\", \"principalType\": \"$principal_type\", \"status\": \"orphaned_or_external\"}" > "$role_dir/___orphaned_${principal_id}.json"
        fi
    done
}

#------------------------------------------------------------------------------
# Subscription-level RBAC
#------------------------------------------------------------------------------

sync_subscription_rbac() {
    print_info "Syncing subscription-level RBAC..."

    local subs
    subs=$(az account list --query '[].{id:id,name:name}' -o json 2>/dev/null)

    echo "$subs" | jq -c '.[]' | while read -r sub; do
        local sub_id name safe_name sub_dir
        sub_id=$(echo "$sub" | jq -r '.id')
        name=$(echo "$sub" | jq -r '.name')
        safe_name=$(sanitize_name "$name")

        sub_dir="$AZURE_DIR/subscriptions/$safe_name"

        if [[ -d "$sub_dir" ]]; then
            local scope="/subscriptions/$sub_id"
            # Path from: subscriptions/{sub}/roles/{role}/ -> azure/
            # That's 4 levels up: role -> roles -> sub -> subscriptions -> azure
            sync_rbac_for_scope "$scope" "$sub_dir" "$sub_id" "../../../../"
        fi
    done

    print_success "  Subscription RBAC synced"
}

#------------------------------------------------------------------------------
# PIM Sync
#------------------------------------------------------------------------------

sync_pim_groups() {
    print_info "Syncing PIM group eligibilities..."

    local pim_dir="$AZURE_DIR/entra/pim"
    ensure_dir "$pim_dir"

    local groups_dir="$pim_dir/groups"
    ensure_dir "$groups_dir"

    # Try to get token from entra-audit first (has PIM permissions)
    local token=""
    local entra_audit_config="$HOME/.config/entra-audit/token.json"

    if [[ -f "$entra_audit_config" ]]; then
        local expires_on stored_token
        expires_on=$(jq -r '.expires_on // 0' "$entra_audit_config" 2>/dev/null)
        stored_token=$(jq -r '.access_token // ""' "$entra_audit_config" 2>/dev/null)

        if [[ -n "$stored_token" ]] && [[ "$expires_on" -gt "$(date +%s)" ]]; then
            token="$stored_token"
            print_info "  Using entra-audit token (has PIM permissions)"
        fi
    fi

    # Fall back to az CLI token (may not have PIM permissions)
    if [[ -z "$token" ]]; then
        token=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null)
        if [[ -n "$token" ]]; then
            print_warning "  Using az CLI token (may lack PIM permissions - run './entraling.sh login' for full PIM sync)"
        fi
    fi

    if [[ -z "$token" ]]; then
        print_warning "  Could not get Graph API token, skipping PIM sync"
        return
    fi

    # Get current user's eligible groups to discover PIM-enabled groups
    local user_id
    user_id=$(curl -s -H "Authorization: Bearer $token" "https://graph.microsoft.com/v1.0/me" | jq -r '.id')

    local user_eligible
    user_eligible=$(curl -s -H "Authorization: Bearer $token" \
        "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=principalId%20eq%20%27${user_id}%27" 2>/dev/null)

    local group_ids
    group_ids=$(echo "$user_eligible" | jq -r '[.value[]?.groupId] | unique | .[]' 2>/dev/null)

    if [[ -z "$group_ids" ]]; then
        print_warning "  No PIM-enabled groups found"
        return
    fi

    # For each PIM group, get all eligibilities
    while read -r group_id; do
        [[ -z "$group_id" ]] && continue

        # Get group name
        local group_info
        group_info=$(curl -s -H "Authorization: Bearer $token" \
            "https://graph.microsoft.com/v1.0/groups/${group_id}?\$select=id,displayName" 2>/dev/null)

        local group_name safe_group_name group_pim_dir
        group_name=$(echo "$group_info" | jq -r '.displayName // .id')
        safe_group_name=$(sanitize_name "$group_name")
        group_pim_dir="$groups_dir/$safe_group_name"
        ensure_dir "$group_pim_dir"

        # Get all eligibilities for this group
        local eligibilities
        eligibilities=$(curl -s -H "Authorization: Bearer $token" \
            "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" 2>/dev/null)

        echo "$eligibilities" | jq '.value' > "$group_pim_dir/_eligibilities.json"

        # Get active assignments
        local active
        active=$(curl -s -H "Authorization: Bearer $token" \
            "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" 2>/dev/null)

        echo "$active" | jq '.value' > "$group_pim_dir/_active.json"

        # Create symlinks to eligible users/groups
        local eligible_dir="$group_pim_dir/eligible"
        ensure_dir "$eligible_dir"

        echo "$eligibilities" | jq -c '.value[]?' | while read -r elig; do
            local principal_id member_type
            principal_id=$(echo "$elig" | jq -r '.principalId')
            member_type=$(echo "$elig" | jq -r '.memberType')

            # Try to resolve principal name
            local principal_info principal_name safe_principal_name
            principal_info=$(curl -s -H "Authorization: Bearer $token" \
                "https://graph.microsoft.com/v1.0/directoryObjects/${principal_id}" 2>/dev/null)
            principal_name=$(echo "$principal_info" | jq -r '.displayName // .userPrincipalName // .id')
            safe_principal_name=$(sanitize_name "$principal_name")

            local principal_type
            principal_type=$(echo "$principal_info" | jq -r '.["@odata.type"] // "unknown"' | sed 's/#microsoft.graph.//')

            # Find the ___guid.json file and create symlink to it
            local found_file=""
            local relative_path=""

            case "$principal_type" in
                "user")
                    found_file=$(find "$AZURE_DIR/entra/users" -name "___${principal_id}.json" 2>/dev/null | head -1)
                    if [[ -n "$found_file" ]]; then
                        local user_type=$(basename "$(dirname "$(dirname "$found_file")")")
                        relative_path="../../../../users/$user_type/$safe_principal_name/___${principal_id}.json"
                    fi
                    ;;
                "group")
                    found_file=$(find "$AZURE_DIR/entra/groups" -name "___${principal_id}.json" 2>/dev/null | head -1)
                    if [[ -n "$found_file" ]]; then
                        local grp_name=$(basename "$(dirname "$found_file")")
                        relative_path="../../../../groups/$grp_name/___${principal_id}.json"
                    fi
                    ;;
                "servicePrincipal")
                    found_file=$(find "$AZURE_DIR/entra/service_principals" -name "___${principal_id}.json" 2>/dev/null | head -1)
                    if [[ -n "$found_file" ]]; then
                        local sp_type=$(basename "$(dirname "$(dirname "$found_file")")")
                        local sp_name=$(basename "$(dirname "$found_file")")
                        relative_path="../../../../service_principals/$sp_type/$sp_name/___${principal_id}.json"
                    fi
                    ;;
            esac

            # Create symlink named by display name, pointing to ___guid.json
            if [[ -n "$found_file" ]] && [[ -f "$found_file" ]]; then
                ln -sf "$relative_path" "$eligible_dir/$safe_principal_name" 2>/dev/null || true
            fi
        done

    done <<< "$group_ids"

    print_success "  PIM groups synced to $groups_dir"
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

show_help() {
    cat << EOF
azurbac.sh - Sync Azure/Entra resources to filesystem

USAGE:
    azurbac.sh [command] [options]

COMMANDS:
    sync        Full sync of all resources (default)
    users       Sync only Entra users
    groups      Sync only Entra groups
    sps         Sync only service principals
    subs        Sync subscriptions, resource groups, and resources
    resources   Sync only Azure resources (requires subs synced first)
    rbac        Sync RBAC assignments
    pim         Sync PIM eligibilities
    help        Show this help

OPTIONS:
    --dir PATH  Set base directory (default: ./azure)

ENVIRONMENT VARIABLES:
    AZURE_DIR                Base directory (default: ./azure)
    SYNC_USERS              Sync users (default: true)
    SYNC_GROUPS             Sync groups (default: true)
    SYNC_SERVICE_PRINCIPALS Sync SPs (default: true)
    SYNC_SUBSCRIPTIONS      Sync subs/RGs (default: true)
    SYNC_RBAC               Sync RBAC (default: true)
    SYNC_RESOURCES          Sync Azure resources (default: true)

EXAMPLES:
    azurbac.sh                    # Full sync
    azurbac.sh sync --dir ./my-azure
    azurbac.sh users              # Only users
    azurbac.sh rbac               # Only RBAC
EOF
}

main() {
    local command="${1:-sync}"

    # Parse --dir option
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir)
                AZURE_DIR="$2"
                shift 2
                ;;
            *)
                command="$1"
                shift
                ;;
        esac
    done

    check_dependencies

    print_info "Azure Sync - Base directory: $AZURE_DIR"
    echo ""

    ensure_dir "$AZURE_DIR"

    case "$command" in
        sync)
            [[ "$SYNC_USERS" == "true" ]] && sync_users
            [[ "$SYNC_GROUPS" == "true" ]] && sync_groups
            [[ "$SYNC_SERVICE_PRINCIPALS" == "true" ]] && sync_service_principals
            [[ "$SYNC_SUBSCRIPTIONS" == "true" ]] && sync_subscriptions
            [[ "$SYNC_RBAC" == "true" ]] && sync_subscription_rbac
            sync_pim_groups
            ;;
        users)
            sync_users
            ;;
        groups)
            sync_groups
            ;;
        sps)
            sync_service_principals
            ;;
        subs)
            sync_subscriptions
            ;;
        resources)
            # Sync resources for all subscriptions (requires subs to be synced first)
            local subs
            subs=$(az account list --query '[].{id:id,name:name}' -o json 2>/dev/null)
            echo "$subs" | jq -c '.[]' | while read -r sub; do
                local sub_id name safe_name sub_dir
                sub_id=$(echo "$sub" | jq -r '.id')
                name=$(echo "$sub" | jq -r '.name')
                safe_name=$(sanitize_name "$name")
                sub_dir="$AZURE_DIR/subscriptions/$safe_name"
                [[ -d "$sub_dir" ]] && sync_resources "$sub_id" "$sub_dir"
            done
            ;;
        rbac)
            sync_subscription_rbac
            ;;
        pim)
            sync_pim_groups
            ;;
        help|--help|-h)
            show_help
            exit 0
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac

    echo ""
    print_success "Sync complete!"
    print_info "You can now commit changes: cd $AZURE_DIR && git add -A && git commit -m 'Azure sync $(date +%Y-%m-%d)'"
}

main "$@"

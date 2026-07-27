#!/bin/bash
#
# azurbac.sh - Sync Azure/Entra resources to filesystem for git tracking
#
# Directory structure:
#   azure/
#     entra/
#       users/{Guest|Member}/{displayName}/___{id}.json
#         groups/{groupName} -> symlink to group ___guid.json
#         roles/{roleName}/{scopeName} -> symlink to subscription/RG/resource ___*.json
#       groups/{displayName}/___{id}.json
#         members/{memberName} -> symlink to user/group ___guid.json
#         roles/{roleName}/{scopeName} -> symlink to subscription/RG/resource ___*.json
#       service_principals/{Application|ManagedIdentity|...}/{displayName}/___{id}.json
#         roles/{roleName}/{scopeName} -> symlink to subscription/RG/resource ___*.json
#       pim/
#         groups/{groupName}/_eligibilities.json + _active.json
#           eligible/{principalName} -> symlink to entra ___guid.json
#         roles/{roleName}/_eligibilities.json + _active.json
#           eligible/{principalName} -> symlink to entra ___guid.json
#     subscriptions/{name}/___{id}.json
#       resource_groups/{name}/___{name}.json
#         roles/{roleName}/{principalName} -> symlink to entra ___guid.json
#         resources/{resourceName}/___{guid}.json
#           roles/{roleName}/{principalName} -> symlink to entra ___guid.json
#       resource_types/{type}/{resourceName} -> symlink to resource directory
#       resource_regions/{location}/{resourceName} -> symlink to resource directory
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

# principalId -> "type|safeName", shared across PIM link passes
declare -A PRINCIPAL_CACHE

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

    # After syncing groups, create reverse symlinks (groups under users)
    sync_user_group_memberships
}

sync_user_group_memberships() {
    print_info "  Creating group memberships under users..."

    local users_dir="$AZURE_DIR/entra/users"
    local groups_dir="$AZURE_DIR/entra/groups"

    # Skip if users haven't been synced yet
    [[ ! -d "$users_dir" ]] && return

    # Clean up existing groups directories under all users
    find "$users_dir" -type d -name "groups" -exec rm -rf {} \; 2>/dev/null || true

    # Iterate through each group's members directory
    for group_dir in "$groups_dir"/*/; do
        [[ ! -d "$group_dir" ]] && continue

        local group_name=$(basename "$group_dir")
        local members_dir="$group_dir/members"
        local group_json=$(find "$group_dir" -maxdepth 1 -name "___*.json" 2>/dev/null | head -1)

        [[ ! -d "$members_dir" ]] && continue
        [[ -z "$group_json" ]] && continue

        local group_id=$(basename "$group_json" | sed 's/___//; s/.json//')

        # For each member symlink in the group
        for member_link in "$members_dir"/*; do
            [[ ! -L "$member_link" ]] && continue

            local target=$(readlink "$member_link")

            # Check if it points to a user (contains /users/)
            if [[ "$target" == *"/users/"* ]]; then
                local member_name=$(basename "$member_link")

                # Extract user type from the symlink target path
                # Target looks like: ../../../users/{type}/{name}/___guid.json
                local user_type=$(echo "$target" | sed -n 's|.*/users/\([^/]*\)/.*|\1|p')

                local user_dir="$users_dir/$user_type/$member_name"
                if [[ -d "$user_dir" ]]; then
                    local user_groups_dir="$user_dir/groups"
                    ensure_dir "$user_groups_dir"

                    # Create symlink from user's groups/ to group's ___guid.json
                    # Path from: users/{type}/{name}/groups/ to groups/{groupName}/___guid.json
                    # That's 4 levels up: groups -> name -> type -> users -> entra, then into groups/
                    ln -sf "../../../../groups/$group_name/___${group_id}.json" \
                        "$user_groups_dir/$group_name" 2>/dev/null || true
                fi
            fi
        done
    done

    print_success "  User group memberships created"
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
        # Path from: resource_types/{type}/ to resource_groups/{rg}/resources/{name}/
        # That's: up 2 (type -> resource_types -> sub_dir), then into resource_groups/...
        # Symlink to directory (not json) so roles are visible when browsing via symlink
        ln -sf "../../resource_groups/$safe_rg_name/resources/$safe_res_name" \
            "$types_dir/$safe_type/$safe_res_name" 2>/dev/null || true

        # Create symlink in resource_regions/{location}/
        ensure_dir "$regions_dir/$safe_location"
        # Symlink to directory (not json) so roles are visible when browsing via symlink
        ln -sf "../../resource_groups/$safe_rg_name/resources/$safe_res_name" \
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
# Principal Roles Sync (reverse symlinks from principals to their role assignments)
#------------------------------------------------------------------------------

sync_principal_roles() {
    print_info "Syncing principal role assignments..."

    local subs_dir="$AZURE_DIR/subscriptions"
    local entra_dir="$AZURE_DIR/entra"

    [[ ! -d "$subs_dir" ]] && return
    [[ ! -d "$entra_dir" ]] && return

    # Clean up existing roles directories under all principals
    print_info "  Cleaning existing principal roles..."
    find "$entra_dir/users" -type d -name "roles" -exec rm -rf {} \; 2>/dev/null || true
    find "$entra_dir/groups" -type d -name "roles" -exec rm -rf {} \; 2>/dev/null || true
    find "$entra_dir/service_principals" -type d -name "roles" -exec rm -rf {} \; 2>/dev/null || true

    # Iterate through all subscriptions
    for sub_dir in "$subs_dir"/*/; do
        [[ ! -d "$sub_dir" ]] && continue

        local sub_name=$(basename "$sub_dir")

        # Process subscription-level roles
        process_roles_at_scope "$sub_dir" "subscriptions" "$sub_name" "" ""

        # Process resource group roles
        local rgs_dir="$sub_dir/resource_groups"
        if [[ -d "$rgs_dir" ]]; then
            for rg_dir in "$rgs_dir"/*/; do
                [[ ! -d "$rg_dir" ]] && continue

                local rg_name=$(basename "$rg_dir")

                # Process RG-level roles
                process_roles_at_scope "$rg_dir" "resource_groups" "$sub_name" "$rg_name" ""

                # Process resource-level roles
                local resources_dir="$rg_dir/resources"
                if [[ -d "$resources_dir" ]]; then
                    for res_dir in "$resources_dir"/*/; do
                        [[ ! -d "$res_dir" ]] && continue

                        local res_name=$(basename "$res_dir")

                        # Process resource-level roles
                        process_roles_at_scope "$res_dir" "resources" "$sub_name" "$rg_name" "$res_name"
                    done
                fi
            done
        fi
    done

    print_success "  Principal role assignments synced"
}

# Helper function to process roles at a specific scope and create reverse symlinks
# Args: scope_dir, scope_type (subscriptions|resource_groups|resources), sub_name, rg_name, res_name
process_roles_at_scope() {
    local scope_dir="$1"
    local scope_type="$2"
    local sub_name="$3"
    local rg_name="$4"
    local res_name="$5"

    local roles_dir="$scope_dir/roles"
    [[ ! -d "$roles_dir" ]] && return

    # Find the JSON file for this scope to link to
    local scope_json=$(find "$scope_dir" -maxdepth 1 -name "___*.json" 2>/dev/null | head -1)
    [[ -z "$scope_json" ]] && return
    local scope_json_name=$(basename "$scope_json")

    # Determine the scope name for the symlink
    local scope_name=""
    case "$scope_type" in
        subscriptions) scope_name="$sub_name" ;;
        resource_groups) scope_name="$rg_name" ;;
        resources) scope_name="$res_name" ;;
    esac

    # Iterate through each role directory
    for role_dir in "$roles_dir"/*/; do
        [[ ! -d "$role_dir" ]] && continue

        local role_name=$(basename "$role_dir")
        local safe_role=$(sanitize_name "$role_name")

        # Iterate through each principal symlink in the role
        for principal_link in "$role_dir"/*; do
            # Skip if not a symlink (could be orphaned JSON files)
            [[ ! -L "$principal_link" ]] && continue

            local principal_name=$(basename "$principal_link")
            local target=$(readlink "$principal_link")

            # Determine the principal type and directory from the symlink target
            local principal_dir=""
            local levels_up=""

            if [[ "$target" == *"/users/"* ]]; then
                local user_type=$(echo "$target" | sed -n 's|.*/users/\([^/]*\)/.*|\1|p')
                principal_dir="$AZURE_DIR/entra/users/$user_type/$principal_name"
                # From: entra/users/{type}/{name}/roles/{role}/ need to go up to azure/
                # That's: {role} -> roles -> {name} -> {type} -> users -> entra -> azure = 6 levels
                levels_up="../../../../../.."

            elif [[ "$target" == *"/groups/"* ]]; then
                principal_dir="$AZURE_DIR/entra/groups/$principal_name"
                # From: entra/groups/{name}/roles/{role}/ to azure/
                # That's: {role} -> roles -> {name} -> groups -> entra -> azure = 5 levels
                levels_up="../../../../.."

            elif [[ "$target" == *"/service_principals/"* ]]; then
                local sp_type=$(echo "$target" | sed -n 's|.*/service_principals/\([^/]*\)/.*|\1|p')
                principal_dir="$AZURE_DIR/entra/service_principals/$sp_type/$principal_name"
                # From: entra/service_principals/{type}/{name}/roles/{role}/ to azure/
                # That's: {role} -> roles -> {name} -> {type} -> service_principals -> entra -> azure = 6 levels
                levels_up="../../../../../.."
            fi

            [[ -z "$principal_dir" ]] && continue
            [[ ! -d "$principal_dir" ]] && continue

            # Create roles/{roleName}/ under the principal
            local principal_role_dir="$principal_dir/roles/$safe_role"
            ensure_dir "$principal_role_dir"

            # Create symlink: {scopeName} -> path to scope's ___*.json
            local target_path=""
            case "$scope_type" in
                subscriptions)
                    target_path="$levels_up/subscriptions/$sub_name/$scope_json_name"
                    ;;
                resource_groups)
                    target_path="$levels_up/subscriptions/$sub_name/resource_groups/$rg_name/$scope_json_name"
                    ;;
                resources)
                    target_path="$levels_up/subscriptions/$sub_name/resource_groups/$rg_name/resources/$res_name/$scope_json_name"
                    ;;
            esac

            ln -sf "$target_path" "$principal_role_dir/$scope_name" 2>/dev/null || true
        done
    done
}

#------------------------------------------------------------------------------
# PIM Sync
#------------------------------------------------------------------------------

# Get a Graph token for PIM reads. Prefers the entra-audit delegated token
# (local runs), falls back to the az CLI token — which is app-only in CI, so
# PIM sync there needs the Graph app roles granted to the workflow's SP:
#   PrivilegedEligibilitySchedule.Read.AzureADGroup (PIM for groups)
#   RoleManagement.Read.Directory (PIM for directory roles)
get_pim_graph_token() {
    local token=""
    local entra_audit_config="$HOME/.config/entra-audit/token.json"

    if [[ -f "$entra_audit_config" ]]; then
        local expires_on stored_token
        expires_on=$(jq -r '.expires_on // 0' "$entra_audit_config" 2>/dev/null)
        stored_token=$(jq -r '.access_token // ""' "$entra_audit_config" 2>/dev/null)

        if [[ -n "$stored_token" ]] && [[ "$expires_on" -gt "$(date +%s)" ]]; then
            token="$stored_token"
            print_info "  Using entra-audit token (has PIM permissions)" >&2
        fi
    fi

    if [[ -z "$token" ]]; then
        token=$(az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv 2>/dev/null)
        if [[ -n "$token" ]]; then
            print_warning "  Using az CLI token (PIM reads need the identity to hold PIM permissions)" >&2
        fi
    fi

    echo "$token"
}

# GET a Graph collection, following @odata.nextLink pagination.
# Prints a JSON array of all .value items; returns 1 on any error response
# so callers can bail out before touching previously-synced files.
# curl --retry absorbs transient 429/503 throttling (honouring Retry-After);
# $3, if set, names a permission to hint at — printed only on an actual 403
# so throttling is never misreported as a consent problem.
graph_get_all() {
    local token="$1"
    local url="$2"
    local permission_hint="${3:-}"
    local pages
    pages=$(mktemp)

    while [[ -n "$url" ]]; do
        local response http_code body
        response=$(curl -s --retry 4 --retry-max-time 300 -w $'\n%{http_code}' \
            -H "Authorization: Bearer $token" "$url" 2>/dev/null) || true
        http_code="${response##*$'\n'}"
        body="${response%$'\n'*}"

        if [[ "$http_code" != "200" ]] || ! echo "$body" | jq -e '.value' &>/dev/null; then
            local error_msg
            error_msg=$(echo "$body" | jq -r '.error.message // "no response"' 2>/dev/null)
            print_warning "  Graph request failed (HTTP ${http_code:-?}): $error_msg" >&2
            print_warning "    $url" >&2
            if [[ "$http_code" == "403" && -n "$permission_hint" ]]; then
                print_warning "  Hint: the identity may be missing $permission_hint" >&2
            fi
            rm -f "$pages"
            return 1
        fi

        # Accumulate pages on disk — an argv-passed accumulator is
        # ARG_MAX-bound and re-serialised per page
        echo "$body" | jq '.value' >> "$pages"
        url=$(echo "$body" | jq -r '.["@odata.nextLink"] // empty')
    done

    jq -s 'add // []' "$pages"
    rm -f "$pages"
}

# Create display-name symlinks under $3 for each .principalId in the JSON
# array $2, pointing at the principal's ___guid.json under entra/.
# Link depth assumes $3 is entra/pim/{groups|roles}/{name}/eligible.
link_eligible_principals() {
    local token="$1"
    local principals_json="$2"
    local eligible_dir="$3"

    # No principals — don't leave an empty eligible/ dir behind
    [[ "$(echo "$principals_json" | jq 'length')" == "0" ]] && return 0

    ensure_dir "$eligible_dir"

    while read -r principal_id; do
        [[ -z "$principal_id" ]] && continue

        # Resolve principal name+type, cached — the same principal is
        # typically eligible in many groups/roles
        local principal_info principal_name safe_principal_name principal_type
        if [[ -n "${PRINCIPAL_CACHE[$principal_id]:-}" ]]; then
            principal_type="${PRINCIPAL_CACHE[$principal_id]%%|*}"
            safe_principal_name="${PRINCIPAL_CACHE[$principal_id]#*|}"
        else
            principal_info=$(curl -s --retry 4 --retry-max-time 300 -H "Authorization: Bearer $token" \
                "https://graph.microsoft.com/v1.0/directoryObjects/${principal_id}" 2>/dev/null)
            principal_name=$(echo "$principal_info" | jq -r '.displayName // .userPrincipalName // .id')
            safe_principal_name=$(sanitize_name "$principal_name")
            principal_type=$(echo "$principal_info" | jq -r '.["@odata.type"] // "unknown"' | sed 's/#microsoft.graph.//')
            PRINCIPAL_CACHE[$principal_id]="${principal_type}|${safe_principal_name}"
        fi

        [[ -z "$safe_principal_name" ]] && continue

        # Find the ___guid.json file and create symlink to it.
        # find exits non-zero when the tree doesn't exist yet (e.g. a
        # standalone `pim` run before users/groups are synced) — with
        # pipefail that would silently kill the script.
        local found_file=""
        local relative_path=""

        case "$principal_type" in
            "user")
                found_file=$(find "$AZURE_DIR/entra/users" -name "___${principal_id}.json" 2>/dev/null | head -1) || true
                if [[ -n "$found_file" ]]; then
                    local user_type=$(basename "$(dirname "$(dirname "$found_file")")")
                    relative_path="../../../../users/$user_type/$safe_principal_name/___${principal_id}.json"
                fi
                ;;
            "group")
                found_file=$(find "$AZURE_DIR/entra/groups" -name "___${principal_id}.json" 2>/dev/null | head -1) || true
                if [[ -n "$found_file" ]]; then
                    local grp_name=$(basename "$(dirname "$found_file")")
                    relative_path="../../../../groups/$grp_name/___${principal_id}.json"
                fi
                ;;
            "servicePrincipal")
                found_file=$(find "$AZURE_DIR/entra/service_principals" -name "___${principal_id}.json" 2>/dev/null | head -1) || true
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
    done < <(echo "$principals_json" | jq -r '[.[].principalId] | unique | .[]')
}

sync_pim_groups() {
    print_info "Syncing PIM group eligibilities..."

    local token
    token=$(get_pim_graph_token)

    if [[ -z "$token" ]]; then
        print_warning "  Could not get Graph API token, skipping PIM group sync"
        return
    fi

    # Discover PIM-enabled groups by querying every group for eligibility
    # schedules. The privilegedAccess/group API requires a groupId or
    # principalId filter, and filtering on the caller's principalId only sees
    # the caller's own eligibilities — under app-only auth (CI) the SP has
    # none, which left this sync silently empty.
    local all_groups
    if ! all_groups=$(graph_get_all "$token" "https://graph.microsoft.com/v1.0/groups?\$select=id,displayName,groupTypes&\$top=999" "Group.Read.All"); then
        print_warning "  Could not list groups, skipping PIM group sync"
        return
    fi

    local groups_dir="$AZURE_DIR/entra/pim/groups"
    ensure_dir "$groups_dir"

    local pim_group_count=0
    while read -r group; do
        [[ -z "$group" ]] && continue

        # PIM for Groups can't be enabled on dynamic-membership groups —
        # skip instead of probing them twice each
        if [[ "$(echo "$group" | jq '(.groupTypes // []) | index("DynamicMembership") != null')" == "true" ]]; then
            continue
        fi

        local group_id group_name safe_group_name group_pim_dir
        group_id=$(echo "$group" | jq -r '.id')
        group_name=$(echo "$group" | jq -r '.displayName // .id')
        safe_group_name=$(sanitize_name "$group_name")

        # A displayName that sanitizes to nothing (or a dot-dir) must never
        # reach the rm -rf below
        if [[ -z "$safe_group_name" || "$safe_group_name" == "." || "$safe_group_name" == ".." ]]; then
            print_warning "  Skipping group $group_id: unusable display name for a path"
            continue
        fi
        group_pim_dir="$groups_dir/$safe_group_name"

        # Fetch BOTH schedules before touching this group's snapshot; any
        # failure aborts the whole sync so previously-synced data is left
        # intact — in the committed diff, a silent [] from a failed fetch
        # would be indistinguishable from a real access change.
        local eligibilities
        if ! eligibilities=$(graph_get_all "$token" "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" "PrivilegedEligibilitySchedule.Read.AzureADGroup"); then
            print_warning "  Aborting PIM group sync (eligibility schedules unreadable)"
            return
        fi

        local active
        if ! active=$(graph_get_all "$token" "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" "PrivilegedEligibilitySchedule.Read.AzureADGroup"); then
            print_warning "  Aborting PIM group sync (assignment schedules unreadable)"
            return
        fi

        # Not a PIM-enabled group: make sure no stale snapshot lingers
        if [[ "$(echo "$eligibilities" | jq 'length')" == "0" ]] && [[ "$(echo "$active" | jq 'length')" == "0" ]]; then
            rm -rf "$group_pim_dir"
            continue
        fi

        pim_group_count=$((pim_group_count + 1))
        rm -rf "$group_pim_dir"
        ensure_dir "$group_pim_dir"

        # sort_by(.id): Graph doesn't guarantee collection order, and the
        # whole point of the snapshot is a meaningful git diff
        echo "$eligibilities" | jq 'sort_by(.id)' > "$group_pim_dir/_eligibilities.json"
        echo "$active" | jq 'sort_by(.id)' > "$group_pim_dir/_active.json"

        # Create symlinks to eligible users/groups
        link_eligible_principals "$token" "$eligibilities" "$group_pim_dir/eligible"

    done < <(echo "$all_groups" | jq -c '.[]')

    if [[ "$pim_group_count" -eq 0 ]]; then
        print_warning "  No PIM-enabled groups found"
        return
    fi

    print_success "  PIM groups synced to $groups_dir ($pim_group_count group(s))"
}

sync_pim_roles() {
    print_info "Syncing PIM directory role eligibilities..."

    local token
    token=$(get_pim_graph_token)

    if [[ -z "$token" ]]; then
        print_warning "  Could not get Graph API token, skipping PIM role sync"
        return
    fi

    # Requires RoleManagement.Read.Directory (delegated or application).
    # ALL three fetches must succeed before the snapshot is rebuilt — a []
    # or GUID-name fallback would commit a wipe/rename indistinguishable
    # from a real access change.
    local eligibilities
    if ! eligibilities=$(graph_get_all "$token" "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances" "RoleManagement.Read.Directory"); then
        print_warning "  Skipping PIM role sync (eligibility schedules unreadable)"
        return
    fi

    local active
    if ! active=$(graph_get_all "$token" "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances" "RoleManagement.Read.Directory"); then
        print_warning "  Skipping PIM role sync (assignment schedules unreadable)"
        return
    fi

    local role_defs
    if ! role_defs=$(graph_get_all "$token" "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$select=id,displayName" "RoleManagement.Read.Directory"); then
        print_warning "  Skipping PIM role sync (role definitions unreadable)"
        return
    fi

    # All fetches succeeded — safe to rebuild the snapshot from scratch
    local roles_dir="$AZURE_DIR/entra/pim/roles"
    rm -rf "$roles_dir"
    ensure_dir "$roles_dir"

    local role_ids
    role_ids=$(jq -nr --argjson e "$eligibilities" --argjson a "$active" \
        '[$e[].roleDefinitionId, $a[].roleDefinitionId] | unique | .[]')

    local role_count=0
    while read -r role_id; do
        [[ -z "$role_id" ]] && continue

        local role_name safe_role_name role_dir
        role_name=$(echo "$role_defs" | jq -r --arg id "$role_id" '[.[] | select(.id == $id) | .displayName] | first // $id')
        safe_role_name=$(sanitize_name "$role_name")
        if [[ -z "$safe_role_name" || "$safe_role_name" == "." || "$safe_role_name" == ".." ]]; then
            print_warning "  Skipping role $role_id: unusable display name for a path"
            continue
        fi
        role_dir="$roles_dir/$safe_role_name"
        ensure_dir "$role_dir"
        role_count=$((role_count + 1))

        # NOTE: grouping by roleDefinitionId flattens directoryScopeId — an
        # AU- or app-scoped eligibility lands in the same directory as a
        # tenant-wide one. The scope survives in the JSON below; check it
        # before reading the eligible/ folder view as tenant-wide.
        local role_elig role_active
        role_elig=$(echo "$eligibilities" | jq --arg id "$role_id" '[.[] | select(.roleDefinitionId == $id)] | sort_by(.id)')
        role_active=$(echo "$active" | jq --arg id "$role_id" '[.[] | select(.roleDefinitionId == $id)] | sort_by(.id)')

        echo "$role_elig" > "$role_dir/_eligibilities.json"
        echo "$role_active" > "$role_dir/_active.json"

        # Create symlinks to eligible users/groups
        link_eligible_principals "$token" "$role_elig" "$role_dir/eligible"

    done <<< "$role_ids"

    print_success "  PIM roles synced to $roles_dir ($role_count role(s))"
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
    pim         Sync PIM eligibilities (groups + directory roles)
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
            [[ "$SYNC_RBAC" == "true" ]] && sync_principal_roles
            sync_pim_groups
            sync_pim_roles
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
            sync_principal_roles
            ;;
        pim)
            sync_pim_groups
            sync_pim_roles
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

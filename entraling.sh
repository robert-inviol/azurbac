#!/bin/bash
#
# entraling.sh - Entra ID Permissions Audit Tool (Entra Trawling)
# Audit permissions in Entra ID including PIM entitlements and PIM group entitlements
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color
BOLD='\033[1m'
DIM='\033[2m'

# Configuration
CONFIG_DIR="$HOME/.config/entra-audit"
APP_CONFIG_FILE="$CONFIG_DIR/app.json"
TOKEN_CACHE_FILE="$CONFIG_DIR/token.json"
APP_NAME="Entra Audit Tool"

# Output formats
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"  # table, json, csv
AUDIT_OUTPUT_DIR="${AUDIT_OUTPUT_DIR:-./audit-reports}"

# Required Graph API permissions for auditing (delegated permissions)
GRAPH_PERMISSIONS=(
    "User.Read"
    "User.Read.All"
    "Group.Read.All"
    "Directory.Read.All"
    "RoleManagement.Read.Directory"
    "RoleManagement.Read.All"
    "PrivilegedAccess.Read.AzureADGroup"
    "PrivilegedEligibilitySchedule.Read.AzureADGroup"
    "PrivilegedAssignmentSchedule.Read.AzureADGroup"
    "Application.Read.All"
)

# Global caches
GRAPH_TOKEN=""
declare -A USER_CACHE
declare -A GROUP_CACHE
declare -A ROLE_CACHE

#------------------------------------------------------------------------------
# Utility Functions
#------------------------------------------------------------------------------

print_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${BLUE}$1${NC}" >&2
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

print_header() {
    echo ""
    gum style --bold --foreground 212 "$1"
    echo ""
}

print_subheader() {
    gum style --foreground 33 "$1"
}

check_dependencies() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if ! command -v gum &> /dev/null; then
        missing+=("gum")
    fi

    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required dependencies: ${missing[*]}"
        echo "Please install them before running this script."
        exit 1
    fi
}

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
}

#------------------------------------------------------------------------------
# Token Management (reuses pim.sh token infrastructure)
#------------------------------------------------------------------------------

get_app_config() {
    if [[ -f "$APP_CONFIG_FILE" ]]; then
        cat "$APP_CONFIG_FILE"
    else
        echo ""
    fi
}

get_cached_token() {
    if [[ -f "$TOKEN_CACHE_FILE" ]]; then
        local token_data
        token_data=$(cat "$TOKEN_CACHE_FILE")

        local expires_on
        expires_on=$(echo "$token_data" | jq -r '.expires_on // 0')
        local now
        now=$(date +%s)

        # Check if token is still valid (with 5 min buffer)
        if [[ "$expires_on" -gt $((now + 300)) ]]; then
            echo "$token_data" | jq -r '.access_token'
            return 0
        fi
    fi
    return 1
}

get_refresh_token() {
    if command -v secret-tool &> /dev/null; then
        secret-tool lookup application entra-audit type refresh_token 2>/dev/null || echo ""
    else
        echo ""
    fi
}

save_token() {
    local access_token="$1"
    local expires_in="$2"
    local refresh_token="${3:-}"

    ensure_config_dir
    local expires_on
    expires_on=$(($(date +%s) + expires_in))

    cat > "$TOKEN_CACHE_FILE" << EOF
{
    "access_token": "$access_token",
    "expires_on": $expires_on
}
EOF
    chmod 600 "$TOKEN_CACHE_FILE"

    if [[ -n "$refresh_token" ]] && command -v secret-tool &> /dev/null; then
        echo -n "$refresh_token" | secret-tool store --label="Entra Audit Refresh Token" \
            application entra-audit \
            type refresh_token \
            2>/dev/null || true
    fi
}

refresh_access_token() {
    local config
    config=$(get_app_config)

    if [[ -z "$config" ]]; then
        return 1
    fi

    local refresh_token
    refresh_token=$(get_refresh_token)

    if [[ -z "$refresh_token" ]]; then
        return 1
    fi

    local app_id tenant_id
    app_id=$(echo "$config" | jq -r '.appId')
    tenant_id=$(echo "$config" | jq -r '.tenantId')

    local scopes="https://graph.microsoft.com/.default offline_access"

    local token_response
    token_response=$(curl -s -X POST \
        "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/token" \
        -d "client_id=$app_id" \
        -d "grant_type=refresh_token" \
        -d "refresh_token=$refresh_token" \
        -d "scope=$scopes")

    local access_token
    access_token=$(echo "$token_response" | jq -r '.access_token // empty')

    if [[ -n "$access_token" ]]; then
        local expires_in new_refresh_token
        expires_in=$(echo "$token_response" | jq -r '.expires_in // 3600')
        new_refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')

        if [[ -z "$new_refresh_token" ]]; then
            new_refresh_token="$refresh_token"
        fi

        save_token "$access_token" "$expires_in" "$new_refresh_token"
        return 0
    fi

    return 1
}

get_graph_token() {
    if [[ -n "$GRAPH_TOKEN" ]]; then
        echo "$GRAPH_TOKEN"
        return 0
    fi

    GRAPH_TOKEN=$(get_cached_token 2>/dev/null) || {
        if refresh_access_token; then
            GRAPH_TOKEN=$(get_cached_token) || {
                print_error "Not logged in. Please run 'entraling.sh login' first."
                return 1
            }
        else
            print_error "Not logged in. Please run 'entraling.sh login' first."
            return 1
        fi
    }

    echo "$GRAPH_TOKEN"
}

#------------------------------------------------------------------------------
# App Registration and Authentication
#------------------------------------------------------------------------------

check_az() {
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI (az) is not installed or not in PATH"
        echo "Please install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi
}

check_az_login() {
    if ! az account show &> /dev/null; then
        print_error "Not logged in to Azure CLI"
        echo "Please run: az login"
        exit 1
    fi
}

get_tenant_id() {
    az account show --query tenantId -o tsv
}

save_app_config() {
    local app_id="$1"
    local tenant_id="$2"

    ensure_config_dir
    cat > "$APP_CONFIG_FILE" << EOF
{
    "appId": "$app_id",
    "tenantId": "$tenant_id"
}
EOF
    chmod 600 "$APP_CONFIG_FILE"
}

setup_app_registration() {
    print_header "Entra Audit App Registration Setup"

    check_az
    check_az_login

    local tenant_id
    tenant_id=$(get_tenant_id)

    # Check if app already exists
    local existing_app
    existing_app=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv 2>/dev/null || echo "")

    if [[ -n "$existing_app" ]]; then
        print_warning "App registration '$APP_NAME' already exists (App ID: $existing_app)"
        if gum confirm "Use the existing app?"; then
            save_app_config "$existing_app" "$tenant_id"
            print_success "Configuration saved!"
            echo ""
            echo "Next step: An admin needs to grant consent for the app permissions."
            echo "Run: ${BOLD}entraling.sh grant-consent${NC}"
            return 0
        fi
        print_info "Creating a new app registration..."
    fi

    print_info "Creating app registration '$APP_NAME'..."

    # Create the app registration with public client (for device code flow)
    local app_result
    app_result=$(az ad app create \
        --display-name "$APP_NAME" \
        --public-client-redirect-uris "https://login.microsoftonline.com/common/oauth2/nativeclient" \
        --is-fallback-public-client true \
        --sign-in-audience "AzureADMyOrg" \
        2>&1) || {
        print_error "Failed to create app registration: $app_result"
        return 1
    }

    local app_id
    app_id=$(echo "$app_result" | jq -r '.appId')

    print_success "App registration created (App ID: $app_id)"

    # Get Microsoft Graph service principal ID
    local graph_sp_id
    graph_sp_id=$(az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query '[0].id' -o tsv 2>/dev/null)

    # Get the permission IDs for the required scopes
    print_info "Adding API permissions..."

    local graph_permissions_json='[]'
    for perm in "${GRAPH_PERMISSIONS[@]}"; do
        local perm_id
        perm_id=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" \
            --query "oauth2PermissionScopes[?value=='$perm'].id" -o tsv 2>/dev/null || echo "")

        if [[ -n "$perm_id" ]]; then
            graph_permissions_json=$(echo "$graph_permissions_json" | jq ". + [{\"id\": \"$perm_id\", \"type\": \"Scope\"}]")
            print_info "  Added: $perm"
        else
            print_warning "  Permission not found: $perm"
        fi
    done

    # Update the app with required permissions
    local required_access="[{\"resourceAppId\": \"00000003-0000-0000-c000-000000000000\", \"resourceAccess\": $graph_permissions_json}]"

    az ad app update --id "$app_id" --required-resource-accesses "$required_access" 2>/dev/null || {
        print_warning "Could not add permissions automatically. Please add them manually in Azure Portal."
    }

    # Create service principal for the app
    print_info "Creating service principal..."
    az ad sp create --id "$app_id" 2>/dev/null || true

    # Save configuration
    save_app_config "$app_id" "$tenant_id"

    print_success "App registration setup complete!"
    echo ""
    echo "App ID: ${BOLD}$app_id${NC}"
    echo "Tenant ID: ${BOLD}$tenant_id${NC}"
    echo ""
    print_warning "IMPORTANT: An admin must grant consent for the API permissions."
    echo ""
    echo "Option 1: Run as admin: ${BOLD}entraling.sh grant-consent${NC}"
    echo "Option 2: Go to Azure Portal -> App registrations -> $APP_NAME -> API permissions -> Grant admin consent"
    echo ""
    echo "After consent is granted, run: ${BOLD}entraling.sh login${NC}"
}

grant_admin_consent() {
    print_header "Grant Admin Consent"

    check_az
    check_az_login

    local config
    config=$(get_app_config)

    if [[ -z "$config" ]]; then
        print_error "App not configured. Run 'entraling.sh setup' first."
        return 1
    fi

    local app_id
    app_id=$(echo "$config" | jq -r '.appId')

    print_info "Granting admin consent for app: $app_id"
    print_warning "This requires Global Administrator or Privileged Role Administrator permissions."
    echo ""

    # Get the service principal
    local sp_id
    sp_id=$(az ad sp list --filter "appId eq '$app_id'" --query '[0].id' -o tsv 2>/dev/null)

    if [[ -z "$sp_id" ]]; then
        print_info "Service principal not found. Creating..."
        az ad sp create --id "$app_id" 2>/dev/null
        sp_id=$(az ad sp list --filter "appId eq '$app_id'" --query '[0].id' -o tsv 2>/dev/null)
    fi

    # Get Microsoft Graph service principal
    local graph_sp_id
    graph_sp_id=$(az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query '[0].id' -o tsv 2>/dev/null)

    # Build the scopes string
    local scopes=""
    for perm in "${GRAPH_PERMISSIONS[@]}"; do
        if [[ -n "$scopes" ]]; then
            scopes="$scopes $perm"
        else
            scopes="$perm"
        fi
    done

    # Create OAuth2 permission grant
    local grant_result
    grant_result=$(az rest \
        --method POST \
        --url "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" \
        --headers "Content-Type=application/json" \
        --body "{
            \"clientId\": \"$sp_id\",
            \"consentType\": \"AllPrincipals\",
            \"resourceId\": \"$graph_sp_id\",
            \"scope\": \"$scopes\"
        }" 2>&1) || {
        if echo "$grant_result" | grep -q "Permission entry already exists"; then
            print_success "Admin consent already granted!"
        else
            print_error "Failed to grant consent: $grant_result"
            echo ""
            echo "Please grant consent manually in Azure Portal:"
            echo "1. Go to Azure Portal -> Microsoft Entra ID -> App registrations"
            echo "2. Find '$APP_NAME'"
            echo "3. Go to API permissions"
            echo "4. Click 'Grant admin consent'"
            return 1
        fi
    }

    if [[ -n "$grant_result" ]] && ! echo "$grant_result" | grep -q "error"; then
        print_success "Admin consent granted successfully!"
    fi

    echo ""
    echo "You can now run: ${BOLD}entraling.sh login${NC}"
}

do_device_code_login() {
    print_header "Login to Entra Audit"

    local config
    config=$(get_app_config)

    if [[ -z "$config" ]]; then
        print_error "App not configured. Run 'entraling.sh setup' first."
        return 1
    fi

    local app_id tenant_id
    app_id=$(echo "$config" | jq -r '.appId')
    tenant_id=$(echo "$config" | jq -r '.tenantId')

    # Build scope string
    local scopes="https://graph.microsoft.com/User.Read"
    for perm in "${GRAPH_PERMISSIONS[@]}"; do
        scopes="$scopes https://graph.microsoft.com/$perm"
    done
    scopes="$scopes offline_access"

    print_info "Starting device code flow..."

    # Request device code
    local device_code_response
    device_code_response=$(curl -s -X POST \
        "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/devicecode" \
        -d "client_id=$app_id" \
        -d "scope=$scopes")

    local user_code device_code verification_uri message

    user_code=$(echo "$device_code_response" | jq -r '.user_code // empty')
    device_code=$(echo "$device_code_response" | jq -r '.device_code // empty')
    verification_uri=$(echo "$device_code_response" | jq -r '.verification_uri // empty')
    message=$(echo "$device_code_response" | jq -r '.message // empty')

    if [[ -z "$device_code" ]]; then
        local error
        error=$(echo "$device_code_response" | jq -r '.error_description // .error // "Unknown error"')
        print_error "Failed to get device code: $error"
        return 1
    fi

    echo ""
    echo "$message"
    echo ""
    gum style --bold --foreground 35 "Code: $user_code"
    echo ""

    # Poll for token
    local interval
    interval=$(echo "$device_code_response" | jq -r '.interval // 5')

    print_info "Waiting for authentication..."

    while true; do
        sleep "$interval"

        local token_response
        token_response=$(curl -s -X POST \
            "https://login.microsoftonline.com/$tenant_id/oauth2/v2.0/token" \
            -d "client_id=$app_id" \
            -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
            -d "device_code=$device_code")

        local access_token
        access_token=$(echo "$token_response" | jq -r '.access_token // empty')

        if [[ -n "$access_token" ]]; then
            local expires_in refresh_token
            expires_in=$(echo "$token_response" | jq -r '.expires_in // 3600')
            refresh_token=$(echo "$token_response" | jq -r '.refresh_token // empty')
            save_token "$access_token" "$expires_in" "$refresh_token"
            print_success "Logged in successfully!"
            if [[ -n "$refresh_token" ]]; then
                print_info "Refresh token saved - future logins will be automatic."
            fi
            return 0
        fi

        local error
        error=$(echo "$token_response" | jq -r '.error // empty')

        case "$error" in
            "authorization_pending")
                ;;
            "slow_down")
                interval=$((interval + 5))
                ;;
            "expired_token")
                print_error "Device code expired. Please try again."
                return 1
                ;;
            "access_denied")
                print_error "Access denied by user."
                return 1
                ;;
            *)
                local error_desc
                error_desc=$(echo "$token_response" | jq -r '.error_description // "Unknown error"')
                print_error "Authentication failed: $error_desc"
                return 1
                ;;
        esac
    done
}

# Make a Graph API request
graph_request() {
    local method="$1"
    local url="$2"
    local body="${3:-}"

    local token
    token=$(get_graph_token) || return 1

    local curl_args=(
        -s
        -X "$method"
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "ConsistencyLevel: eventual"
    )

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    curl "${curl_args[@]}" "$url"
}

# Paginated Graph API request - fetches all pages
graph_request_all() {
    local url="$1"
    local results="[]"
    local next_url="$url"

    while [[ -n "$next_url" ]]; do
        local response
        response=$(graph_request GET "$next_url") || return 1

        if echo "$response" | jq -e '.error' &>/dev/null; then
            local error_msg
            error_msg=$(echo "$response" | jq -r '.error.message // "Unknown error"')
            print_error "API Error: $error_msg"
            return 1
        fi

        local page_results
        page_results=$(echo "$response" | jq '.value // []')
        results=$(echo "$results $page_results" | jq -s 'add')

        next_url=$(echo "$response" | jq -r '.["@odata.nextLink"] // empty')
    done

    echo "$results"
}

#------------------------------------------------------------------------------
# Name Resolution Functions (with caching)
#------------------------------------------------------------------------------

resolve_user_name() {
    local user_id="$1"

    if [[ -z "$user_id" ]] || [[ "$user_id" == "null" ]]; then
        echo "Unknown"
        return
    fi

    # Check cache first
    if [[ -v "USER_CACHE[$user_id]" ]]; then
        echo "${USER_CACHE[$user_id]}"
        return
    fi

    local result
    result=$(graph_request GET "https://graph.microsoft.com/v1.0/users/${user_id}?\$select=displayName,userPrincipalName" 2>/dev/null)

    local name
    name=$(echo "$result" | jq -r '.displayName // .userPrincipalName // empty' 2>/dev/null)

    if [[ -n "$name" ]]; then
        USER_CACHE[$user_id]="$name"
        echo "$name"
    else
        # Could be a service principal
        result=$(graph_request GET "https://graph.microsoft.com/v1.0/servicePrincipals/${user_id}?\$select=displayName" 2>/dev/null)
        name=$(echo "$result" | jq -r '.displayName // empty' 2>/dev/null)

        if [[ -n "$name" ]]; then
            USER_CACHE[$user_id]="$name (SP)"
            echo "$name (SP)"
        else
            USER_CACHE[$user_id]="$user_id"
            echo "$user_id"
        fi
    fi
}

resolve_group_name() {
    local group_id="$1"

    if [[ -z "$group_id" ]] || [[ "$group_id" == "null" ]]; then
        echo "Unknown"
        return
    fi

    if [[ -v "GROUP_CACHE[$group_id]" ]]; then
        echo "${GROUP_CACHE[$group_id]}"
        return
    fi

    local result
    result=$(graph_request GET "https://graph.microsoft.com/v1.0/groups/${group_id}?\$select=displayName" 2>/dev/null)

    local name
    name=$(echo "$result" | jq -r '.displayName // empty' 2>/dev/null)

    if [[ -n "$name" ]]; then
        GROUP_CACHE[$group_id]="$name"
        echo "$name"
    else
        GROUP_CACHE[$group_id]="$group_id"
        echo "$group_id"
    fi
}

resolve_role_name() {
    local role_id="$1"

    if [[ -z "$role_id" ]] || [[ "$role_id" == "null" ]]; then
        echo "Unknown"
        return
    fi

    if [[ -v "ROLE_CACHE[$role_id]" ]]; then
        echo "${ROLE_CACHE[$role_id]}"
        return
    fi

    local result
    result=$(graph_request GET "https://graph.microsoft.com/v1.0/directoryRoles/${role_id}?\$select=displayName" 2>/dev/null)

    local name
    name=$(echo "$result" | jq -r '.displayName // empty' 2>/dev/null)

    if [[ -n "$name" ]]; then
        ROLE_CACHE[$role_id]="$name"
        echo "$name"
    else
        # Try role definition
        result=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions/${role_id}?\$select=displayName" 2>/dev/null)
        name=$(echo "$result" | jq -r '.displayName // empty' 2>/dev/null)

        if [[ -n "$name" ]]; then
            ROLE_CACHE[$role_id]="$name"
            echo "$name"
        else
            ROLE_CACHE[$role_id]="$role_id"
            echo "$role_id"
        fi
    fi
}

#------------------------------------------------------------------------------
# Directory Role Audit Functions
#------------------------------------------------------------------------------

audit_directory_roles() {
    print_header "Directory Role Assignments"

    local token
    token=$(get_graph_token) || return 1

    # Get all role assignments (without expand - we'll resolve names separately)
    local url="https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments"

    local assignments
    assignments=$(gum spin --spinner dot --title "Fetching directory role assignments..." -- \
        bash -c "curl -s -X GET -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' '$url'")

    if echo "$assignments" | jq -e '.error' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$assignments" | jq -r '.error.message // "Unknown error"')
        print_error "Failed to fetch role assignments: $error_msg"
        return 1
    fi

    local count
    count=$(echo "$assignments" | jq '.value | length')

    if [[ "$count" -eq 0 ]]; then
        print_warning "No directory role assignments found."
        return 0
    fi

    gum style --foreground 252 "Found $count directory role assignment(s)"
    echo ""

    # Get role definitions for name mapping
    local role_defs
    role_defs=$(gum spin --spinner dot --title "Fetching role definitions..." -- \
        bash -c "curl -s -X GET -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' 'https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$select=id,displayName'")
    local role_map
    role_map=$(echo "$role_defs" | jq '[.value[] | {(.id): .displayName}] | add // {}')

    # Group by role and resolve names
    local roles_json
    roles_json=$(echo "$assignments" | jq --argjson roles "$role_map" '[.value | group_by(.roleDefinitionId) | .[] | {
        role: ($roles[.[0].roleDefinitionId] // .[0].roleDefinitionId),
        roleId: .[0].roleDefinitionId,
        members: [.[] | {
            principalId: .principalId,
            directoryScopeId: .directoryScopeId
        }]
    }] | sort_by(.role)')

    # Display results
    while IFS= read -r role_data; do
        local role_name member_count
        role_name=$(echo "$role_data" | jq -r '.role')
        member_count=$(echo "$role_data" | jq '.members | length')

        gum style --bold --foreground 35 "$role_name ($member_count member(s))"

        while IFS= read -r member; do
            local principal_id scope
            principal_id=$(echo "$member" | jq -r '.principalId')
            scope=$(echo "$member" | jq -r '.directoryScopeId')

            local principal_name
            principal_name=$(resolve_user_name "$principal_id")

            if [[ "$scope" == "/" ]]; then
                gum style --foreground 252 "  - $principal_name"
            else
                gum style --foreground 252 "  - $principal_name (scope: $scope)"
            fi
        done < <(echo "$role_data" | jq -c '.members[]')

        echo ""
    done < <(echo "$roles_json" | jq -c '.[]')
}

#------------------------------------------------------------------------------
# PIM Role Eligibility Audit Functions
#------------------------------------------------------------------------------

audit_pim_role_eligibilities() {
    print_header "PIM Role Eligibility Assignments"

    local token
    token=$(get_graph_token) || return 1

    # Get all PIM role eligibility schedule instances
    local url="https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances"

    local eligibilities
    eligibilities=$(gum spin --spinner dot --title "Fetching PIM role eligibilities..." -- \
        bash -c "curl -s -X GET -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -H 'ConsistencyLevel: eventual' '$url'")

    if echo "$eligibilities" | jq -e '.error' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$eligibilities" | jq -r '.error.message // "Unknown error"')
        print_error "Failed to fetch PIM eligibilities: $error_msg"
        return 1
    fi

    local count
    count=$(echo "$eligibilities" | jq '.value | length')

    if [[ "$count" -eq 0 ]]; then
        print_warning "No PIM role eligibility assignments found."
        return 0
    fi

    gum style --foreground 252 "Found $count PIM role eligibility assignment(s)"
    echo ""

    # Collect unique IDs for batch resolution
    local role_ids principal_ids
    role_ids=$(echo "$eligibilities" | jq -r '[.value[].roleDefinitionId] | unique | .[]')
    principal_ids=$(echo "$eligibilities" | jq -r '[.value[].principalId] | unique | .[]')

    # Pre-fetch role definitions
    gum spin --spinner dot --title "Resolving role names..." -- sleep 0.1
    local role_defs
    role_defs=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$select=id,displayName")
    local role_map
    role_map=$(echo "$role_defs" | jq '[.value[] | {(.id): .displayName}] | add // {}')

    # Process and display
    local processed
    processed=$(echo "$eligibilities" | jq --argjson roles "$role_map" '[.value[] | {
        roleId: .roleDefinitionId,
        roleName: ($roles[.roleDefinitionId] // .roleDefinitionId),
        principalId: .principalId,
        startDateTime: .startDateTime,
        endDateTime: .endDateTime,
        memberType: .memberType,
        directoryScopeId: .directoryScopeId
    }] | group_by(.roleName) | map({
        role: .[0].roleName,
        members: .
    }) | sort_by(.role)')

    while IFS= read -r role_group; do
        local role_name member_count
        role_name=$(echo "$role_group" | jq -r '.role')
        member_count=$(echo "$role_group" | jq '.members | length')

        gum style --bold --foreground 35 "$role_name ($member_count eligible)"

        while IFS= read -r member; do
            local principal_id end_date member_type scope
            principal_id=$(echo "$member" | jq -r '.principalId')
            end_date=$(echo "$member" | jq -r '.endDateTime // "Permanent"')
            member_type=$(echo "$member" | jq -r '.memberType // "Direct"')
            scope=$(echo "$member" | jq -r '.directoryScopeId')

            local principal_name
            principal_name=$(resolve_user_name "$principal_id")

            local expiry_info=""
            if [[ "$end_date" != "Permanent" ]] && [[ "$end_date" != "null" ]]; then
                expiry_info=" (expires: ${end_date:0:10})"
            fi

            local scope_info=""
            if [[ "$scope" != "/" ]] && [[ "$scope" != "null" ]]; then
                scope_info=" [scope: $scope]"
            fi

            gum style --foreground 252 "  - $principal_name [$member_type]$expiry_info$scope_info"
        done < <(echo "$role_group" | jq -c '.members[]')

        echo ""
    done < <(echo "$processed" | jq -c '.[]')
}

audit_pim_role_active_assignments() {
    print_header "PIM Active Role Assignments"

    local token
    token=$(get_graph_token) || return 1

    local url="https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances"

    local assignments
    assignments=$(gum spin --spinner dot --title "Fetching active PIM role assignments..." -- \
        bash -c "curl -s -X GET -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' -H 'ConsistencyLevel: eventual' '$url'")

    if echo "$assignments" | jq -e '.error' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$assignments" | jq -r '.error.message // "Unknown error"')
        print_error "Failed to fetch active assignments: $error_msg"
        return 1
    fi

    local count
    count=$(echo "$assignments" | jq '.value | length')

    if [[ "$count" -eq 0 ]]; then
        print_warning "No active PIM role assignments found."
        return 0
    fi

    gum style --foreground 252 "Found $count active PIM role assignment(s)"
    echo ""

    # Get role definitions for name mapping
    local role_defs
    role_defs=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?\$select=id,displayName")
    local role_map
    role_map=$(echo "$role_defs" | jq '[.value[] | {(.id): .displayName}] | add // {}')

    # Process and display
    local processed
    processed=$(echo "$assignments" | jq --argjson roles "$role_map" '[.value[] | {
        roleId: .roleDefinitionId,
        roleName: ($roles[.roleDefinitionId] // .roleDefinitionId),
        principalId: .principalId,
        startDateTime: .startDateTime,
        endDateTime: .endDateTime,
        assignmentType: .assignmentType,
        memberType: .memberType
    }] | group_by(.roleName) | map({
        role: .[0].roleName,
        members: .
    }) | sort_by(.role)')

    while IFS= read -r role_group; do
        local role_name member_count
        role_name=$(echo "$role_group" | jq -r '.role')
        member_count=$(echo "$role_group" | jq '.members | length')

        gum style --bold --foreground 35 "$role_name ($member_count active)"

        while IFS= read -r member; do
            local principal_id end_date assignment_type
            principal_id=$(echo "$member" | jq -r '.principalId')
            end_date=$(echo "$member" | jq -r '.endDateTime // "Permanent"')
            assignment_type=$(echo "$member" | jq -r '.assignmentType // "Assigned"')

            local principal_name
            principal_name=$(resolve_user_name "$principal_id")

            local expiry_info=""
            if [[ "$end_date" != "Permanent" ]] && [[ "$end_date" != "null" ]]; then
                expiry_info=" (expires: ${end_date:0:10})"
            fi

            local type_color=252
            if [[ "$assignment_type" == "Activated" ]]; then
                type_color=214  # Yellow for activated
            fi

            gum style --foreground "$type_color" "  - $principal_name [$assignment_type]$expiry_info"
        done < <(echo "$role_group" | jq -c '.members[]')

        echo ""
    done < <(echo "$processed" | jq -c '.[]')
}

#------------------------------------------------------------------------------
# PIM Group Eligibility Audit Functions
#------------------------------------------------------------------------------

get_pim_enabled_groups() {
    local token="$1"

    # Strategy: Get current user's eligible groups first, then query each group
    # to discover all PIM-enabled groups
    local user_result user_id
    user_result=$(graph_request GET "https://graph.microsoft.com/v1.0/me?\$select=id")
    user_id=$(echo "$user_result" | jq -r '.id // empty')

    # Get groups the current user is eligible for
    local user_groups
    user_groups=$(curl -s -H "Authorization: Bearer $token" \
        "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=principalId%20eq%20%27${user_id}%27" 2>/dev/null)

    # Also try to get groups from active assignments
    local user_active
    user_active=$(curl -s -H "Authorization: Bearer $token" \
        "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?\$filter=principalId%20eq%20%27${user_id}%27" 2>/dev/null)

    # Combine and get unique group IDs
    local all_group_ids
    all_group_ids=$(echo "$user_groups $user_active" | jq -rs '[.[].value[]?.groupId] | unique | .[]' 2>/dev/null)

    echo "$all_group_ids"
}

audit_pim_group_eligibilities() {
    print_header "PIM Group Eligibility Assignments (All Users)"

    local token
    token=$(get_graph_token) || return 1

    # First, discover PIM-enabled groups
    print_info "Discovering PIM-enabled groups..."
    local pim_groups
    pim_groups=$(get_pim_enabled_groups "$token")

    if [[ -z "$pim_groups" ]]; then
        print_warning "No PIM-enabled groups found (or no access to discover them)."
        return 0
    fi

    local group_count
    group_count=$(echo "$pim_groups" | wc -l)
    gum style --foreground 252 "Found $group_count PIM-enabled group(s)"
    echo ""

    # Get group names
    local group_ids_str
    group_ids_str=$(echo "$pim_groups" | while read -r gid; do printf "'%s'," "$gid"; done | sed 's/,$//')

    local group_names_result group_names
    group_names_result=$(curl -s -H "Authorization: Bearer $token" -H "ConsistencyLevel: eventual" \
        "https://graph.microsoft.com/v1.0/groups?\$filter=id%20in%20(${group_ids_str})&\$select=id,displayName" 2>/dev/null)
    group_names=$(echo "$group_names_result" | jq '[.value[] | {(.id): .displayName}] | add // {}')

    # Query each group for all eligible users
    local all_eligibilities="[]"

    while read -r group_id; do
        [[ -z "$group_id" ]] && continue

        local group_name
        group_name=$(echo "$group_names" | jq -r --arg id "$group_id" '.[$id] // $id')

        local group_eligibilities
        group_eligibilities=$(gum spin --spinner dot --title "Fetching eligibilities for $group_name..." -- \
            bash -c "curl -s -H 'Authorization: Bearer $token' 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27'" 2>/dev/null)

        if echo "$group_eligibilities" | jq -e '.value' &>/dev/null; then
            all_eligibilities=$(echo "$all_eligibilities" "$(echo "$group_eligibilities" | jq '.value')" | jq -s 'add')
        fi
    done <<< "$pim_groups"

    local count
    count=$(echo "$all_eligibilities" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        print_warning "No PIM group eligibility assignments found."
        return 0
    fi

    gum style --foreground 252 "Found $count total eligibility assignment(s)"
    echo ""

    # Process and display grouped by group
    local processed
    processed=$(echo "$all_eligibilities" | jq --argjson groups "$group_names" '[.[] | {
        groupId: .groupId,
        groupName: ($groups[.groupId] // .groupId),
        principalId: .principalId,
        accessId: .accessId,
        startDateTime: .startDateTime,
        endDateTime: .endDateTime,
        memberType: .memberType
    }] | group_by(.groupName) | map({
        group: .[0].groupName,
        groupId: .[0].groupId,
        members: .
    }) | sort_by(.group)')

    while IFS= read -r group_data; do
        local group_name member_count
        group_name=$(echo "$group_data" | jq -r '.group')
        member_count=$(echo "$group_data" | jq '.members | length')

        gum style --bold --foreground 35 "$group_name ($member_count eligible)"

        while IFS= read -r member; do
            local principal_id access_id end_date member_type
            principal_id=$(echo "$member" | jq -r '.principalId')
            access_id=$(echo "$member" | jq -r '.accessId')
            end_date=$(echo "$member" | jq -r '.endDateTime // "Permanent"')
            member_type=$(echo "$member" | jq -r '.memberType // "Direct"')

            local principal_name
            principal_name=$(resolve_user_name "$principal_id")

            local access_type="member"
            [[ "$access_id" == "owner" ]] && access_type="owner"

            local expiry_info=""
            if [[ "$end_date" != "Permanent" ]] && [[ "$end_date" != "null" ]]; then
                expiry_info=" (expires: ${end_date:0:10})"
            fi

            gum style --foreground 252 "  - $principal_name [$access_type] [$member_type]$expiry_info"
        done < <(echo "$group_data" | jq -c '.members[]')

        echo ""
    done < <(echo "$processed" | jq -c '.[]')
}

audit_pim_group_rbac() {
    print_header "PIM Group Azure RBAC Assignments"

    local token
    token=$(get_graph_token) || return 1

    # Check if az CLI is available
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI (az) is required for RBAC queries"
        echo "Please install it from: https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        return 1
    fi

    # Check az login
    if ! az account show &> /dev/null; then
        print_error "Not logged in to Azure CLI. Please run: az login"
        return 1
    fi

    # Discover PIM-enabled groups
    print_info "Discovering PIM-enabled groups..."
    local pim_groups
    pim_groups=$(get_pim_enabled_groups "$token")

    if [[ -z "$pim_groups" ]]; then
        print_warning "No PIM-enabled groups found."
        return 0
    fi

    local group_count
    group_count=$(echo "$pim_groups" | wc -l)
    gum style --foreground 252 "Found $group_count PIM-enabled group(s)"
    echo ""

    # Get group names
    local group_ids_str
    group_ids_str=$(echo "$pim_groups" | while read -r gid; do printf "'%s'," "$gid"; done | sed 's/,$//')

    local group_names_result group_names
    group_names_result=$(curl -s -H "Authorization: Bearer $token" -H "ConsistencyLevel: eventual" \
        "https://graph.microsoft.com/v1.0/groups?\$filter=id%20in%20(${group_ids_str})&\$select=id,displayName" 2>/dev/null)
    group_names=$(echo "$group_names_result" | jq '[.value[] | {(.id): .displayName}] | add // {}')

    # Query RBAC for each group
    while read -r group_id; do
        [[ -z "$group_id" ]] && continue

        local group_name
        group_name=$(echo "$group_names" | jq -r --arg id "$group_id" '.[$id] // $id')

        gum style --bold --foreground 35 "$group_name"

        local rbac_assignments
        rbac_assignments=$(gum spin --spinner dot --title "Fetching RBAC for $group_name..." -- \
            bash -c "az role assignment list --assignee '$group_id' --all 2>/dev/null")

        if [[ -z "$rbac_assignments" ]] || [[ "$rbac_assignments" == "[]" ]]; then
            gum style --foreground 245 "  (no Azure RBAC assignments)"
        else
            local assignment_count
            assignment_count=$(echo "$rbac_assignments" | jq 'length')

            while IFS= read -r assignment; do
                local role_name scope_raw scope_display
                role_name=$(echo "$assignment" | jq -r '.roleDefinitionName')
                scope_raw=$(echo "$assignment" | jq -r '.scope')

                # Parse scope to make it more readable
                if [[ "$scope_raw" == "/subscriptions/"* ]]; then
                    local sub_id rg_name resource_path
                    sub_id=$(echo "$scope_raw" | sed -n 's|/subscriptions/\([^/]*\).*|\1|p')

                    if echo "$scope_raw" | grep -q "/resourceGroups/"; then
                        rg_name=$(echo "$scope_raw" | sed -n 's|.*/resourceGroups/\([^/]*\).*|\1|p')
                        if echo "$scope_raw" | grep -q "/providers/"; then
                            resource_path=$(echo "$scope_raw" | sed 's|.*/providers/||')
                            scope_display="RG:$rg_name/$resource_path"
                        else
                            scope_display="RG:$rg_name"
                        fi
                    else
                        # Subscription level
                        local sub_name
                        sub_name=$(az account show --subscription "$sub_id" --query name -o tsv 2>/dev/null || echo "$sub_id")
                        scope_display="Sub:$sub_name"
                    fi
                elif [[ "$scope_raw" == "/providers/Microsoft.Management/managementGroups/"* ]]; then
                    local mg_name
                    mg_name=$(echo "$scope_raw" | sed 's|.*/managementGroups/||')
                    scope_display="MG:$mg_name"
                else
                    scope_display="$scope_raw"
                fi

                gum style --foreground 252 "  - ${role_name} @ ${scope_display}"
            done < <(echo "$rbac_assignments" | jq -c '.[]')
        fi

        echo ""
    done <<< "$pim_groups"
}

audit_pim_group_active_assignments() {
    print_header "PIM Active Group Assignments (All Users)"

    local token
    token=$(get_graph_token) || return 1

    # First, discover PIM-enabled groups
    print_info "Discovering PIM-enabled groups..."
    local pim_groups
    pim_groups=$(get_pim_enabled_groups "$token")

    if [[ -z "$pim_groups" ]]; then
        print_warning "No PIM-enabled groups found (or no access to discover them)."
        return 0
    fi

    local group_count
    group_count=$(echo "$pim_groups" | wc -l)
    gum style --foreground 252 "Found $group_count PIM-enabled group(s)"
    echo ""

    # Get group names
    local group_ids_str
    group_ids_str=$(echo "$pim_groups" | while read -r gid; do printf "'%s'," "$gid"; done | sed 's/,$//')

    local group_names_result group_names
    group_names_result=$(curl -s -H "Authorization: Bearer $token" -H "ConsistencyLevel: eventual" \
        "https://graph.microsoft.com/v1.0/groups?\$filter=id%20in%20(${group_ids_str})&\$select=id,displayName" 2>/dev/null)
    group_names=$(echo "$group_names_result" | jq '[.value[] | {(.id): .displayName}] | add // {}')

    # Query each group for all active assignments
    local all_assignments="[]"

    while read -r group_id; do
        [[ -z "$group_id" ]] && continue

        local group_name
        group_name=$(echo "$group_names" | jq -r --arg id "$group_id" '.[$id] // $id')

        local group_assignments
        group_assignments=$(gum spin --spinner dot --title "Fetching active assignments for $group_name..." -- \
            bash -c "curl -s -H 'Authorization: Bearer $token' 'https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27'" 2>/dev/null)

        if echo "$group_assignments" | jq -e '.value' &>/dev/null; then
            all_assignments=$(echo "$all_assignments" "$(echo "$group_assignments" | jq '.value')" | jq -s 'add')
        fi
    done <<< "$pim_groups"

    local count
    count=$(echo "$all_assignments" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        print_warning "No active PIM group assignments found."
        return 0
    fi

    gum style --foreground 252 "Found $count total active assignment(s)"
    echo ""

    # Process and display
    local processed
    processed=$(echo "$all_assignments" | jq --argjson groups "$group_names" '[.[] | {
        groupId: .groupId,
        groupName: ($groups[.groupId] // .groupId),
        principalId: .principalId,
        accessId: .accessId,
        startDateTime: .startDateTime,
        endDateTime: .endDateTime,
        assignmentType: .assignmentType
    }] | group_by(.groupName) | map({
        group: .[0].groupName,
        members: .
    }) | sort_by(.group)')

    while IFS= read -r group_data; do
        local group_name member_count
        group_name=$(echo "$group_data" | jq -r '.group')
        member_count=$(echo "$group_data" | jq '.members | length')

        gum style --bold --foreground 35 "$group_name ($member_count active)"

        while IFS= read -r member; do
            local principal_id access_id end_date assignment_type
            principal_id=$(echo "$member" | jq -r '.principalId')
            access_id=$(echo "$member" | jq -r '.accessId')
            end_date=$(echo "$member" | jq -r '.endDateTime // "Permanent"')
            assignment_type=$(echo "$member" | jq -r '.assignmentType // "Assigned"')

            local principal_name
            principal_name=$(resolve_user_name "$principal_id")

            local access_type="member"
            [[ "$access_id" == "owner" ]] && access_type="owner"

            local expiry_info=""
            if [[ "$end_date" != "Permanent" ]] && [[ "$end_date" != "null" ]]; then
                expiry_info=" (expires: ${end_date:0:10})"
            fi

            local type_color=252
            if [[ "$assignment_type" == "Activated" ]]; then
                type_color=214
            fi

            gum style --foreground "$type_color" "  - $principal_name [$access_type] [$assignment_type]$expiry_info"
        done < <(echo "$group_data" | jq -c '.members[]')

        echo ""
    done < <(echo "$processed" | jq -c '.[]')
}

#------------------------------------------------------------------------------
# Service Principal and App Registration Audit
#------------------------------------------------------------------------------

audit_service_principal_rbac() {
    print_header "Service Principal Azure RBAC Assignments"

    # Check if az CLI is available
    if ! command -v az &> /dev/null; then
        print_error "Azure CLI (az) is required for RBAC queries"
        return 1
    fi

    if ! az account show &> /dev/null; then
        print_error "Not logged in to Azure CLI. Please run: az login"
        return 1
    fi

    print_info "Fetching all service principal RBAC assignments..."

    local assignments
    assignments=$(gum spin --spinner dot --title "Querying Azure RBAC..." -- \
        bash -c "az role assignment list --all --query \"[?principalType=='ServicePrincipal']\" -o json 2>/dev/null")

    if [[ -z "$assignments" ]] || [[ "$assignments" == "[]" ]]; then
        print_warning "No service principal RBAC assignments found."
        return 0
    fi

    local count
    count=$(echo "$assignments" | jq 'length')
    gum style --foreground 252 "Found $count service principal RBAC assignment(s)"
    echo ""

    # Get unique principal IDs to resolve names
    local principal_ids
    principal_ids=$(echo "$assignments" | jq -r '[.[].principalId] | unique | .[]')

    local principal_count
    principal_count=$(echo "$principal_ids" | wc -l)

    # Build a map of principal ID to display name
    print_info "Resolving $principal_count service principal names..."
    declare -A sp_names
    declare -A sp_deleted

    local resolved=0
    while read -r sp_id; do
        [[ -z "$sp_id" ]] && continue
        resolved=$((resolved + 1))

        local sp_info
        sp_info=$(az ad sp show --id "$sp_id" --query '{displayName:displayName,appId:appId,servicePrincipalType:servicePrincipalType}' -o json 2>/dev/null || echo '{"error":true}')

        if echo "$sp_info" | jq -e '.error' &>/dev/null; then
            # SP doesn't exist - orphaned assignment
            sp_names[$sp_id]="[DELETED] $sp_id"
            sp_deleted[$sp_id]="true"
        else
            local display_name
            display_name=$(echo "$sp_info" | jq -r '.displayName // empty')
            if [[ -n "$display_name" ]]; then
                sp_names[$sp_id]="$display_name"
            else
                sp_names[$sp_id]="$sp_id"
            fi
        fi
    done <<< "$principal_ids"

    # Group by service principal
    local grouped
    grouped=$(echo "$assignments" | jq '[group_by(.principalId)[] | {
        principalId: .[0].principalId,
        principalName: .[0].principalName,
        assignments: [.[] | {
            role: .roleDefinitionName,
            scope: .scope
        }]
    }] | sort_by(.principalName)')

    # Display results
    while IFS= read -r sp_data; do
        local principal_id principal_name assignment_count is_deleted
        principal_id=$(echo "$sp_data" | jq -r '.principalId')
        principal_name="${sp_names[$principal_id]:-$(echo "$sp_data" | jq -r '.principalName // .principalId')}"
        assignment_count=$(echo "$sp_data" | jq '.assignments | length')
        is_deleted="${sp_deleted[$principal_id]:-false}"

        # Skip Microsoft first-party apps (optional - they clutter the output)
        if [[ "$principal_name" == "Microsoft"* ]] || [[ "$principal_name" == "Windows Azure"* ]] || [[ "$principal_name" == "Azure"* && "$principal_name" != *"Entra"* ]]; then
            continue
        fi

        # Show deleted SPs in red/warning color
        if [[ "$is_deleted" == "true" ]]; then
            gum style --bold --foreground 196 "$principal_name ($assignment_count role(s)) - ORPHANED"
        else
            gum style --bold --foreground 35 "$principal_name ($assignment_count role(s))"
        fi

        while IFS= read -r assignment; do
            local role_name scope_raw scope_display
            role_name=$(echo "$assignment" | jq -r '.role')
            scope_raw=$(echo "$assignment" | jq -r '.scope')

            # Parse scope to make it more readable
            if [[ "$scope_raw" == "/subscriptions/"* ]]; then
                local sub_id rg_name
                sub_id=$(echo "$scope_raw" | sed -n 's|/subscriptions/\([^/]*\).*|\1|p')

                if echo "$scope_raw" | grep -q "/resourceGroups/"; then
                    rg_name=$(echo "$scope_raw" | sed -n 's|.*/resourceGroups/\([^/]*\).*|\1|p')
                    if echo "$scope_raw" | grep -q "/providers/"; then
                        local resource_path
                        resource_path=$(echo "$scope_raw" | sed 's|.*/providers/||' | cut -d'/' -f1-3)
                        scope_display="RG:$rg_name/$resource_path"
                    else
                        scope_display="RG:$rg_name"
                    fi
                else
                    local sub_name
                    sub_name=$(az account show --subscription "$sub_id" --query name -o tsv 2>/dev/null || echo "${sub_id:0:8}...")
                    scope_display="Sub:$sub_name"
                fi
            elif [[ "$scope_raw" == "/providers/Microsoft.Management/managementGroups/"* ]]; then
                local mg_name
                mg_name=$(echo "$scope_raw" | sed 's|.*/managementGroups/||')
                scope_display="MG:$mg_name"
            else
                scope_display="$scope_raw"
            fi

            # Color code by role risk level
            local role_color=252
            case "$role_name" in
                "Owner"|"Contributor"|"User Access Administrator"|"Role Based Access Control Administrator")
                    role_color=196  # Red for high-privilege
                    ;;
                *"Admin"*|*"Contributor"*)
                    role_color=214  # Yellow for medium-privilege
                    ;;
            esac

            gum style --foreground "$role_color" "  - $role_name @ $scope_display"
        done < <(echo "$sp_data" | jq -c '.assignments[]')

        echo ""
    done < <(echo "$grouped" | jq -c '.[]')
}

audit_privileged_apps() {
    print_header "Privileged Application Permissions"

    local token
    token=$(get_graph_token) || return 1

    # Define high-privilege permissions to look for
    local high_priv_permissions=(
        "Application.ReadWrite.All"
        "Directory.ReadWrite.All"
        "RoleManagement.ReadWrite.Directory"
        "AppRoleAssignment.ReadWrite.All"
        "Group.ReadWrite.All"
        "User.ReadWrite.All"
        "Mail.ReadWrite"
        "Mail.Send"
        "Files.ReadWrite.All"
        "Sites.ReadWrite.All"
    )

    print_info "Scanning for applications with high-privilege permissions..."

    # Get all service principals with app role assignments
    local url="https://graph.microsoft.com/v1.0/servicePrincipals?\$select=id,displayName,appId,appRoles&\$top=999"

    local sps
    sps=$(gum spin --spinner dot --title "Fetching service principals..." -- \
        bash -c "curl -s -X GET -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' '$url'")

    if echo "$sps" | jq -e '.error' &>/dev/null; then
        local error_msg
        error_msg=$(echo "$sps" | jq -r '.error.message // "Unknown error"')
        print_error "Failed to fetch service principals: $error_msg"
        return 1
    fi

    # Get Microsoft Graph service principal for permission lookups
    local graph_sp
    graph_sp=$(graph_request GET "https://graph.microsoft.com/v1.0/servicePrincipals?\$filter=appId%20eq%20%2700000003-0000-0000-c000-000000000000%27&\$select=id,appRoles,oauth2PermissionScopes")
    local graph_sp_id
    graph_sp_id=$(echo "$graph_sp" | jq -r '.value[0].id')

    # Build permission ID to name map
    local permission_map
    permission_map=$(echo "$graph_sp" | jq '[.value[0].appRoles[] | {(.id): .value}] | add // {}')

    # Get app role assignments for each SP (this shows granted application permissions)
    gum style --foreground 252 "Analyzing application permissions..."
    echo ""

    local found_any=false

    while IFS= read -r sp; do
        local sp_id sp_name
        sp_id=$(echo "$sp" | jq -r '.id')
        sp_name=$(echo "$sp" | jq -r '.displayName')

        # Get app role assignments for this SP (application permissions granted TO this app)
        local assignments
        assignments=$(graph_request GET "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_id}/appRoleAssignments" 2>/dev/null)

        if [[ -z "$assignments" ]] || echo "$assignments" | jq -e '.error' &>/dev/null; then
            continue
        fi

        local high_priv_found=()

        while IFS= read -r assignment; do
            local app_role_id resource_id
            app_role_id=$(echo "$assignment" | jq -r '.appRoleId')
            resource_id=$(echo "$assignment" | jq -r '.resourceId')

            # Get permission name
            local perm_name
            perm_name=$(echo "$permission_map" | jq -r --arg id "$app_role_id" '.[$id] // empty')

            # Check if it's a high-privilege permission
            for high_priv in "${high_priv_permissions[@]}"; do
                if [[ "$perm_name" == "$high_priv" ]]; then
                    high_priv_found+=("$perm_name")
                    break
                fi
            done
        done < <(echo "$assignments" | jq -c '.value[] // empty' 2>/dev/null)

        if [[ ${#high_priv_found[@]} -gt 0 ]]; then
            found_any=true
            gum style --bold --foreground 214 "$sp_name"
            for perm in "${high_priv_found[@]}"; do
                gum style --foreground 196 "  ! $perm"
            done
            echo ""
        fi
    done < <(echo "$sps" | jq -c '.value[]')

    if [[ "$found_any" == "false" ]]; then
        print_success "No applications found with high-privilege permissions."
    fi
}

#------------------------------------------------------------------------------
# Summary Report
#------------------------------------------------------------------------------

generate_summary() {
    print_header "Audit Summary"

    local token
    token=$(get_graph_token) || return 1

    gum style --foreground 245 "Querying all PIM-enabled groups..."
    echo ""

    # Count directory role assignments
    local dir_roles dir_role_count
    dir_roles=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?\$count=true" 2>/dev/null)
    if echo "$dir_roles" | jq -e '.error' &>/dev/null; then
        gum style --foreground 252 "  Directory Role Assignments: (no permission)"
    else
        dir_role_count=$(echo "$dir_roles" | jq '.value | length // 0')
        gum style --foreground 252 "  Directory Role Assignments: $dir_role_count"
    fi

    # Count PIM role eligibilities
    local pim_eligible pim_eligible_count
    pim_eligible=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances" 2>/dev/null)
    if echo "$pim_eligible" | jq -e '.error' &>/dev/null; then
        gum style --foreground 252 "  PIM Role Eligibilities: (no permission)"
    else
        pim_eligible_count=$(echo "$pim_eligible" | jq '.value | length // 0')
        gum style --foreground 252 "  PIM Role Eligibilities: $pim_eligible_count"
    fi

    # Count PIM active role assignments
    local pim_active pim_active_count
    pim_active=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances" 2>/dev/null)
    if echo "$pim_active" | jq -e '.error' &>/dev/null; then
        gum style --foreground 252 "  PIM Active Role Assignments: (no permission)"
    else
        pim_active_count=$(echo "$pim_active" | jq '.value | length // 0')
        gum style --foreground 252 "  PIM Active Role Assignments: $pim_active_count"
    fi

    # Count PIM group eligibilities (query all groups)
    local pim_groups group_eligible_count=0 group_active_count=0
    pim_groups=$(get_pim_enabled_groups "$token")

    if [[ -n "$pim_groups" ]]; then
        while read -r group_id; do
            [[ -z "$group_id" ]] && continue
            local elig_result
            elig_result=$(curl -s -H "Authorization: Bearer $token" \
                "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" 2>/dev/null)
            local elig_cnt
            elig_cnt=$(echo "$elig_result" | jq '.value | length // 0')
            group_eligible_count=$((group_eligible_count + elig_cnt))

            local active_result
            active_result=$(curl -s -H "Authorization: Bearer $token" \
                "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" 2>/dev/null)
            local active_cnt
            active_cnt=$(echo "$active_result" | jq '.value | length // 0')
            group_active_count=$((group_active_count + active_cnt))
        done <<< "$pim_groups"
        gum style --foreground 252 "  PIM Group Eligibilities: $group_eligible_count (across $(echo "$pim_groups" | wc -l) groups)"
        gum style --foreground 252 "  PIM Group Active Assignments: $group_active_count"
    else
        gum style --foreground 252 "  PIM Group Eligibilities: (no groups found)"
        gum style --foreground 252 "  PIM Group Active Assignments: (no groups found)"
    fi

    echo ""
    gum style --foreground 245 "Audit completed at: $(date '+%Y-%m-%d %H:%M:%S')"
}

#------------------------------------------------------------------------------
# Export Functions
#------------------------------------------------------------------------------

export_json_report() {
    local output_file="${1:-$AUDIT_OUTPUT_DIR/entra-audit-$(date +%Y%m%d-%H%M%S).json}"

    mkdir -p "$(dirname "$output_file")"

    print_info "Generating JSON report..."

    local token
    token=$(get_graph_token) || return 1

    # Get current user ID for filtered queries
    local user_result user_id
    user_result=$(graph_request GET "https://graph.microsoft.com/v1.0/me?\$select=id,userPrincipalName")
    user_id=$(echo "$user_result" | jq -r '.id // empty')

    local report='{}'

    # Directory roles (may fail without permission)
    local dir_roles
    dir_roles=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments" 2>/dev/null)
    if echo "$dir_roles" | jq -e '.value' &>/dev/null; then
        report=$(echo "$report" | jq --argjson data "$dir_roles" '. + {directoryRoleAssignments: $data.value}')
    else
        report=$(echo "$report" | jq '. + {directoryRoleAssignments: []}')
    fi

    # PIM role eligibilities (may fail without permission)
    local pim_eligible
    pim_eligible=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances" 2>/dev/null)
    if echo "$pim_eligible" | jq -e '.value' &>/dev/null; then
        report=$(echo "$report" | jq --argjson data "$pim_eligible" '. + {pimRoleEligibilities: $data.value}')
    else
        report=$(echo "$report" | jq '. + {pimRoleEligibilities: []}')
    fi

    # PIM role active (may fail without permission)
    local pim_active
    pim_active=$(graph_request GET "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances" 2>/dev/null)
    if echo "$pim_active" | jq -e '.value' &>/dev/null; then
        report=$(echo "$report" | jq --argjson data "$pim_active" '. + {pimRoleActiveAssignments: $data.value}')
    else
        report=$(echo "$report" | jq '. + {pimRoleActiveAssignments: []}')
    fi

    # PIM group eligibilities (query all groups)
    local pim_groups all_group_eligibilities="[]" all_group_active="[]"
    pim_groups=$(get_pim_enabled_groups "$token")

    if [[ -n "$pim_groups" ]]; then
        while read -r group_id; do
            [[ -z "$group_id" ]] && continue

            local elig_result
            elig_result=$(curl -s -H "Authorization: Bearer $token" \
                "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/eligibilityScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" 2>/dev/null)
            if echo "$elig_result" | jq -e '.value' &>/dev/null; then
                all_group_eligibilities=$(echo "$all_group_eligibilities" "$(echo "$elig_result" | jq '.value')" | jq -s 'add')
            fi

            local active_result
            active_result=$(curl -s -H "Authorization: Bearer $token" \
                "https://graph.microsoft.com/v1.0/identityGovernance/privilegedAccess/group/assignmentScheduleInstances?\$filter=groupId%20eq%20%27${group_id}%27" 2>/dev/null)
            if echo "$active_result" | jq -e '.value' &>/dev/null; then
                all_group_active=$(echo "$all_group_active" "$(echo "$active_result" | jq '.value')" | jq -s 'add')
            fi
        done <<< "$pim_groups"
    fi

    report=$(echo "$report" | jq --argjson data "$all_group_eligibilities" '. + {pimGroupEligibilities: $data}')
    report=$(echo "$report" | jq --argjson data "$all_group_active" '. + {pimGroupActiveAssignments: $data}')

    # Add metadata
    local user_upn
    user_upn=$(echo "$user_result" | jq -r '.userPrincipalName // "unknown"')
    report=$(echo "$report" | jq --arg ts "$(date -Iseconds)" --arg uid "$user_id" --arg upn "$user_upn" '. + {
        metadata: {
            generatedAt: $ts,
            reportType: "entra-permissions-audit",
            userId: $uid,
            userPrincipalName: $upn
        }
    }')

    echo "$report" | jq '.' > "$output_file"

    print_success "Report saved to: $output_file"
}

#------------------------------------------------------------------------------
# Interactive Menu
#------------------------------------------------------------------------------

interactive_menu() {
    while true; do
        echo ""
        gum style --bold --foreground 212 "Entra ID Permissions Audit"
        echo ""

        local choice
        choice=$(gum choose \
            "Full Audit (all sections)" \
            "Directory Role Assignments" \
            "PIM Role Eligibilities" \
            "PIM Active Role Assignments" \
            "PIM Group Eligibilities" \
            "PIM Active Group Assignments" \
            "PIM Group RBAC Assignments" \
            "Service Principal RBAC" \
            "Privileged Graph Permissions" \
            "Summary" \
            "Export JSON Report" \
            "Exit")

        case "$choice" in
            "Full Audit (all sections)")
                audit_directory_roles
                audit_pim_role_eligibilities
                audit_pim_role_active_assignments
                audit_pim_group_eligibilities
                audit_pim_group_active_assignments
                audit_pim_group_rbac
                audit_service_principal_rbac
                audit_privileged_apps
                generate_summary
                ;;
            "Directory Role Assignments")
                audit_directory_roles
                ;;
            "PIM Role Eligibilities")
                audit_pim_role_eligibilities
                ;;
            "PIM Active Role Assignments")
                audit_pim_role_active_assignments
                ;;
            "PIM Group Eligibilities")
                audit_pim_group_eligibilities
                ;;
            "PIM Active Group Assignments")
                audit_pim_group_active_assignments
                ;;
            "PIM Group RBAC Assignments")
                audit_pim_group_rbac
                ;;
            "Service Principal RBAC")
                audit_service_principal_rbac
                ;;
            "Privileged Graph Permissions")
                audit_privileged_apps
                ;;
            "Summary")
                generate_summary
                ;;
            "Export JSON Report")
                export_json_report
                ;;
            "Exit")
                break
                ;;
        esac

        echo ""
        gum confirm "Continue?" || break
    done
}

#------------------------------------------------------------------------------
# Help and Usage
#------------------------------------------------------------------------------

show_help() {
    gum style --foreground 212 --bold '
███████╗███╗   ██╗████████╗██████╗  █████╗
██╔════╝████╗  ██║╚══██╔══╝██╔══██╗██╔══██╗
█████╗  ██╔██╗ ██║   ██║   ██████╔╝███████║
██╔══╝  ██║╚██╗██║   ██║   ██╔══██╗██╔══██║
███████╗██║ ╚████║   ██║   ██║  ██║██║  ██║
╚══════╝╚═╝  ╚═══╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝
 █████╗ ██╗   ██╗██████╗ ██╗████████╗
██╔══██╗██║   ██║██╔══██╗██║╚══██╔══╝
███████║██║   ██║██║  ██║██║   ██║
██╔══██║██║   ██║██║  ██║██║   ██║
██║  ██║╚██████╔╝██████╔╝██║   ██║
╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚═╝   ╚═╝'
    echo ""
    gum style --foreground 252 "Entra ID Permissions Audit Tool"
    echo ""
    gum style --bold --foreground 33 "USAGE:"
    echo "    entraling.sh [command]"
    echo ""
    gum style --bold --foreground 33 "SETUP (one-time):"
    echo "    setup           Create app registration for audit permissions"
    echo "    grant-consent   Grant admin consent for the app (requires admin)"
    echo "    login           Authenticate with the audit app"
    echo ""
    gum style --bold --foreground 33 "AUDIT COMMANDS:"
    echo "    (none)          Interactive menu"
    echo "    all             Run full audit (all sections)"
    echo "    roles           Audit directory role assignments"
    echo "    pim-roles       Audit PIM role eligibilities"
    echo "    pim-active      Audit PIM active role assignments"
    echo "    pim-groups      Audit PIM group eligibilities"
    echo "    pim-groups-active  Audit PIM active group assignments"
    echo "    pim-groups-rbac Audit Azure RBAC roles for PIM groups"
    echo "    sp-rbac        Audit service principal Azure RBAC roles"
    echo "    apps            Audit privileged Graph API permissions"
    echo "    summary         Show summary counts"
    echo "    export [file]   Export JSON report"
    echo "    help, h         Show this help message"
    echo ""
    gum style --bold --foreground 33 "FIRST-TIME SETUP:"
    echo "    1. entraling.sh setup         # Create app registration"
    echo "    2. entraling.sh grant-consent # Grant permissions (requires admin)"
    echo "    3. entraling.sh login         # Authenticate"
    echo ""
    gum style --bold --foreground 33 "EXAMPLES:"
    echo "    entraling.sh              # Interactive mode"
    echo "    entraling.sh all          # Full audit"
    echo "    entraling.sh pim-roles    # Just PIM role eligibilities"
    echo "    entraling.sh export       # Export to JSON"
}

#------------------------------------------------------------------------------
# Main Entry Point
#------------------------------------------------------------------------------

main() {
    check_dependencies

    local command="${1:-}"

    case "$command" in
        "")
            interactive_menu
            ;;
        setup)
            setup_app_registration
            ;;
        grant-consent)
            grant_admin_consent
            ;;
        login)
            do_device_code_login
            ;;
        all)
            audit_directory_roles
            audit_pim_role_eligibilities
            audit_pim_role_active_assignments
            audit_pim_group_eligibilities
            audit_pim_group_active_assignments
            audit_pim_group_rbac
            audit_service_principal_rbac
            audit_privileged_apps
            generate_summary
            ;;
        roles)
            audit_directory_roles
            ;;
        pim-roles)
            audit_pim_role_eligibilities
            ;;
        pim-active)
            audit_pim_role_active_assignments
            ;;
        pim-groups)
            audit_pim_group_eligibilities
            ;;
        pim-groups-active)
            audit_pim_group_active_assignments
            ;;
        pim-groups-rbac)
            audit_pim_group_rbac
            ;;
        sp-rbac)
            audit_service_principal_rbac
            ;;
        apps)
            audit_privileged_apps
            ;;
        summary)
            generate_summary
            ;;
        export)
            export_json_report "${2:-}"
            ;;
        help|h|--help|-h)
            show_help
            ;;
        *)
            print_error "Unknown command: $command"
            show_help
            exit 1
            ;;
    esac
}

main "$@"

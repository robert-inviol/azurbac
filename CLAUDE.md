# Azure RBAC Audit Toolkit

Tools for auditing Azure/Entra ID permissions, role assignments, and PIM (Privileged Identity Management) configurations.

## Project Structure

```
azurbac/
├── azurbac.sh         # Sync Azure/Entra resources to filesystem for git tracking
├── entraling.sh       # Interactive Entra ID permissions audit tool (Entra Trawling)
├── .devcontainer/     # Dev container config (Debian with az cli, gh cli, gum, jq)
└── azure/             # Generated directory structure (created by azurbac.sh)
```

## Scripts

### azurbac.sh

Syncs Azure and Entra ID resources to a filesystem structure for git-based tracking.

**Usage:**
```bash
./azurbac.sh [command] [--dir PATH]
```

**Commands:**
- `sync` (default) - Full sync of all resources
- `users` - Sync only Entra users
- `groups` - Sync only Entra groups
- `sps` - Sync only service principals
- `subs` - Sync subscriptions and resource groups
- `resources` - Sync Azure resources
- `rbac` - Sync RBAC assignments
- `pim` - Sync PIM eligibilities

**Output Structure:**
```
azure/
├── entra/
│   ├── users/{Guest|Member}/{displayName}/___<id>.json
│   ├── groups/{displayName}/___<id>.json
│   │   └── members/{memberName} -> symlink to ___guid.json
│   ├── service_principals/{Type}/{displayName}/___<id>.json
│   └── pim/groups/{groupName}/
├── subscriptions/{name}/___<id>.json
│   ├── resource_groups/{name}/___<name>.json
│   │   ├── roles/{roleName}/{principalName} -> symlink
│   │   └── resources/{name}/___<guid>.json
│   ├── resource_types/{type}/{resourceName} -> symlink
│   └── resource_regions/{location}/{resourceName} -> symlink
```

### entraling.sh

Interactive audit tool for Entra ID permissions with PIM support. Name is a play on "Entra Trawling".

**Setup (one-time):**
```bash
./entraling.sh setup         # Create app registration
./entraling.sh grant-consent # Grant permissions (requires admin)
./entraling.sh login         # Authenticate
```

**Audit Commands:**
```bash
./entraling.sh              # Interactive menu
./entraling.sh all          # Full audit
./entraling.sh roles        # Directory role assignments
./entraling.sh pim-roles    # PIM role eligibilities
./entraling.sh pim-active   # PIM active role assignments
./entraling.sh pim-groups   # PIM group eligibilities
./entraling.sh sp-rbac      # Service principal RBAC
./entraling.sh apps         # Privileged Graph API permissions
./entraling.sh export       # Export JSON report
```

## Dependencies

- `az` - Azure CLI (must be logged in)
- `jq` - JSON processor
- `gum` - Terminal UI toolkit (entraling.sh only)

## Development

The `.devcontainer` configuration provides a ready-to-use environment with all dependencies pre-installed.

## Environment Variables

For `azurbac.sh`:
- `AZURE_DIR` - Base directory (default: ./azure)
- `SYNC_USERS`, `SYNC_GROUPS`, `SYNC_SERVICE_PRINCIPALS`, `SYNC_SUBSCRIPTIONS`, `SYNC_RBAC`, `SYNC_RESOURCES` - Enable/disable specific sync operations (default: true)

## Common Tasks

**Full Azure sync:**
```bash
./azurbac.sh sync
```

**Run audit and export:**
```bash
./entraling.sh all
./entraling.sh export ./reports/audit.json
```

**Check specific PIM eligibilities:**
```bash
./entraling.sh pim-groups
```

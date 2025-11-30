# azurbac

> **/əˈzɜːbɪk/** - *adjective* - sharp and forthright in revealing the bitter truth about your Azure permissions

GitOps for Azure security. Because "who has access to what" shouldn't require a séance.

## What is this?

Turn your sprawling Azure/Entra ID permissions into a git-trackable filesystem. Users, groups, roles, RBAC assignments, PIM eligibilities - all dumped into folders and symlinks you can actually `grep`, `diff`, and commit.

```
azure/
├── entra/
│   ├── users/Member/Alice/___<guid>.json
│   ├── groups/Platform-Admins/___<guid>.json
│   │   └── members/Alice -> ../../users/Member/Alice/___<guid>.json
│   └── service_principals/Application/my-app/___<guid>.json
└── subscriptions/Production/
    └── resource_groups/rg-core/
        └── roles/Contributor/
            └── Platform-Admins -> ../../../../entra/groups/Platform-Admins/___<guid>.json
```

Now you can answer "who can delete prod?" with `find` instead of clicking through 47 Azure Portal blades.

## Tools

| Script | Purpose |
|--------|---------|
| `azurbac.sh` | Dump Azure resources to filesystem |
| `entrauling.sh` | Trawl Entra ID for permissions audit |

## Quick Start

```bash
# Sync everything to ./azure
az login
./azurbac.sh

# Commit your permissions baseline
git add azure/
git commit -m "Azure permissions snapshot $(date +%Y-%m-%d)"

# Interactive Entra audit (requires one-time setup)
./entrauling.sh setup && ./entrauling.sh login
./entrauling.sh
```

## Requirements

- `az` CLI (logged in)
- `jq`
- `gum` (for entrauling.sh interactive mode)

## Why?

- **Audit trails**: `git log` shows who changed what permissions, when
- **Code review for access**: PR your permission changes
- **Grep your IAM**: `grep -r "Owner" azure/` finds all Owner assignments
- **Diff environments**: Compare prod vs staging permissions
- **Detect drift**: Scheduled sync + git diff = instant alerts

## License

MIT

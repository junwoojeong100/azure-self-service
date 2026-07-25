#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/offboard-business-user.sh \
    --subscription-id <subscription-id> \
    --platform-resource-group <platform-resource-group> \
    --resource-group <business-user-resource-group> \
    [--acr-name <shared-registry-name>] \
    [--repository-name <acr-repository>] \
    [--github-repository <owner/repository>] \
    [--business-owner <user-principal-name>] \
    [--delete-resource-group]

Run by IT. In the shared platform model, deleting the business user resource
group is not enough: role assignments and registry content live in the platform
resource group and survive that deletion. This script removes them in order and
prints anything that still needs a manual decision.

Nothing is deleted unless --delete-resource-group is passed; without it the
script reports what it would remove.
EOF
}

subscription_id=""
platform_resource_group=""
resource_group=""
acr_name=""
repository_name=""
github_repository=""
business_owner=""
delete_resource_group="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) subscription_id="$2"; shift 2 ;;
    --platform-resource-group) platform_resource_group="$2"; shift 2 ;;
    --resource-group) resource_group="$2"; shift 2 ;;
    --acr-name) acr_name="$2"; shift 2 ;;
    --repository-name) repository_name="$2"; shift 2 ;;
    --github-repository) github_repository="$2"; shift 2 ;;
    --business-owner) business_owner="$2"; shift 2 ;;
    --delete-resource-group) delete_resource_group="true"; shift ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$subscription_id" || -z "$platform_resource_group" || -z "$resource_group" ]]; then
  usage
  exit 1
fi

az account set --subscription "$subscription_id"

dry_run_note=""
if [[ "$delete_resource_group" != "true" ]]; then
  dry_run_note="  (dry run, nothing removed)"
fi

echo "Offboarding ${resource_group}${dry_run_note}"
echo

# Step 1: collect the principal IDs before they disappear with the resource group.
principal_ids=()
while IFS= read -r principal_id; do
  [[ -n "$principal_id" ]] && principal_ids+=("$principal_id")
done < <(az identity list --resource-group "$resource_group" --query "[].principalId" --output tsv 2>/dev/null || true)

while IFS= read -r principal_id; do
  [[ -n "$principal_id" && "$principal_id" != "None" ]] && principal_ids+=("$principal_id")
done < <(az containerapp list --resource-group "$resource_group" --query "[].identity.principalId" --output tsv 2>/dev/null || true)

if [[ ${#principal_ids[@]} -eq 0 ]]; then
  echo "1. No managed identities found in ${resource_group}."
else
  echo "1. Managed identities to revoke: ${#principal_ids[@]}"
  printf '     %s\n' "${principal_ids[@]}"
fi
echo

# Step 2: remove role assignments held in the platform resource group. These are
# scoped to the shared registry and environment, so deleting the business user
# resource group would leave them behind as orphaned assignments.
#
# Assignments live on child resources of the platform resource group, and
# "az role assignment list --scope <resource-group>" does not return those. The
# assignee must be listed with --all and filtered by scope prefix instead.
platform_scope_prefix="$(printf '/subscriptions/%s/resourcegroups/%s/' "$subscription_id" "$platform_resource_group" | tr '[:upper:]' '[:lower:]')"
removed_assignments=0
for principal_id in "${principal_ids[@]:-}"; do
  [[ -z "$principal_id" ]] && continue
  while IFS=$'\t' read -r assignment_id assignment_scope; do
    [[ -z "$assignment_id" || -z "$assignment_scope" ]] && continue
    lowered_scope="$(printf '%s' "$assignment_scope" | tr '[:upper:]' '[:lower:]')"
    [[ "$lowered_scope" == "${platform_scope_prefix}"* ]] || continue
    echo "2. ${assignment_scope##*/providers/}"
    if [[ "$delete_resource_group" == "true" ]]; then
      az role assignment delete --ids "$assignment_id" --output none
    fi
    removed_assignments=$((removed_assignments + 1))
  done < <(az role assignment list \
    --assignee "$principal_id" \
    --all \
    --query "[].[id,scope]" \
    --output tsv 2>/dev/null || true)
done
if [[ "$removed_assignments" -eq 0 ]]; then
  echo "2. No platform scoped role assignments found."
fi
echo

# Step 3: delete this user's repository from the shared registry. Registry content
# is not part of the business user resource group.
if [[ -z "$acr_name" ]]; then
  discovered_registries=()
  while IFS= read -r registry_name; do
    [[ -n "$registry_name" ]] && discovered_registries+=("$registry_name")
  done < <(az acr list --resource-group "$platform_resource_group" --query "[].name" --output tsv 2>/dev/null || true)

  if [[ ${#discovered_registries[@]} -eq 1 ]]; then
    acr_name="${discovered_registries[0]}"
  elif [[ ${#discovered_registries[@]} -gt 1 ]]; then
    echo "Multiple registries found in ${platform_resource_group}: ${discovered_registries[*]}" >&2
    echo "Pass --acr-name to choose the one that holds this user's repository." >&2
    exit 1
  fi
fi

if [[ -z "$repository_name" ]]; then
  repository_name="$(printf '%s' "$resource_group" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')/business-app"
fi

if [[ -z "$acr_name" ]]; then
  echo "3. No registry found in ${platform_resource_group}; skipping repository cleanup."
elif az acr repository show --name "$acr_name" --repository "$repository_name" --output none 2>/dev/null; then
  echo "3. Repository ${acr_name}/${repository_name}"
  if [[ "$delete_resource_group" == "true" ]]; then
    az acr repository delete --name "$acr_name" --repository "$repository_name" --yes --output none
  fi
else
  echo "3. Repository ${repository_name} not present in ${acr_name}."
fi
echo

# Step 4: remove the direct role assignment the business user holds on their own
# resource group, so access stops even if the group is retained for audit.
if [[ -n "$business_owner" ]]; then
  assignee_id="$(az ad user show --id "$business_owner" --query id --output tsv 2>/dev/null || true)"
  user_scope="/subscriptions/${subscription_id}/resourceGroups/${resource_group}"
  if [[ -n "$assignee_id" ]]; then
    echo "4. Direct role assignments for ${business_owner} at ${user_scope}"
    if [[ "$delete_resource_group" == "true" ]]; then
      while IFS= read -r assignment_id; do
        [[ -z "$assignment_id" ]] && continue
        az role assignment delete --ids "$assignment_id" --output none
      done < <(az role assignment list --assignee "$assignee_id" --scope "$user_scope" --query "[].id" --output tsv 2>/dev/null || true)
    fi
  else
    echo "4. Cannot resolve ${business_owner} in Microsoft Entra ID."
  fi
else
  echo "4. No --business-owner supplied; skipping direct role assignment cleanup."
fi
echo

# Step 5: delete the business user resource group itself.
if az group exists --name "$resource_group" | grep -q true; then
  echo "5. Resource group ${resource_group}"
  if [[ "$delete_resource_group" == "true" ]]; then
    az group delete --name "$resource_group" --yes --no-wait --output none
    echo "     deletion started"
  fi
else
  echo "5. Resource group ${resource_group} does not exist."
fi
echo

if [[ -n "$github_repository" ]]; then
  cat <<EOF
GitHub cleanup still required for ${github_repository}:
  gh variable delete AZURE_CLIENT_ID --env production --repo ${github_repository}
  gh api -X DELETE repos/${github_repository}/environments/production
EOF
  echo
fi

cat <<'EOF'
Manual decisions that this script deliberately does not make:

  - Queues, topics and databases that this user owned inside shared instances.
    They are child resources of a platform resource and are never removed by
    deleting the business user resource group. See docs/RESOURCE_ISOLATION_GUIDE.md.
  - Log Analytics data retention for the removed app.
  - Cost exports and budgets that referenced the deleted resource group.
EOF

if [[ "$delete_resource_group" != "true" ]]; then
  echo
  echo "Dry run complete. Re-run with --delete-resource-group to apply."
fi

#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/assign-resource-group-owner.sh \
    --subscription-id <subscription-id> \
    --resource-group <business-user-resource-group> \
    --business-owner <user-principal-name>

Run by IT. Assigns Owner only at the specified resource group scope.
EOF
}

subscription_id=""
resource_group=""
business_owner=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) subscription_id="$2"; shift 2 ;;
    --resource-group) resource_group="$2"; shift 2 ;;
    --business-owner) business_owner="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$subscription_id" || -z "$resource_group" || -z "$business_owner" ]]; then
  usage
  exit 1
fi

az account set --subscription "$subscription_id"
scope="/subscriptions/${subscription_id}/resourceGroups/${resource_group}"
assignee_id="$(az ad user show --id "$business_owner" --query id --output tsv)"
existing_assignments="$(az role assignment list \
  --assignee "$assignee_id" \
  --role "Owner" \
  --scope "$scope" \
  --query 'length(@)' \
  --output tsv)"

if [[ "$existing_assignments" == "0" ]]; then
  az role assignment create \
    --assignee "$assignee_id" \
    --role "Owner" \
    --scope "$scope" \
    --output none
fi

echo "Owner access confirmed for ${business_owner} at ${scope}"

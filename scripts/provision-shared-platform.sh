#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/provision-shared-platform.sh \
    --subscription-id <subscription-id> \
    --platform-resource-group <platform-resource-group> \
    --location <azure-region> \
    [--acr-name <globally-unique-acr-name>]

Run once by IT. Creates the shared platform resource group that holds the
Container Apps environment, the ABAC-enabled container registry and the Log
Analytics workspace. Business users never receive a role on this resource group.
EOF
}

subscription_id=""
platform_resource_group=""
location=""
acr_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) subscription_id="$2"; shift 2 ;;
    --platform-resource-group) platform_resource_group="$2"; shift 2 ;;
    --location) location="$2"; shift 2 ;;
    --acr-name) acr_name="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$subscription_id" || -z "$platform_resource_group" || -z "$location" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

environment_name="cae-${platform_resource_group}"

if [[ -z "$acr_name" ]]; then
  safe_name="$(printf '%s' "$platform_resource_group" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  unique_suffix="$(printf '%s' "${subscription_id}-${platform_resource_group}" | shasum | cut -c1-8)"
  acr_name="$(printf 'acr%s%s' "${safe_name:0:28}" "$unique_suffix" | cut -c1-50)"
fi

az account set --subscription "$subscription_id"
az extension add --name containerapp --upgrade --only-show-errors

az group create \
  --name "$platform_resource_group" \
  --location "$location" \
  --tags CostCenter=platform Environment=shared Application=business-app-platform \
  --output none

az deployment group create \
  --resource-group "$platform_resource_group" \
  --name "platform-$(date -u +%Y%m%d%H%M%S)" \
  --template-file "${repo_root}/infra/platform.bicep" \
  --parameters \
    containerAppsEnvironmentName="$environment_name" \
    acrName="$acr_name" \
  --output none

role_assignment_mode="$(az acr show --name "$acr_name" --resource-group "$platform_resource_group" --query roleAssignmentMode --output tsv 2>/dev/null || true)"
if [[ "$role_assignment_mode" != "AbacRepositoryPermissions" ]]; then
  echo "Registry ${acr_name} is not in ABAC mode (found '${role_assignment_mode}'). Repository level isolation would silently become registry wide." >&2
  exit 1
fi

environment_id="$(az containerapp env show --name "$environment_name" --resource-group "$platform_resource_group" --query id --output tsv)"
acr_login_server="$(az acr show --name "$acr_name" --resource-group "$platform_resource_group" --query loginServer --output tsv)"

cat <<EOF

Shared platform is ready.

  PLATFORM_RESOURCE_GROUP=${platform_resource_group}
  CONTAINER_APPS_ENVIRONMENT=${environment_name}
  CONTAINER_APPS_ENVIRONMENT_ID=${environment_id}
  ACR_NAME=${acr_name}
  ACR_LOGIN_SERVER=${acr_login_server}
  ACR_ROLE_ASSIGNMENT_MODE=${role_assignment_mode}

Next, onboard one business user per resource group:

  ./scripts/provision-user-workload.sh \\
    --subscription-id ${subscription_id} \\
    --platform-resource-group ${platform_resource_group} \\
    --resource-group rg-sales-jiyoon-dev \\
    --location ${location} \\
    --github-repository <owner/repository>
EOF

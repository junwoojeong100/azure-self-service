#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/provision-team-environment.sh \
    --subscription-id <subscription-id> \
    --resource-group <team-resource-group> \
    --location <azure-region> \
    --github-repository <owner/repository>

Run this script as the Owner of the target resource group. It provisions one
isolated app environment and trusts only the GitHub Actions "production"
environment of the specified repository.
EOF
}

subscription_id=""
resource_group=""
location=""
github_repository=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) subscription_id="$2"; shift 2 ;;
    --resource-group) resource_group="$2"; shift 2 ;;
    --location) location="$2"; shift 2 ;;
    --github-repository) github_repository="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$subscription_id" || -z "$resource_group" || -z "$location" || -z "$github_repository" ]]; then
  usage
  exit 1
fi

if ! [[ "$github_repository" =~ ^[^/]+/[^/]+$ ]]; then
  echo "--github-repository must be in owner/repository form." >&2
  exit 1
fi

safe_name="$(printf '%s' "$resource_group" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
unique_suffix="$(printf '%s' "${subscription_id}-${resource_group}" | shasum | cut -c1-8)"
acr_name="$(printf 'acr%s%s' "${safe_name:0:28}" "$unique_suffix" | cut -c1-50)"
environment_name="cae-${resource_group}"
app_name="business-app"
identity_name="id-gha-deploy"

az account set --subscription "$subscription_id"
az extension add --name containerapp --upgrade --only-show-errors
az group create --name "$resource_group" --location "$location" --output none

az deployment group create \
  --resource-group "$resource_group" \
  --template-file infra/main.bicep \
  --parameters \
    acrName="$acr_name" \
    containerAppsEnvironmentName="$environment_name" \
    containerAppName="$app_name" \
    deploymentIdentityName="$identity_name" \
  --output none

identity_client_id="$(az identity show --name "$identity_name" --resource-group "$resource_group" --query clientId --output tsv)"
az identity federated-credential create \
  --name github-production \
  --identity-name "$identity_name" \
  --resource-group "$resource_group" \
  --issuer "https://token.actions.githubusercontent.com" \
  --subject "repo:${github_repository}:environment:production" \
  --audiences "api://AzureADTokenExchange" \
  --output none

az containerapp registry set \
  --name "$app_name" \
  --resource-group "$resource_group" \
  --server "${acr_name}.azurecr.io" \
  --identity system \
  --output none

tenant_id="$(az account show --query tenantId --output tsv)"
container_app_url="$(az containerapp show --name "$app_name" --resource-group "$resource_group" --query properties.configuration.ingress.fqdn --output tsv)"

cat <<EOF

Provisioning succeeded.

Create the GitHub "production" environment, then set these environment variables:
  AZURE_CLIENT_ID=${identity_client_id}
  AZURE_TENANT_ID=${tenant_id}
  AZURE_SUBSCRIPTION_ID=${subscription_id}
  AZURE_RESOURCE_GROUP=${resource_group}
  AZURE_CONTAINER_REGISTRY_NAME=${acr_name}
  AZURE_CONTAINER_APP_NAME=${app_name}

Bootstrap URL: https://${container_app_url}
EOF

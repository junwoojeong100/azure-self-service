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

if ! command -v gh >/dev/null 2>&1; then
  echo "GitHub CLI (gh) is required to configure production environment variables." >&2
  exit 1
fi

if ! gh repo view "$github_repository" --json nameWithOwner >/dev/null; then
  echo "Cannot access GitHub repository ${github_repository}. Authenticate gh with repository admin access." >&2
  exit 1
fi

if ! gh api "repos/${github_repository}/environments/production" --silent >/dev/null; then
  echo "GitHub production environment is missing. Create and protect it before provisioning." >&2
  exit 1
fi

github_oidc_subject_prefix="$(gh api "repos/${github_repository}/actions/oidc/customization/sub" --jq .sub_claim_prefix)"
if [[ -z "$github_oidc_subject_prefix" || "$github_oidc_subject_prefix" == "null" ]]; then
  echo "Cannot determine the GitHub OIDC subject prefix for ${github_repository}." >&2
  exit 1
fi

safe_name="$(printf '%s' "$resource_group" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
unique_suffix="$(printf '%s' "${subscription_id}-${resource_group}" | shasum | cut -c1-8)"
acr_name="$(printf 'acr%s%s' "${safe_name:0:28}" "$unique_suffix" | cut -c1-50)"
environment_name="cae-${resource_group}"
app_name="business-app"
identity_name="id-gha-deploy"
federated_credential_name="github-production"
federated_subject="${github_oidc_subject_prefix}:environment:production"

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
existing_subject="$(az identity federated-credential show \
  --name "$federated_credential_name" \
  --identity-name "$identity_name" \
  --resource-group "$resource_group" \
  --query subject \
  --output tsv 2>/dev/null || true)"

if [[ -z "$existing_subject" ]]; then
  az identity federated-credential create \
    --name "$federated_credential_name" \
    --identity-name "$identity_name" \
    --resource-group "$resource_group" \
    --issuer "https://token.actions.githubusercontent.com" \
    --subject "$federated_subject" \
    --audiences "api://AzureADTokenExchange" \
    --output none
elif [[ "$existing_subject" != "$federated_subject" ]]; then
  echo "Existing GitHub federated credential trusts ${existing_subject}, not ${federated_subject}." >&2
  exit 1
fi

az containerapp registry set \
  --name "$app_name" \
  --resource-group "$resource_group" \
  --server "${acr_name}.azurecr.io" \
  --identity system \
  --output none

tenant_id="$(az account show --query tenantId --output tsv)"
container_app_url="$(az containerapp show --name "$app_name" --resource-group "$resource_group" --query properties.configuration.ingress.fqdn --output tsv)"

gh variable set AZURE_CLIENT_ID --env production --repo "$github_repository" --body "$identity_client_id"
gh variable set AZURE_TENANT_ID --env production --repo "$github_repository" --body "$tenant_id"
gh variable set AZURE_SUBSCRIPTION_ID --env production --repo "$github_repository" --body "$subscription_id"
gh variable set AZURE_RESOURCE_GROUP --env production --repo "$github_repository" --body "$resource_group"
gh variable set AZURE_CONTAINER_REGISTRY_NAME --env production --repo "$github_repository" --body "$acr_name"
gh variable set AZURE_CONTAINER_APP_NAME --env production --repo "$github_repository" --body "$app_name"

cat <<EOF

Provisioning succeeded.

The GitHub "production" environment variables were configured:
  AZURE_CLIENT_ID=${identity_client_id}
  AZURE_TENANT_ID=${tenant_id}
  AZURE_SUBSCRIPTION_ID=${subscription_id}
  AZURE_RESOURCE_GROUP=${resource_group}
  AZURE_CONTAINER_REGISTRY_NAME=${acr_name}
  AZURE_CONTAINER_APP_NAME=${app_name}

Bootstrap URL: https://${container_app_url}
EOF

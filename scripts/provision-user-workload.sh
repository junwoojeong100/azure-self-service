#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./scripts/provision-user-workload.sh \
    --subscription-id <subscription-id> \
    --platform-resource-group <platform-resource-group> \
    --resource-group <business-user-resource-group> \
    --location <azure-region> \
    --github-repository <owner/repository> \
    [--acr-name <shared-registry-name>] \
    [--environment-name <shared-environment-name>] \
    [--repository-name <acr-repository>] \
    [--max-replicas <count>]

Run by IT after ./scripts/provision-shared-platform.sh. Creates the business user
workload in an existing resource group, places one container app in the shared
Container Apps environment, and grants that user access to exactly one repository
of the shared registry.

The caller needs Contributor and Role Based Access Control Administrator on the
business user resource group, plus Role Based Access Control Administrator on the
platform resource group.
EOF
}

subscription_id=""
platform_resource_group=""
resource_group=""
location=""
github_repository=""
repository_name=""
acr_name=""
environment_name=""
max_replicas="2"
discovered_environments=()
discovered_registries=()

ensure_role_assignment() {
  local principal_id="$1"
  local role_id="$2"
  local role_name="$3"
  local scope="$4"
  local condition="$5"
  local description="$6"
  local existing_assignment
  local existing_id
  local existing_condition
  local normalized_condition
  local normalized_existing_condition
  local role_args

  existing_assignment="$(az role assignment list \
    --scope "$scope" \
    --query "[?principalId=='${principal_id}' && roleDefinitionName=='${role_name}'] | [0].[id, condition]" \
    --output tsv 2>/dev/null || true)"

  existing_id="$(printf '%s' "$existing_assignment" | cut -f1)"
  existing_condition="$(printf '%s' "$existing_assignment" | cut -f2-)"
  normalized_condition="$(printf '%s' "$condition" | tr -d '[:space:]')"
  normalized_existing_condition="$(printf '%s' "$existing_condition" | tr -d '[:space:]')"

  if [[ -n "$existing_id" ]]; then
    if [[ -n "$condition" && "$normalized_existing_condition" != "$normalized_condition" ]]; then
      echo "Existing ${role_name} assignment at ${scope} has an unexpected condition." >&2
      exit 1
    fi
    return
  fi

  role_args=(
    az role assignment create
    --assignee-object-id "$principal_id"
    --assignee-principal-type ServicePrincipal
    --role "$role_id"
    --scope "$scope"
    --description "$description"
    --output none
  )

  if [[ -n "$condition" ]]; then
    role_args+=(--condition "$condition" --condition-version "2.0")
  fi

  "${role_args[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) subscription_id="$2"; shift 2 ;;
    --platform-resource-group) platform_resource_group="$2"; shift 2 ;;
    --resource-group) resource_group="$2"; shift 2 ;;
    --location) location="$2"; shift 2 ;;
    --github-repository) github_repository="$2"; shift 2 ;;
    --acr-name) acr_name="$2"; shift 2 ;;
    --environment-name) environment_name="$2"; shift 2 ;;
    --repository-name) repository_name="$2"; shift 2 ;;
    --max-replicas) max_replicas="$2"; shift 2 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$subscription_id" || -z "$platform_resource_group" || -z "$resource_group" || -z "$location" || -z "$github_repository" ]]; then
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

app_name="business-app"
identity_name="id-gha-deploy"
federated_credential_name="github-production"

# One repository per business user. Everything before the slash is the isolation
# key used by the ABAC condition on the shared registry.
if [[ -z "$repository_name" ]]; then
  repository_name="$(printf '%s' "$resource_group" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')/${app_name}"
fi

az account set --subscription "$subscription_id"
az extension add --name containerapp --upgrade --only-show-errors

if ! az group show --name "$resource_group" --output none 2>/dev/null; then
  echo "Resource group ${resource_group} does not exist. Create it and assign the business owner before running this script." >&2
  exit 1
fi

resource_group_location="$(az group show --name "$resource_group" --query location --output tsv)"
normalized_resource_group_location="$(printf '%s' "$resource_group_location" | tr '[:upper:]' '[:lower:]')"
normalized_location="$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')"
if [[ "$normalized_resource_group_location" != "$normalized_location" ]]; then
  echo "Resource group ${resource_group} is in ${resource_group_location}, not ${location}." >&2
  exit 1
fi

if [[ -z "$environment_name" ]]; then
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && discovered_environments+=("$candidate")
  done < <(az containerapp env list --resource-group "$platform_resource_group" --query "[].name" --output tsv 2>/dev/null || true)

  if [[ ${#discovered_environments[@]} -eq 0 ]]; then
    echo "No Container Apps environment found in ${platform_resource_group}. Run ./scripts/provision-shared-platform.sh first." >&2
    exit 1
  elif [[ ${#discovered_environments[@]} -gt 1 ]]; then
    echo "Multiple Container Apps environments found in ${platform_resource_group}: ${discovered_environments[*]}" >&2
    echo "Pass --environment-name to choose one." >&2
    exit 1
  fi
  environment_name="${discovered_environments[0]}"
fi

environment_id="$(az containerapp env show --name "$environment_name" --resource-group "$platform_resource_group" --query id --output tsv)"

if [[ -z "$acr_name" ]]; then
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] && discovered_registries+=("$candidate")
  done < <(az acr list --resource-group "$platform_resource_group" --query "[].name" --output tsv 2>/dev/null || true)

  if [[ ${#discovered_registries[@]} -eq 0 ]]; then
    echo "No container registry found in ${platform_resource_group}." >&2
    exit 1
  elif [[ ${#discovered_registries[@]} -gt 1 ]]; then
    echo "Multiple container registries found in ${platform_resource_group}: ${discovered_registries[*]}" >&2
    echo "Pass --acr-name to choose one." >&2
    exit 1
  fi
  acr_name="${discovered_registries[0]}"
fi

acr_login_server="$(az acr show --name "$acr_name" --resource-group "$platform_resource_group" --query loginServer --output tsv)"
role_assignment_mode="$(az acr show --name "$acr_name" --resource-group "$platform_resource_group" --query roleAssignmentMode --output tsv 2>/dev/null || true)"
if [[ "$role_assignment_mode" != "AbacRepositoryPermissions" ]]; then
  echo "Registry ${acr_name} is not in ABAC mode. Repository scoped role assignments would grant registry wide access." >&2
  exit 1
fi

github_oidc_subject_prefix="$(gh api "repos/${github_repository}/actions/oidc/customization/sub" --jq .sub_claim_prefix)"
if [[ -z "$github_oidc_subject_prefix" || "$github_oidc_subject_prefix" == "null" ]]; then
  echo "Cannot determine the GitHub OIDC subject prefix for ${github_repository}." >&2
  exit 1
fi
federated_subject="${github_oidc_subject_prefix}:environment:production"

create_container_app="true"
if az containerapp show --name "$app_name" --resource-group "$resource_group" --output none 2>/dev/null; then
  existing_environment_id="$(az containerapp show \
    --name "$app_name" \
    --resource-group "$resource_group" \
    --query properties.managedEnvironmentId \
    --output tsv)"
  normalized_existing_environment_id="$(printf '%s' "$existing_environment_id" | tr '[:upper:]' '[:lower:]')"
  normalized_environment_id="$(printf '%s' "$environment_id" | tr '[:upper:]' '[:lower:]')"
  if [[ "$normalized_existing_environment_id" != "$normalized_environment_id" ]]; then
    echo "Container app ${app_name} already uses a different Container Apps environment." >&2
    exit 1
  fi
  create_container_app="false"
  echo "Container app ${app_name} already exists; preserving its current revision template."
fi

az deployment group create \
  --resource-group "$resource_group" \
  --name "user-workload-$(date -u +%Y%m%d%H%M%S)" \
  --template-file "${repo_root}/infra/user-workload.bicep" \
  --parameters \
    containerAppsEnvironmentId="$environment_id" \
    acrLoginServer="$acr_login_server" \
    repositoryName="$repository_name" \
    containerAppName="$app_name" \
    deploymentIdentityName="$identity_name" \
    maxReplicas="$max_replicas" \
    createContainerApp="$create_container_app" \
  --output none

identity_client_id="$(az identity show --name "$identity_name" --resource-group "$resource_group" --query clientId --output tsv)"
identity_principal_id="$(az identity show --name "$identity_name" --resource-group "$resource_group" --query principalId --output tsv)"
container_app_principal_id="$(az containerapp show --name "$app_name" --resource-group "$resource_group" --query identity.principalId --output tsv)"
if [[ -z "$container_app_principal_id" || "$container_app_principal_id" == "None" ]]; then
  echo "Container app ${app_name} must have a system-assigned managed identity." >&2
  exit 1
fi
acr_id="$(az acr show --name "$acr_name" --resource-group "$platform_resource_group" --query id --output tsv)"
resource_group_scope="/subscriptions/${subscription_id}/resourceGroups/${resource_group}"
contributor_role_id="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
reader_role_id="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
repository_reader_role_id="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/b93aa761-3e63-49ed-ac28-beffa264f7ac"
repository_writer_role_id="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/2a1e307c-b015-4ebd-883e-5b7698a07328"
container_apps_contributor_role_id="/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions/358470bc-b998-42bd-ab17-a7e34c199c0f"
read_actions="!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/read'}) AND !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/read'})"
write_actions="!(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/metadata/write'}) AND !(ActionMatches{'Microsoft.ContainerRegistry/registries/repositories/content/write'})"
repository_matches="@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase '${repository_name}'"
pull_only_condition="((${read_actions}) OR (${repository_matches}))"
push_and_pull_condition="((${read_actions} AND ${write_actions}) OR (${repository_matches}))"

ensure_role_assignment \
  "$identity_principal_id" \
  "$contributor_role_id" \
  "Contributor" \
  "$resource_group_scope" \
  "" \
  "Deploy this business user workload"

ensure_role_assignment \
  "$identity_principal_id" \
  "$reader_role_id" \
  "Reader" \
  "$acr_id" \
  "" \
  "Read shared registry metadata"

ensure_role_assignment \
  "$identity_principal_id" \
  "$repository_writer_role_id" \
  "Container Registry Repository Writer" \
  "$acr_id" \
  "$push_and_pull_condition" \
  "Push and pull limited to repository ${repository_name}"

ensure_role_assignment \
  "$container_app_principal_id" \
  "$repository_reader_role_id" \
  "Container Registry Repository Reader" \
  "$acr_id" \
  "$pull_only_condition" \
  "Pull limited to repository ${repository_name}"

ensure_role_assignment \
  "$identity_principal_id" \
  "$container_apps_contributor_role_id" \
  "Container Apps Contributor" \
  "$environment_id" \
  "" \
  "Join the shared Container Apps environment"

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

tenant_id="$(az account show --query tenantId --output tsv)"
container_app_url="$(az containerapp show --name "$app_name" --resource-group "$resource_group" --query properties.configuration.ingress.fqdn --output tsv)"

gh variable set AZURE_CLIENT_ID --env production --repo "$github_repository" --body "$identity_client_id"
gh variable set AZURE_TENANT_ID --env production --repo "$github_repository" --body "$tenant_id"
gh variable set AZURE_SUBSCRIPTION_ID --env production --repo "$github_repository" --body "$subscription_id"
gh variable set AZURE_RESOURCE_GROUP --env production --repo "$github_repository" --body "$resource_group"
gh variable set AZURE_CONTAINER_REGISTRY_NAME --env production --repo "$github_repository" --body "$acr_name"
gh variable set AZURE_CONTAINER_REPOSITORY --env production --repo "$github_repository" --body "$repository_name"
gh variable set AZURE_CONTAINER_APP_NAME --env production --repo "$github_repository" --body "$app_name"

cat <<EOF

Provisioning succeeded.

The GitHub "production" environment variables were configured:
  AZURE_CLIENT_ID=${identity_client_id}
  AZURE_TENANT_ID=${tenant_id}
  AZURE_SUBSCRIPTION_ID=${subscription_id}
  AZURE_RESOURCE_GROUP=${resource_group}
  AZURE_CONTAINER_REGISTRY_NAME=${acr_name}
  AZURE_CONTAINER_REPOSITORY=${repository_name}
  AZURE_CONTAINER_APP_NAME=${app_name}

Shared platform resource group: ${platform_resource_group}
Bootstrap URL: https://${container_app_url}

This user can push only to repository "${repository_name}" of ${acr_name}.
Record ${repository_name} for offboarding, because repository content is not
removed when ${resource_group} is deleted.
EOF

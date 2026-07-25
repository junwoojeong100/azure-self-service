# IT 부서 가이드: 공유 플랫폼 운영과 현업 온보딩

## 이 가이드에서 할 일

1. 공유 ACA 환경, ABAC ACR, Log Analytics를 한 번 구성합니다.
2. 현업 담당자마다 전용 RG와 해당 RG 범위 `Owner`를 제공합니다.
3. 담당자 RG의 월 예산 알림을 설정합니다.
4. 현업이 GitHub 저장소를 준비하면 담당자 워크로드와 OIDC 배포 ID를 프로비저닝합니다.
5. 비용·쿼터·오프보딩을 중앙에서 운영합니다.

**완료 기준:** 공유 플랫폼이 준비되고, 담당자는 자기 RG에만 `Owner`를 가지며, GitHub Actions로 자기 ACR 리포지토리와 Container App만 배포할 수 있습니다.

> 각 체크포인트가 통과한 뒤 다음 단계로 진행합니다. 공유 플랫폼 RG에는 현업 담당자 역할을 부여하지 않습니다.

## 1. 시작 전 확인

필수 도구:

```bash
az version
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" --output table
gh auth status
```

저장소를 한 번 clone하고 이후 명령은 저장소 루트에서 실행합니다.

```bash
SOURCE_REPOSITORY="junwoojeong100/azure-self-service"
gh repo clone "$SOURCE_REPOSITORY"
cd azure-self-service
```

필요 권한:

| 작업 | 범위 | 필요한 역할 |
| --- | --- | --- |
| 공유 플랫폼 RG 생성·배포 | 구독 또는 대상 RG | RG 생성 권한과 `Contributor` |
| 담당자 RG 생성 | 구독 | RG 생성 권한 |
| 담당자 `Owner` 위임 | 담당자 RG | `Owner` 또는 `User Access Administrator` |
| 담당자 워크로드 배포 | 담당자 RG | `Contributor` + `Role Based Access Control Administrator` |
| 공유 ACR·ACA 환경 역할 할당 | 공유 RG | `Role Based Access Control Administrator` |
| 공유 ACR 리포지토리 삭제 | 공유 ACR | `Container Registry Repository Contributor` |
| GitHub 환경 변수 등록 | 담당자 저장소 | 저장소 `ADMIN` |

공유 ACA 환경의 앱들은 네트워크와 `Managed Environment Consumption Cores` 쿼터를 공유합니다. 담당자 간 네트워크 격리, 서로 다른 리전, 독립 청구가 필수인 워크로드는 이 가이드의 범위가 아닙니다.

## 2. 공유 플랫폼을 한 번 만든다

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"

./scripts/provision-shared-platform.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --location "koreacentral"
```

스크립트가 만드는 리소스:

| 리소스 | 역할 |
| --- | --- |
| Container Apps environment | 모든 담당자 Container App의 실행 환경 |
| ABAC Container Registry | 담당자별로 조건이 붙은 전용 리포지토리 제공 |
| Log Analytics workspace | 공유 환경의 컨테이너 로그 수집 |

**체크포인트:** 출력에서 다음 값을 기록합니다.

- `PLATFORM_RESOURCE_GROUP`
- `CONTAINER_APPS_ENVIRONMENT`
- `ACR_NAME`
- `ACR_ROLE_ASSIGNMENT_MODE=AbacRepositoryPermissions`

ABAC 모드가 아니면 스크립트가 중단됩니다. 조건 없는 Repository 역할은 레지스트리 전체 데이터 접근이 되므로 사용하지 않습니다.

### 2.1 플랫폼 운영자에게 오프보딩 권한을 부여한다

담당자 리포지토리를 삭제하는 운영자에게 공유 ACR 범위 `Container Registry Repository Contributor`를 부여합니다.

```bash
PLATFORM_OPERATOR_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv)"
ACR_NAME="$(az acr list \
  --resource-group rg-platform-shared \
  --query "[0].name" \
  --output tsv)"
ACR_ID="$(az acr show \
  --name "$ACR_NAME" \
  --resource-group rg-platform-shared \
  --query id --output tsv)"

az role assignment create \
  --assignee-object-id "$PLATFORM_OPERATOR_OBJECT_ID" \
  --assignee-principal-type User \
  --role "Container Registry Repository Contributor" \
  --scope "$ACR_ID"
```

파이프라인 ID를 운영자로 사용하면 해당 principal ID와 `ServicePrincipal` 유형으로 바꿉니다. 이 역할은 공유 ACR의 모든 리포지토리 데이터를 삭제할 수 있으므로 제한된 운영자나 PIM으로 관리합니다.

## 3. 담당자를 온보딩한다

이 절은 담당자마다 반복합니다.

### 3.1 담당자 RG를 만든다

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
RESOURCE_GROUP="rg-sales-jiyoon-dev"
BUSINESS_OWNER="jiyoon@contoso.com"
LOCATION="koreacentral"

az group create \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --tags \
    CostCenter=training \
    BusinessOwner="$BUSINESS_OWNER" \
    Environment=dev \
    Application=business-app
```

`CostCenter=training`은 실습용 값입니다. 조직의 실제 비용 센터 값으로 바꿉니다.

### 3.2 담당자 RG에만 Owner를 위임한다

```bash
./scripts/assign-resource-group-owner.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --business-owner "$BUSINESS_OWNER"
```

**체크포인트:** `Owner access confirmed`가 출력됩니다. 담당자가 자기 RG는 열 수 있지만 공유 플랫폼 RG와 다른 담당자 RG에는 접근할 수 없는지 확인합니다.

### 3.3 월 예산 알림을 설정한다

Azure portal에서 대상 **Resource group → Cost Management → Budgets → Add**로 이동합니다.

1. 월 예산 금액과 기간을 지정합니다.
2. Actual cost 50%, 80%, 100% 알림을 추가합니다.
3. Forecasted cost 알림도 추가합니다.
4. IT 비용 운영 메일과 필요한 Action Group을 연결합니다.

예산 알림은 비용을 차단하지 않습니다. 초과 시 담당자 확인, 배포 중지, 권한 제거, RG 삭제 절차를 별도로 운영합니다.

CLI 자동화 예시:

```bash
IT_EMAIL="cloud-cost@contoso.com"
START_DATE="$(date -u +%Y-%m-01T00:00:00Z)"
ACTION_GROUP_ID="$(az monitor action-group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "ag-cost-sales-jiyoon" \
  --short-name "costsales" \
  --action email "cost-team" "$IT_EMAIL" \
  --query id --output tsv)"

az consumption budget create-with-rg \
  --resource-group "$RESOURCE_GROUP" \
  --amount 100 \
  --budget-name "monthly-sales-jiyoon" \
  --category Cost \
  --time-grain Monthly \
  --time-period "{\"start-date\":\"$START_DATE\",\"end-date\":\"2031-12-31T23:59:59Z\"}" \
  --notifications "{\"at50\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":50.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]},\"at80\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":80.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]},\"at100\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":100.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]}}"
```

**체크포인트:** Azure portal에서 월 예산과 알림이 표시됩니다.

### 3.4 현업에게 GitHub 준비를 요청한다

현업 담당자에게 다음을 전달합니다.

- [현업 담당자 가이드](BUSINESS_USER_GUIDE.md)
- 담당자 RG 이름
- 저장소 원본 주소

현업 담당자는 현업 가이드 1~3절을 진행합니다. 3절에서 `<owner>/<repository>` 형식의 저장소 이름을 IT에 전달한 뒤 프로비저닝 완료를 기다립니다.

### 3.5 담당자 워크로드를 프로비저닝한다

현업이 GitHub `production` 환경과 보호 규칙을 만든 뒤 실행합니다.

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
RESOURCE_GROUP="rg-sales-jiyoon-dev"
GITHUB_REPOSITORY="contoso/sales-app"

gh auth status
gh repo view "$GITHUB_REPOSITORY" --json viewerPermission --jq .viewerPermission

./scripts/provision-user-workload.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --resource-group "$RESOURCE_GROUP" \
  --location "koreacentral" \
  --github-repository "$GITHUB_REPOSITORY"
```

`gh repo view` 결과는 `ADMIN`이어야 합니다. 권한이 없으면 저장소 관리자 또는 승인된 파이프라인이 실행합니다.

스크립트가 만드는 항목:

- 담당자 RG의 Container App
- GitHub Actions용 사용자 할당 관리 ID
- GitHub `production` Environment OIDC federated credential
- 담당자 RG `Contributor`
- 공유 ACR 관리 평면 `Reader`
- 담당자 리포지토리 조건이 붙은 Repository Writer
- 공유 ACA 환경 `Container Apps Contributor`
- 앱 시스템 ID의 조건부 Repository Reader
- GitHub `production` 환경 변수 7개

**체크포인트:** `Provisioning succeeded`, `AZURE_CONTAINER_REPOSITORY`, Bootstrap URL을 확인합니다. 현업 담당자에게 완료를 알립니다. 담당자는 현업 가이드 3절의 환경 변수 체크포인트를 확인한 뒤 4절부터 진행합니다.

### 3.6 역할과 쿼터를 확인한다

```bash
ACR_NAME="$(az acr list \
  --resource-group rg-platform-shared \
  --query "[0].name" \
  --output tsv)"
ACR_ID="$(az acr show \
  --name "$ACR_NAME" \
  --resource-group rg-platform-shared \
  --query id --output tsv)"

az role assignment list \
  --scope "$ACR_ID" \
  --query "[].{principal:principalId, role:roleDefinitionName, condition:condition}" \
  --output table

az containerapp env list-usages \
  --resource-group rg-platform-shared \
  --name cae-rg-platform-shared \
  --output table
```

- 공유 ACR `Reader`의 `condition`은 비어 있는 것이 정상입니다.
- Repository Writer와 Repository Reader에는 담당자 리포지토리 조건이 반드시 있어야 합니다.
- `infra/user-workload.bicep`은 `maxReplicas`를 최대 10, 기본값 2로 제한합니다.
- 담당자 증가 전에 환경 코어 할당량을 확인하고 필요하면 상향합니다.

## 4. 셀프서비스 경계

| 작업 | 현업 담당자 | IT 또는 플랫폼 파이프라인 |
| --- | --- | --- |
| GitHub 저장소와 `production` 보호 설정 | 수행 | 검토자 참여 |
| 코드 변경, 테스트, `main` Push | 수행 | 필요 시 리뷰 |
| 앱 배포와 revision 롤백 | 수행 | 사고 지원 |
| 공유 ACA 환경·ACR 변경 | 불가 | 수행 |
| 큐·데이터베이스 추가 | 요청 | 승인 후 수행 |
| 담당자 온보딩·오프보딩 | 요청 | 수행 |
| 구독 비용·정책·쿼터 | 조회 범위 제한 | 수행 |

GitHub Actions에는 장기 클라이언트 비밀을 저장하지 않습니다. federated credential은 지정된 저장소의 `production` Environment에서 발급한 OIDC 토큰만 신뢰합니다.

## 5. 비용과 운영 가드레일

- 개발 앱은 `minReplicas: 0`을 유지합니다.
- Azure Policy로 허용 리전, SKU, 필수 태그, 공개 ingress 정책을 관리합니다.
- 담당자 RG 비용은 Resource group 필터로 집계합니다.
- 공유 ACR·ACA 환경·Log Analytics 비용은 담당자별로 자동 분리되지 않습니다.
- 공유 고정비는 균등 배분하거나 IT 공통 비용으로 처리합니다.
- Log Analytics 사용량은 `ContainerAppConsoleLogs_CL`을 앱 이름으로 그룹화해 근사합니다.
- 같은 ACA 환경의 앱들은 서로 네트워크로 도달할 수 있으므로 앱 수준 인증을 적용합니다.

큐나 데이터베이스를 추가할 때는 [공유 자원 격리 가이드](RESOURCE_ISOLATION_GUIDE.md)의 엔티티 범위 RBAC와 데이터 보존 기준을 따릅니다.

## 6. 오프보딩

담당자 RG만 삭제하면 공유 ACR 리포지토리와 역할 할당이 남습니다. 실행자는 공유 ACR 범위 `Container Registry Repository Contributor`를 가져야 합니다. 먼저 시험 실행합니다.

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
RESOURCE_GROUP="rg-sales-jiyoon-dev"
BUSINESS_OWNER="jiyoon@contoso.com"
GITHUB_REPOSITORY="contoso/sales-app"

./scripts/offboard-business-user.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --resource-group "$RESOURCE_GROUP" \
  --business-owner "$BUSINESS_OWNER" \
  --github-repository "$GITHUB_REPOSITORY"
```

출력을 검토한 뒤 실제 적용합니다.

```bash
./scripts/offboard-business-user.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --resource-group "$RESOURCE_GROUP" \
  --business-owner "$BUSINESS_OWNER" \
  --github-repository "$GITHUB_REPOSITORY" \
  --delete-resource-group
```

스크립트 처리 순서:

1. 담당자 RG의 관리 ID 주체 ID 수집
2. 공유 RG 범위 역할 할당 삭제
3. 공유 ACR의 담당자 리포지토리 삭제
4. 담당자의 직접 RG 역할 할당 삭제
5. 담당자 RG 삭제

큐·토픽·데이터베이스와 로그 보존은 데이터 정책을 확인한 뒤 별도로 처리합니다. GitHub Environment, reviewer, 저장소 접근 권한도 제거합니다.

## 공식 참고 자료

- [Azure RBAC 역할 할당](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal)
- [ACR ABAC 리포지토리 권한](https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions)
- [Azure Cost Management 예산](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure Container Apps 비용 최적화](https://learn.microsoft.com/azure/well-architected/service-guides/azure-container-apps)

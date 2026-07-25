# IT 부서 가이드: 현업 Owner 위임과 비용 거버넌스

## 이 가이드에서 할 일

1. 격리 모델(전용 / 공유 플랫폼)을 고릅니다.
2. 현업 담당자마다 전용 RG를 만들고, **그 RG에만** `Owner`를 부여합니다.
3. 월 예산과 50%, 80%, 100% 알림을 설정합니다.
4. 현업 담당자에게 [현업 담당자 가이드](BUSINESS_USER_GUIDE.md)와 RG 이름을 전달합니다. 모델 B는 현업의 GitHub 준비 후 워크로드 프로비저닝을 완료합니다.

**완료 기준:** 담당자는 자신의 RG에만 `Owner`를 갖고, 월 예산 알림이 설정됩니다. 모델 B는 공유 플랫폼과 담당자 워크로드까지 준비되며, IT는 구독 범위 비용·정책을 계속 관리합니다.

> **실습 원칙:** 각 단계의 확인 결과가 나오기 전에는 다음 단계로 진행하지 않습니다. 이 가이드에서는 IT가 구독·RG를 관리하고, 다음 가이드에서는 현업 담당자가 자기 RG만 사용합니다.

## 0. 먼저 격리 모델을 고른다

담당자 수에 따라 두 모델 중 하나를 선택합니다. 판단 기준과 근거는 [자원 격리 가이드](RESOURCE_ISOLATION_GUIDE.md)에 정리되어 있습니다.

| | **모델 A. 전용** | **모델 B. 공유 플랫폼** |
| --- | --- | --- |
| 담당자 RG 안에 있는 것 | ACA 환경, ACR, 로그, 앱 전부 | 앱과 배포용 관리 ID만 |
| 공유되는 것 | 없음 | ACA 환경, ACR, Log Analytics |
| ACR 고정비 | 담당자 수에 비례 | 레지스트리 1개 |
| 담당자 간 네트워크 격리 | 있음 | **없음** (같은 환경을 공유) |
| 프로비저닝 주체 | 현업 담당자 | **IT 또는 파이프라인** |
| 템플릿 | `infra/main.bicep` | `infra/platform.bicep` + `infra/user-workload.bicep` |
| 절차 | 아래 1~2절 → 4~5절 → 현업 가이드 1절부터 | 1~2절 → 3.1절 → 4~5절 → 현업 가이드 1~2절 → 3.2~3.4절 → 현업 가이드 4절부터 |

담당자가 5명 이하인 실습이라면 모델 A로 시작하고, 레지스트리 고정비와 리전당 환경 쿼터가 부담이 되는 시점에 모델 B로 옮깁니다. 담당자 간 네트워크 격리가 요구사항이면 모델 B를 쓰면 안 됩니다.

## 1. 운영 모델

IT 부서는 각 현업 담당자에게 **전용 Azure Resource Group(RG)** 과 그 RG 범위의 **`Owner`** 역할을 제공합니다. 현업 담당자는 자기 RG 안에서 GitHub Copilot 또는 Claude Code의 도움으로 Azure Container Apps(ACA), Azure Container Registry(ACR), GitHub Actions를 만들고 운영합니다. IT는 구독·다른 RG·비용 거버넌스를 계속 관리합니다.

```text
IT 부서: Subscription / Billing / Policy / Cost Management
  ├─ rg-sales-jiyoon-dev ── Owner ── 영업 담당자
  ├─ rg-hr-minsu-dev    ── Owner ── 인사 담당자
  └─ rg-marketing-yuna-dev ─ Owner ── 마케팅 담당자
```

| 주체 | 책임 | 권한 범위 |
| --- | --- | --- |
| IT 부서 | RG 생성, Owner 위임, 정책, 비용 모니터링·알림, 오프보딩 | 구독 및 Billing scope |
| 현업 담당자 | 앱·ACR·ACA·GitHub Actions 생성과 배포, 자기 앱 비용 확인 | **자기 RG만 Owner** |
| GitHub Actions 관리 ID | 컨테이너 빌드·ACR Push·ACA 배포 | 현업 RG `Contributor`; 모델 A는 ACR `AcrPush`, 모델 B는 공유 ACR `Reader` + 조건부 Repository Writer |
| Container App 관리 ID | 실행 이미지 Pull | 모델 A는 ACR `AcrPull`, 모델 B는 조건부 Repository Reader |

> `Owner`는 RG 안에서 리소스를 생성·삭제하고 역할도 위임할 수 있는 강한 권한입니다. 따라서 담당자에게 **구독 Owner를 부여하지 말고**, 전용 RG 이외의 scope에 역할을 주지 않습니다. IT가 Owner를 부여하려면 `Owner` 또는 `User Access Administrator`처럼 `Microsoft.Authorization/roleAssignments/write` 권한이 필요합니다.

## 2. 전용 RG와 Owner를 준비한다

### 2.1 RG를 만든다

환경별 격리를 권장합니다. 개발과 운영을 같은 RG에 넣지 않습니다.

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
RESOURCE_GROUP="rg-sales-jiyoon-dev"
BUSINESS_OWNER="jiyoon@contoso.com"

az group create \
  --subscription "$SUBSCRIPTION_ID" \
  --name "$RESOURCE_GROUP" \
  --location "koreacentral" \
  --tags \
    CostCenter=training \
    BusinessOwner="$BUSINESS_OWNER" \
    Environment=dev \
    Application=business-app
```

`CostCenter=training`은 실습용 값입니다. 조직의 비용 센터 값이 있으면 그 값으로 바꿉니다.

### 2.2 RG 범위에서만 Owner를 위임한다

저장소의 스크립트를 IT 권한으로 실행합니다.

```bash
./scripts/assign-resource-group-owner.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --business-owner "$BUSINESS_OWNER"
```

스크립트는 Microsoft Entra 사용자를 확인하고 전용 RG 범위에만 `Owner`를 부여하며, 이미 같은 할당이 있으면 재사용합니다.

**체크포인트:** 스크립트가 `Owner access confirmed`를 출력합니다. Azure portal에서 현업 담당자가 해당 RG는 열 수 있지만 다른 RG·구독에는 권한이 없는지 확인합니다.

포털에서는 **Resource group → Access control (IAM) → Add role assignment → Owner**를 선택해 동일하게 구성할 수 있습니다. 현업 담당자가 Azure portal에서 자기 RG만 보이는지, 구독 및 다른 RG는 접근하지 못하는지 확인합니다.

## 3. 모델 B를 선택했다면: 공유 플랫폼을 구성한다

모델 A를 선택했다면 이 절을 건너뛰고 4절로 이동합니다. 현업 가이드는 5절의 비용 설정까지 끝낸 뒤 전달합니다.

### 3.1 공유 플랫폼을 한 번 만든다

```bash
./scripts/provision-shared-platform.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --location "koreacentral"
```

스크립트는 공유 RG에 ACA 환경, Log Analytics, **ABAC 모드 컨테이너 레지스트리**를 만들고 레지스트리가 실제로 ABAC 모드인지 확인한 뒤 종료합니다.

**체크포인트:** 출력의 `ACR_ROLE_ASSIGNMENT_MODE=AbacRepositoryPermissions`를 확인하고 `ACR_NAME`을 기록합니다. 모드 값이 다르면 리포지토리 단위 격리가 조용히 레지스트리 전체 권한으로 바뀌므로 스크립트가 중단됩니다.

> 현업 담당자에게는 이 RG에 **어떤 역할도 부여하지 않습니다.** 공유 RG에 `Contributor`를 주면 다른 담당자의 리소스를 삭제할 수 있습니다.

공유 플랫폼이 준비되면 아직 담당자 워크로드를 배포하지 않습니다. 4~5절의 셀프서비스 범위와 비용 설정을 끝낸 뒤 현업 담당자에게 현업 가이드 1~2절을 수행하도록 요청하고, `<owner>/<repository>` 형식의 저장소 이름을 전달받습니다. 그다음 아래 3.2절로 돌아옵니다.

### 3.2 담당자마다 워크로드를 배포한다

모델 B에서는 담당자가 공유 RG에 권한이 없으므로 **IT가 프로비저닝을 대행**합니다. 이 절을 시작하기 전에 현업 담당자가 GitHub `production` 환경과 보호 규칙을 만들었고 저장소 이름을 전달했는지 확인합니다.

스크립트는 GitHub `production` 환경 변수를 등록하므로 실행자는 해당 저장소의 관리자 권한과 GitHub CLI 로그인이 필요합니다.

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
GITHUB_REPOSITORY="contoso/sales-app"
gh auth status
gh repo view "$GITHUB_REPOSITORY" --json viewerPermission --jq .viewerPermission

./scripts/provision-user-workload.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --resource-group "rg-sales-jiyoon-dev" \
  --location "koreacentral" \
  --github-repository "$GITHUB_REPOSITORY"
```

`gh repo view` 결과가 `ADMIN`이 아니면 저장소 관리자에게 실행을 요청하거나, Azure 권한과 GitHub 관리자 권한을 가진 승인된 파이프라인으로 프로비저닝합니다.

이 스크립트를 실행하는 주체에게 필요한 권한은 다음과 같습니다.

| 범위 | 역할 | 이유 |
| --- | --- | --- |
| 담당자 RG | `Contributor` + `Role Based Access Control Administrator` | 컨테이너 앱·관리 ID 생성 및 배포 ID의 RG 범위 `Contributor` 할당 |
| 공유 RG | `Role Based Access Control Administrator` | ACR 리포지토리·ACA 환경 범위 역할 할당 생성 |

스크립트는 담당자 RG가 이미 존재하는지 확인할 뿐 새 RG를 만들지 않으며, 공유 RG에는 ARM 배포를 만들지 않고 필요한 역할 할당만 직접 생성합니다. 따라서 공유 RG의 `Contributor`는 필요하지 않습니다.

`User Access Administrator` 대신 `Role Based Access Control Administrator`를 쓰는 이유는 후자가 역할 할당 관련 권한만 갖고 있고, 부여 가능한 역할을 조건으로 제한할 수 있어 자동화 신원의 권한 상승을 막기 때문입니다.

**체크포인트:** 출력의 `AZURE_CONTAINER_REPOSITORY` 값을 담당자 대장에 기록합니다. 레지스트리 콘텐츠는 담당자 RG를 삭제해도 남으므로 오프보딩에 이 값이 필요합니다.

### 3.3 담당자별 부여 권한을 확인한다

```bash
ACR_NAME="<3.1절에서 기록한 ACR_NAME>"
ACR_ID="$(az acr show --name "$ACR_NAME" --resource-group rg-platform-shared --query id --output tsv)"
az role assignment list --scope "$ACR_ID" \
  --query "[].{principal:principalId, role:roleDefinitionName, condition:condition}" --output table
```

관리 평면 조회용 `Reader`의 `condition`은 비어 있는 것이 정상입니다. `Container Registry Repository Writer`와 `Container Registry Repository Reader`에는 반드시 `condition`이 채워져 있어야 합니다. **이 두 리포지토리 역할에 조건이 없으면 레지스트리 전체 권한**이며 격리가 없는 것과 같습니다.

### 3.4 공유로 인한 가드레일을 설정한다

`Managed Environment Consumption Cores` 할당량은 환경 안 모든 앱이 나눠 씁니다. 한 담당자가 스케일을 크게 잡으면 다른 담당자의 앱이 스케일에 실패합니다.

```bash
az containerapp env list-usages \
  --resource-group rg-platform-shared --name cae-rg-platform-shared --output table
```

`infra/user-workload.bicep`은 `maxReplicas`를 최대 10으로 제한하고 기본값 2를 씁니다. 담당자 수가 늘면 할당량 상향을 미리 요청합니다.

또한 **같은 환경의 앱들은 같은 가상 네트워크에 있어 서로 호출할 수 있습니다.** 담당자 간 네트워크 격리가 필요한 워크로드는 모델 A로 분리합니다.

여기까지 확인되면 현업 담당자에게 프로비저닝 완료를 알리고 현업 가이드 4절부터 진행하도록 안내합니다. 아래 3.5절은 큐나 데이터베이스 요청이 있을 때만 적용합니다.

### 3.5 큐·데이터베이스 요청에 대응한다

담당자가 큐나 데이터베이스를 요청하면 [자원 격리 가이드 4절](RESOURCE_ISOLATION_GUIDE.md#4-큐데이터베이스가-필요해지면)의 판단 기준을 따릅니다. 요약하면 다음과 같습니다.

- **큐(Service Bus, Storage Queue)** — 공유 인스턴스 + 엔티티 범위 RBAC. 격리 강도가 전용과 거의 같고 비용은 인스턴스 하나입니다.
- **관계형 데이터베이스(PostgreSQL)** — 기본은 담당자 RG 안의 전용 서버. 데이터베이스 단위 Azure RBAC가 없고 백업·복원이 서버 단위로 묶이기 때문입니다.
- 공유 데이터베이스를 쓴다면 `REVOKE CONNECT ON DATABASE ... FROM PUBLIC`을 반드시 수행합니다. 이것이 빠지면 격리가 되어 있지 않습니다.

## 4. 현업에 전달할 셀프서비스 범위

아래 셀프서비스 범위를 확정하고 5절의 예산·비용 가드레일까지 설정한 뒤, 현업 담당자에게 [현업 담당자 가이드](BUSINESS_USER_GUIDE.md)와 전용 RG 이름을 전달합니다. 모델 A는 현업 가이드 전체를 순서대로 진행합니다. 모델 B는 먼저 1~2절만 진행해 저장소 이름을 IT에 전달하고, IT가 3.2~3.4절을 완료한 뒤 현업 가이드 4절부터 재개합니다.

| | 모델 A. 전용 | 모델 B. 공유 플랫폼 |
| --- | --- | --- |
| GitHub 저장소 생성, `production` 보호 설정 | 담당자 | 담당자 |
| Azure 환경 프로비저닝 | 담당자 (`provision-team-environment.sh`) | **IT** (`provision-user-workload.sh`) |
| 코드 변경, 테스트, `main` 푸시, 배포와 롤백 | 담당자 | 담당자 |
| 큐·데이터베이스 추가 | 담당자 (자기 RG 안) | **IT 또는 파이프라인** |

GitHub Actions에는 장기 클라이언트 비밀을 저장하지 않습니다. 스크립트가 설정한 federated credential은 해당 저장소의 `production` environment에서 발급한 GitHub OIDC 토큰만 신뢰합니다.

## 5. 비용 관리: IT가 중앙에서 보되, 현업도 책임지게 한다

### 5.1 비용을 보는 위치

IT는 Azure portal의 **Cost Management + Billing → Cost analysis**에서 **Subscription** scope를 선택하고 `Resource group` 필터로 `rg-sales-jiyoon-dev`를 지정합니다. 이 방식은 담당자가 자기 RG에서 예산을 수정하더라도 IT의 구독 수준 비용 분석과 거버넌스를 유지합니다.

- 비용·사용량 데이터는 일반적으로 8~24시간 뒤 표시되며 예산 평가는 약 24시간 주기로 수행됩니다.
- 예산 알림은 비용을 **차단하지 않습니다**. 초과 시 알림·검토·중지·RG 삭제 절차를 운영해야 합니다.
- 팀, 서비스, 환경을 구분하려면 `CostCenter`, `BusinessOwner`, `Environment`, `Application` 태그를 IT 정책으로 필수화합니다.

### 5.2 담당자 RG 예산과 알림을 만든다

IT는 담당자별 RG scope에서 월 예산을 만들고 IT 비용 운영 메일을 50%, 80%, 100% 임계값의 수신자로 둡니다.

1. Azure portal에서 대상 **Resource group**을 엽니다.
2. **Cost Management → Budgets → Add**를 선택합니다.
3. 월 예산 금액과 기간을 지정합니다.
4. Actual cost와 Forecasted cost 기준으로 50%, 80%, 100% 알림을 설정하고 IT 비용 운영 메일을 넣습니다.
5. 운영 환경은 Azure Monitor Action Group도 연결해 Teams, ITSM, Automation으로 전달합니다.

Azure CLI로 Action Group과 RG 예산을 자동화할 수도 있습니다. 아래 예시는 공식 Cost Management 패턴입니다.

```bash
IT_EMAIL="cloud-cost@contoso.com"
RG="rg-sales-jiyoon-dev"
START_DATE="$(date -u +%Y-%m-01T00:00:00Z)"
ACTION_GROUP_ID="$(az monitor action-group create \
  --resource-group "$RG" \
  --name "ag-cost-sales-jiyoon" \
  --short-name "costsales" \
  --action email "cost-team" "$IT_EMAIL" \
  --query id --output tsv)"

az consumption budget create-with-rg \
  --resource-group "$RG" \
  --amount 100 \
  --budget-name "monthly-sales-jiyoon" \
  --category Cost \
  --time-grain Monthly \
  --time-period "{\"start-date\":\"$START_DATE\",\"end-date\":\"2031-12-31T23:59:59Z\"}" \
  --notifications "{\"at50\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":50.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]},\"at80\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":80.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]},\"at100\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":100.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]}}"
```

**체크포인트:** Azure portal의 **Cost Management → Budgets**에서 월 예산과 50%, 80%, 100% 알림 세 개가 보이는지 확인합니다. 예산 알림은 비용을 차단하지 않으므로, 초과 알림의 담당·중지 절차는 IT가 별도로 운영합니다.

> RG `Owner`는 자기 RG 수준 예산도 변경할 수 있습니다. IT의 통제 기준은 담당자 RG 예산 하나에 의존하지 말고, 구독 scope의 Cost analysis·Budget·Export와 Azure Policy를 함께 사용합니다.

### 5.3 비용 가드레일

- 개발 ACA는 `minReplicas: 0`을 사용해 유휴 시 scale-to-zero합니다.
- Azure Policy로 허용 리전, 허용 SKU, 필수 태그, Public IP/공개 ingress 정책을 정합니다.
- 매월 RG별 Cost analysis를 Export해 비용 센터와 서비스 오너에게 공유합니다.
- 예산 초과 시 IT는 먼저 담당자와 리소스 현황을 확인하고, 필요하면 RG `Owner` 역할 제거 또는 RG 삭제를 수행합니다.

### 5.4 모델 B에서는 공유 리소스 비용이 자동으로 나뉘지 않는다

담당자 RG 비용은 RG 필터로 정확히 나오지만, 공유 레지스트리·환경·Log Analytics의 고정비는 Azure가 담당자별로 쪼개 주지 않습니다. 태그로도 불가능합니다.

- 공유 고정비는 담당자 수로 균등 배분하거나 IT 공통 비용으로 처리합니다.
- 변동비(앱 실행 시간, 로그 수집량)만 담당자 RG 기준으로 실비 청구합니다.
- Log Analytics는 `ContainerAppConsoleLogs_CL`을 앱 이름으로 그룹화해 담당자별 수집량을 근사할 수 있습니다.

## 6. 오프보딩과 사고 대응

### 6.1 모델 A: 전용

담당자 이동·퇴사 시 순서는 다음과 같습니다.

1. `Owner` 역할을 제거합니다.
2. GitHub 저장소·Environment의 배포 권한과 reviewer를 제거합니다.
3. 예산·Cost export·Log Analytics 보존 필요성을 확인합니다.
4. 보존이 끝난 비운영 RG를 삭제합니다.

```bash
BUSINESS_OWNER_OBJECT_ID="$(az ad user show --id "$BUSINESS_OWNER" --query id --output tsv)"
SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP"

az role assignment delete --assignee "$BUSINESS_OWNER_OBJECT_ID" --role Owner --scope "$SCOPE"
az group delete --subscription "$SUBSCRIPTION_ID" --name "$RESOURCE_GROUP" --yes --no-wait
```

### 6.2 모델 B: 공유 플랫폼

**`az group delete` 하나로 끝나지 않습니다.** 공유 RG에 있는 역할 할당과 레지스트리 콘텐츠는 담당자 RG를 삭제해도 남고, 관리 ID가 사라지면서 "Identity not found" 상태의 고아 역할 할당이 됩니다.

먼저 삭제 없이 대상만 확인합니다.

```bash
./scripts/offboard-business-user.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --platform-resource-group "rg-platform-shared" \
  --resource-group "rg-sales-jiyoon-dev" \
  --business-owner "$BUSINESS_OWNER" \
  --github-repository "contoso/sales-app"
```

출력을 확인한 뒤 `--delete-resource-group`을 붙여 실제로 적용합니다. 스크립트는 다음 순서를 지킵니다.

1. 담당자 RG의 관리 ID 주체 ID를 **먼저 수집** (RG 삭제 후에는 조회 불가)
2. 공유 RG 범위의 역할 할당 삭제
3. 공유 레지스트리에서 담당자 리포지토리 삭제
4. 담당자 본인의 직접 역할 할당 삭제
5. 담당자 RG 삭제

스크립트가 **일부러 처리하지 않는 것**은 공유 인스턴스 안의 큐·데이터베이스입니다. 데이터 보존 판단이 필요하므로 [자원 격리 가이드](RESOURCE_ISOLATION_GUIDE.md)를 참고해 수동으로 결정합니다.

## 공식 참고 자료

- [Azure RBAC 역할 할당](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal)
- [Azure Cost Management 예산 만들기 및 관리](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure Container Apps 비용 최적화 가이드](https://learn.microsoft.com/azure/well-architected/service-guides/azure-container-apps)

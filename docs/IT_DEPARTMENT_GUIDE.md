# IT 부서 가이드: 현업 Owner 위임과 비용 거버넌스

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
| GitHub Actions 관리 ID | 컨테이너 빌드·ACR Push·ACA 배포 | 현업 RG `Contributor`, 해당 ACR `AcrPush` |
| Container App 관리 ID | 실행 이미지 Pull | 해당 ACR `AcrPull` |

> `Owner`는 RG 안에서 리소스를 생성·삭제하고 역할도 위임할 수 있는 강한 권한입니다. 따라서 담당자에게 **구독 Owner를 부여하지 말고**, 전용 RG 이외의 scope에 역할을 주지 않습니다. IT가 Owner를 부여하려면 `Owner` 또는 `User Access Administrator`처럼 `Microsoft.Authorization/roleAssignments/write` 권한이 필요합니다.

## 2. 담당자별 RG와 Owner를 준비한다

### 2.1 RG를 만든다

환경별 격리를 권장합니다. 개발과 운영을 같은 RG에 넣지 않습니다.

```bash
az account set --subscription "<SUBSCRIPTION_ID>"
az group create --name "rg-sales-jiyoon-dev" --location "koreacentral"
```

### 2.2 RG 범위에서만 Owner를 위임한다

저장소의 스크립트를 IT 권한으로 실행합니다.

```bash
chmod +x scripts/assign-resource-group-owner.sh
./scripts/assign-resource-group-owner.sh \
  --subscription-id "<SUBSCRIPTION_ID>" \
  --resource-group "rg-sales-jiyoon-dev" \
  --business-owner "jiyoon@contoso.com"
```

스크립트는 Microsoft Entra 사용자를 확인하고 아래 scope에만 `Owner`를 부여하며, 이미 같은 할당이 있으면 재사용합니다.

```text
/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-sales-jiyoon-dev
```

포털에서는 **Resource group → Access control (IAM) → Add role assignment → Owner**를 선택해 동일하게 구성할 수 있습니다. 현업 담당자가 Azure portal에서 자기 RG만 보이는지, 구독 및 다른 RG는 접근하지 못하는지 확인합니다.

반복 배포 환경에서는 아래 Bicep 대안을 사용할 수 있습니다. 역할 할당이 현재 RG에만 scope되도록 `infra/business-owner-assignment.bicep`에 명시되어 있습니다.

```bash
az deployment group create \
  --resource-group "rg-sales-jiyoon-dev" \
  --template-file infra/business-owner-assignment.bicep \
  --parameters businessOwnerPrincipalId="<USER_OBJECT_ID>"
```

## 3. 현업에 전달할 셀프서비스 범위

현업 담당자에게 [현업 담당자 가이드](BUSINESS_USER_GUIDE.md)와 전용 RG 이름만 전달합니다. 그들은 다음을 스스로 수행합니다.

1. GitHub 저장소 생성 및 `production` environment 보호 설정
2. `scripts/provision-team-environment.sh`으로 ACR·ACA·로그·OIDC 배포 ID 생성
3. GitHub Actions variables 설정
4. FastAPI 코드 변경, 테스트, `main` 푸시, ACA 배포와 롤백

GitHub Actions에는 장기 클라이언트 비밀을 저장하지 않습니다. 스크립트가 설정한 federated credential은 해당 저장소의 `production` environment에서 발급한 GitHub OIDC 토큰만 신뢰합니다.

## 4. 비용 관리: IT가 중앙에서 보되, 현업도 책임지게 한다

### 4.1 비용을 보는 위치

IT는 Azure portal의 **Cost Management + Billing → Cost analysis**에서 **Subscription** scope를 선택하고 `Resource group` 필터로 `rg-sales-jiyoon-dev`를 지정합니다. 이 방식은 담당자가 자기 RG에서 예산을 수정하더라도 IT의 구독 수준 비용 분석과 거버넌스를 유지합니다.

- 비용·사용량 데이터는 일반적으로 8~24시간 뒤 표시되며 예산 평가는 약 24시간 주기로 수행됩니다.
- 예산 알림은 비용을 **차단하지 않습니다**. 초과 시 알림·검토·중지·RG 삭제 절차를 운영해야 합니다.
- 팀, 서비스, 환경을 구분하려면 `CostCenter`, `BusinessOwner`, `Environment`, `Application` 태그를 IT 정책으로 필수화합니다.

### 4.2 담당자 RG 예산과 알림을 만든다

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
  --time-period '{"start-date":"2026-07-01","end-date":"2031-12-31"}' \
  --notifications "{\"at80\":{\"enabled\":\"true\",\"operator\":\"GreaterThanOrEqualTo\",\"threshold\":80.0,\"contact-emails\":[\"$IT_EMAIL\"],\"contact-groups\":[\"$ACTION_GROUP_ID\"]}}"
```

> RG `Owner`는 자기 RG 수준 예산도 변경할 수 있습니다. IT의 통제 기준은 담당자 RG 예산 하나에 의존하지 말고, 구독 scope의 Cost analysis·Budget·Export와 Azure Policy를 함께 사용합니다.

### 4.3 비용 가드레일

- 개발 ACA는 `minReplicas: 0`을 사용해 유휴 시 scale-to-zero합니다.
- Azure Policy로 허용 리전, 허용 SKU, 필수 태그, Public IP/공개 ingress 정책을 정합니다.
- 매월 RG별 Cost analysis를 Export해 비용 센터와 서비스 오너에게 공유합니다.
- 예산 초과 시 IT는 먼저 담당자와 리소스 현황을 확인하고, 필요하면 RG `Owner` 역할 제거 또는 RG 삭제를 수행합니다.

## 5. 오프보딩과 사고 대응

담당자 이동·퇴사 시 순서는 다음과 같습니다.

1. `Owner` 역할을 제거합니다.
2. GitHub 저장소·Environment의 배포 권한과 reviewer를 제거합니다.
3. 예산·Cost export·Log Analytics 보존 필요성을 확인합니다.
4. 보존이 끝난 비운영 RG를 삭제합니다.

```bash
SCOPE="/subscriptions/<SUBSCRIPTION_ID>/resourceGroups/rg-sales-jiyoon-dev"
az role assignment delete --assignee "<USER_OBJECT_ID>" --role "Owner" --scope "$SCOPE"
az group delete --name "rg-sales-jiyoon-dev" --yes --no-wait
```

## 공식 참고 자료

- [Azure RBAC 역할 할당](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-portal)
- [Azure Cost Management 예산 만들기 및 관리](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [Azure Container Apps 비용 최적화 가이드](https://learn.microsoft.com/azure/well-architected/service-guides/azure-container-apps)

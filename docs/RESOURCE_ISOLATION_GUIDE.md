# 자원 격리 가이드: 어디까지 나누고, 어디부터 공유할 것인가

## 이 문서의 목적

이 저장소는 **현업 담당자별 격리**를 두 가지 모델로 제공합니다. 이 문서는 두 모델의 경계를 정의하고, 큐·데이터베이스처럼 나중에 추가되는 리소스를 어떤 기준으로 나눌지 결정하는 방법을 설명합니다.

| 모델 | 템플릿 | 격리 경계 | 언제 쓰는가 |
| --- | --- | --- | --- |
| **A. 전용 모델** | `infra/main.bicep` | 담당자별 RG 안에 ACA 환경·ACR·로그까지 전부 | 담당자 수가 적고 완전 분리가 필요할 때 |
| **B. 공유 플랫폼 모델** | `infra/platform.bicep` + `infra/user-workload.bicep` | 플랫폼 리소스는 공유, 앱은 담당자별 RG | 담당자가 늘어 중복 리소스가 부담일 때 |

---

## 1. 먼저 바로잡을 전제: 문제는 RG가 아니다

"담당자마다 RG를 만들면 자원이 너무 많아진다"는 인식은 절반만 맞습니다. **리소스 그룹 자체는 무료이고 쿼터를 소비하지 않습니다.** 실제 부담은 RG가 아니라 그 안에서 담당자마다 중복 생성되는 플랫폼 리소스입니다.

| 담당자마다 중복될 때 | 실제 부담 |
| --- | --- |
| Resource Group | 없음. 요금 0, 쿼터 0 |
| Container Apps 환경 | 요금은 없지만 **리전당 환경 수 쿼터**를 소비하고, 사용자 지정 VNet을 쓰면 서브넷을 하나씩 점유하며, 생성에 수 분이 걸림 |
| Container Registry | **담당자 수에 비례하는 고정 요금** |
| Log Analytics 작업 영역 | 요금은 GB 종량제라 개수 영향이 적지만, 작업 영역이 흩어져 교차 조회가 어려움 |

반대로 RG를 없애면 잃는 것이 큽니다.

- RBAC를 부여할 자연스러운 범위
- `az group delete` 한 번으로 끝나는 오프보딩
- 태그 없이도 자동으로 분리되는 비용 귀속
- 배포와 Azure Policy의 적용 범위

**그래서 모델 B는 RG를 없애지 않습니다.** 담당자 RG는 그대로 두고, 중복되던 플랫폼 리소스만 공유 RG로 끌어올립니다.

---

## 2. 모델 B 구조

```text
rg-platform-shared            ← IT 소유. 현업 담당자는 아무 역할도 갖지 않는다
  ├─ Container Apps 환경 (공유)
  ├─ Container Registry (ABAC 모드, 담당자별 리포지토리)
  └─ Log Analytics 작업 영역 (공유)

rg-sales-jiyoon-dev           ← 현업 담당자 소유
  ├─ Container App            → managedEnvironmentId 로 공유 환경에 조인
  └─ 배포용 관리 ID (id-gha-deploy)

rg-hr-minsu-dev               ← 현업 담당자 소유
  └─ ...
```

`Microsoft.App/containerApps`의 `managedEnvironmentId`는 리소스 ID이므로, **앱과 환경이 서로 다른 RG에 있어도 됩니다.** 이 한 가지 성질 덕분에 비용·권한 경계(RG)와 런타임 경계(ACA 환경)를 분리할 수 있습니다.

### 담당자에게 부여되는 권한

| 대상 | 범위 | 역할 |
| --- | --- | --- |
| 현업 담당자 | 자기 RG | `Owner` 또는 `Contributor` |
| 현업 담당자 | 공유 RG | **없음** |
| 배포용 관리 ID | 자기 RG | `Contributor` |
| 배포용 관리 ID | 공유 ACR | `Reader` (로그인 서버 조회용 관리 평면 읽기) |
| 배포용 관리 ID | 공유 ACR | `Container Registry Repository Writer` + **자기 리포지토리로 제한하는 ABAC 조건** |
| 배포용 관리 ID | 공유 ACA 환경 | `Container Apps Contributor` (환경 리소스 범위) |
| Container App 관리 ID | 공유 ACR | `Container Registry Repository Reader` + **자기 리포지토리로 제한하는 ABAC 조건** |

### 레지스트리를 안전하게 공유하는 방법

레지스트리를 그냥 공유하면 담당자 A가 담당자 B의 이미지를 덮어쓸 수 있습니다. 이를 막기 위해 `infra/platform.bicep`은 레지스트리를 **ABAC 모드**로 만듭니다.

```bicep
roleAssignmentMode: 'AbacRepositoryPermissions'
```

이 모드에서는 `AcrPush`, `AcrPull` 같은 기존 역할이 **더 이상 적용되지 않고**, 대신 조건을 붙일 수 있는 역할을 씁니다. `provision-user-workload.sh`가 담당자 리포지토리에 맞는 조건을 계산해 역할 할당에 직접 적용합니다. 공유 ACR의 `Reader`는 `az acr show`와 `az acr login`에 필요한 관리 평면 읽기만 허용하며, 이미지 읽기·쓰기는 계속 ABAC 조건이 붙은 리포지토리 역할로 제한됩니다.

> **API 버전 주의:** `roleAssignmentMode`는 `Microsoft.ContainerRegistry/registries@2025-11-01` 이상에서만 적용됩니다. 그보다 낮은 API 버전을 쓰면 ARM이 이 속성을 **오류 없이 무시하고** 레지스트리가 `LegacyRegistryPermissions`로 만들어집니다. 배포가 성공해도 격리가 없는 상태가 되므로, `provision-shared-platform.sh`는 배포 후 실제 모드를 확인하고 다르면 중단합니다.

```text
((
  !(ActionMatches{'.../repositories/metadata/read'}) AND
  !(ActionMatches{'.../repositories/content/read'})  AND
  !(ActionMatches{'.../repositories/metadata/write'}) AND
  !(ActionMatches{'.../repositories/content/write'})
) OR (
  @Request[Microsoft.ContainerRegistry/registries/repositories:name]
    StringEqualsIgnoreCase 'rg-sales-jiyoon-dev/business-app'
))
```

읽고 쓰는 동작이면 리포지토리 이름이 일치할 때만 허용하고, 그 외 동작에는 조건을 적용하지 않는다는 뜻입니다. Premium SKU가 필요 없으므로 Basic 레지스트리 하나로 전체 담당자를 수용할 수 있습니다.

> **주의:** ABAC 역할을 **조건 없이** 부여하면 레지스트리 전체 권한이 됩니다. 조건이 곧 격리이므로, 조건을 빠뜨린 역할 할당은 격리가 아예 없는 것과 같습니다. `provision-user-workload.sh`는 레지스트리가 ABAC 모드가 아니면 배포를 중단합니다.

---

## 3. 모델 B에서 반드시 함께 넣어야 할 가드레일

공유는 공짜가 아닙니다. 아래 다섯 가지는 선택이 아니라 필수입니다.

### 3.1 환경 코어 쿼터는 담당자 전원이 나눠 쓴다

`Managed Environment Consumption Cores` 쿼터는 **환경 단위**로, 환경 안 모든 앱의 활성 레플리카 코어 합계에 적용됩니다. 한 담당자가 `maxReplicas`를 크게 잡으면 다른 담당자의 앱이 스케일에 실패합니다.

`infra/user-workload.bicep`은 `maxReplicas`를 최대 10으로 제한하고 기본값을 2로 둡니다. 담당자 수가 늘면 IT가 환경 쿼터 상향을 미리 요청해야 합니다.

```bash
az containerapp env list-usages --resource-group rg-platform-shared --name cae-rg-platform-shared
```

### 3.2 같은 환경의 앱은 서로 호출할 수 있다

ACA에서 보안 경계는 **환경**이지 앱이 아닙니다. 같은 환경의 앱들은 같은 가상 네트워크에 있고 내부 이름으로 서로에게 도달할 수 있습니다. 따라서 담당자 간 네트워크 격리는 존재하지 않습니다.

- `infra/platform.bicep`은 복제본 간 트래픽 암호화(`peerTrafficConfiguration`)를 켭니다.
- 인증이 필요한 앱은 Microsoft Entra 인증을 앱 수준에서 적용합니다.
- 외부 공개가 필요 없는 앱은 `ingress.external: false`로 두되, 그것만으로 다른 담당자의 앱이 차단되지는 않는다는 점을 기억합니다.
- 담당자 간 네트워크 격리가 요구사항이라면 그 담당자는 모델 A로 보내야 합니다.

### 3.3 오프보딩이 `az group delete` 하나로 끝나지 않는다

공유 RG에 있는 역할 할당과 레지스트리 콘텐츠는 담당자 RG를 지워도 **남습니다.** 관리 ID가 사라지면서 "Identity not found" 상태의 고아 역할 할당이 됩니다.

`scripts/offboard-business-user.sh`가 순서대로 처리합니다.

1. 담당자 RG의 관리 ID 주체 ID를 **먼저 수집** (RG를 지우면 조회 불가)
2. 공유 RG 범위의 역할 할당 삭제
3. 공유 레지스트리에서 해당 담당자 리포지토리 삭제
4. 담당자 본인의 직접 역할 할당 삭제
5. 담당자 RG 삭제

`--delete-resource-group` 없이 실행하면 삭제 없이 대상만 출력하는 시험 실행이 됩니다.

### 3.4 공유 리소스 비용은 자동으로 나뉘지 않는다

담당자 RG의 비용은 RG 필터로 정확히 뽑히지만, 공유 레지스트리·환경·작업 영역의 고정비는 Azure가 담당자별로 쪼개 주지 않습니다. 태그로도 불가능합니다.

- 공유 고정비는 담당자 수로 균등 배분하거나 IT 공통 비용으로 처리합니다.
- 변동비(앱 실행 시간, 로그 수집량)만 담당자 RG 기준으로 실비 청구합니다.
- Log Analytics는 `ContainerAppConsoleLogs_CL`을 앱 이름으로 그룹화하면 담당자별 수집량을 근사할 수 있습니다.

### 3.5 공유 RG에는 담당자 권한을 절대 주지 않는다

공유 RG에 `Contributor`를 주면 다른 담당자의 리소스를 지울 수 있습니다. 그래서 모델 B에서는 **프로비저닝을 IT 또는 파이프라인이 대행**합니다. `provision-user-workload.sh`를 실행하는 주체에게는 다음이 필요합니다.

| 범위 | 역할 | 이유 |
| --- | --- | --- |
| 담당자 RG | `Contributor` + `Role Based Access Control Administrator` | 앱·관리 ID 생성 및 배포 ID의 RG 범위 역할 할당 |
| 공유 RG | `Role Based Access Control Administrator` | 리포지토리·환경 범위 역할 할당 생성 |

스크립트는 기존 담당자 RG에만 워크로드를 배포하고, 공유 RG에는 ARM 배포를 만들지 않습니다. `User Access Administrator` 대신 `Role Based Access Control Administrator`를 쓰는 이유는 후자가 `roleAssignments/write`, `roleAssignments/delete`, `*/read`만 갖고 있고 **부여 가능한 역할을 조건으로 제한**할 수 있기 때문입니다. 자동화 신원이 자신에게 `Owner`를 부여하는 권한 상승을 막습니다.

---

## 4. 큐·데이터베이스가 필요해지면

여기서부터는 이 저장소가 템플릿을 제공하지 않고 **판단 기준과 절차만** 제공합니다. 조직마다 데이터 요구사항이 달라 일괄 적용이 위험하기 때문입니다.

### 4.1 먼저 알아야 할 제약: 자식 리소스는 부모의 RG를 상속한다

"네임스페이스는 공유하되 큐만 담당자 RG에 두기"는 **불가능합니다.**

```text
/subscriptions/../resourceGroups/rg-platform-shared/providers/
   Microsoft.ServiceBus/namespaces/sb-platform/queues/jiyoon-orders
   └──────────── 이 부분이 RG를 결정한다 ────────────┘
```

큐, 토픽, 데이터베이스, 컨테이너는 모두 부모 리소스의 자식이며 부모의 RG에 속합니다. 다른 RG로 옮길 수 없습니다. 따라서 선택지는 둘뿐입니다.

| | 공유 인스턴스 (자식 = 담당자) | 전용 인스턴스 (인스턴스 = 담당자) |
| --- | --- | --- |
| 리소스 위치 | 공유 RG | **담당자 RG** |
| 격리 지점 | 엔티티 범위 RBAC 또는 DB 권한 | RG 경계 그대로 |
| 비용 | 인스턴스 1개 고정비 | 담당자 수 × 인스턴스 고정비 |
| 오프보딩 | 개별 삭제 절차 필요 | `az group delete` 로 함께 삭제 |
| 비용 귀속 | 자동 분리 불가 | 태그로 자동 |
| 백업·복원·성능 | 인스턴스 단위로 공유 | 완전 분리 |

### 4.2 서비스별 격리 지점

핵심은 **자식 엔티티가 Azure RBAC 경계인지**입니다. 서비스마다 다릅니다.

| 서비스 | 공유 단위 | 담당자 단위 | 격리 제어 지점 | 권장 |
| --- | --- | --- | --- | --- |
| **Service Bus** | Namespace | Queue / Topic | Azure RBAC를 **큐 범위**로 할당 | 공유 |
| **Storage Queue / Blob** | Storage Account | Queue / Container | Azure RBAC를 **큐·컨테이너 범위**로 할당 | 공유 |
| **Cosmos DB** | Account | Database / Container | 데이터 평면 RBAC를 `/dbs/x/colls/y` 범위로 | 공유 |
| **Azure SQL** | Server + Elastic Pool | Database | DB가 독립 ARM 리소스, Entra 포함 사용자 | 공유 |
| **PostgreSQL Flexible** | Server | Database / Schema | Azure RBAC 없음. **Postgres ROLE / GRANT** 만이 경계 | 전용 |
| **Redis** | Instance | 사실상 없음 | Entra 액세스 정책의 키 패턴 | 전용 |

판단 기준은 두 가지입니다.

1. **엔티티 범위 Azure RBAC를 지원하는가?** 지원하면 공유해도 격리 강도가 전용과 거의 같습니다. Service Bus와 Storage가 여기에 해당하며, 공유하지 않을 이유가 거의 없습니다.
2. **운영 작업이 인스턴스 단위인가?** 백업·복원·시점 복구·버전 업그레이드·성능 계층이 인스턴스 단위라면, 공유 시 한 담당자의 복원 요청이 전원에게 영향을 줍니다. 관계형 데이터베이스가 대표적입니다.

### 4.3 큐: 공유 네임스페이스 + 큐 범위 RBAC

Service Bus는 역할 할당 범위를 네임스페이스뿐 아니라 **큐, 토픽, 구독**까지 좁힐 수 있습니다. 담당자마다 네임스페이스를 만들 실익이 없습니다.

```bash
PLATFORM_RG="rg-platform-shared"
NAMESPACE="sb-platform"
QUEUE="jiyoon-orders"
APP_PRINCIPAL_ID="$(az containerapp show \
  --name business-app --resource-group rg-sales-jiyoon-dev \
  --query identity.principalId --output tsv)"

az servicebus queue create \
  --resource-group "$PLATFORM_RG" --namespace-name "$NAMESPACE" --name "$QUEUE" --output none

QUEUE_ID="$(az servicebus queue show \
  --resource-group "$PLATFORM_RG" --namespace-name "$NAMESPACE" --name "$QUEUE" \
  --query id --output tsv)"

az role assignment create \
  --role "Azure Service Bus Data Sender" \
  --assignee-object-id "$APP_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --scope "$QUEUE_ID"

az role assignment create \
  --role "Azure Service Bus Data Receiver" \
  --assignee-object-id "$APP_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --scope "$QUEUE_ID"
```

네임스페이스를 만들 때 **공유 SAS 키 인증을 꺼서** 담당자가 키를 복사해 다른 큐에 접근하는 경로를 없앱니다.

```bash
az servicebus namespace create \
  --resource-group "$PLATFORM_RG" --name "$NAMESPACE" --sku Standard \
  --min-tls 1.2 --output none
az servicebus namespace update \
  --resource-group "$PLATFORM_RG" --name "$NAMESPACE" --disable-local-auth true --output none
```

앱은 연결 문자열 없이 관리 ID로 접근합니다.

```python
from azure.identity import DefaultAzureCredential
from azure.servicebus import ServiceBusClient

client = ServiceBusClient(os.environ["SERVICE_BUS_FQDN"], DefaultAzureCredential())
```

컨테이너 앱에는 비밀이 아니라 주소만 주입합니다.

```bash
az containerapp update \
  --name business-app --resource-group rg-sales-jiyoon-dev \
  --set-env-vars \
    "SERVICE_BUS_FQDN=${NAMESPACE}.servicebus.windows.net" \
    "SERVICE_BUS_QUEUE=${QUEUE}"
```

### 4.4 데이터베이스: 기본은 전용, 비용이 우선이면 공유

**전용을 기본으로 두는 이유**는 PostgreSQL Flexible Server에 데이터베이스 단위 Azure RBAC가 없기 때문입니다. 격리가 전적으로 Postgres 내부 권한에 달려 있고, 백업·복원·업그레이드가 서버 단위로 묶입니다. 전용이면 담당자 RG 안에 서버가 들어가므로 RG 경계가 그대로 유지되고 오프보딩도 단순해집니다.

```bash
ENTRA_ADMIN_UPN="$(az account show --query user.name --output tsv)"
ENTRA_ADMIN_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv)"

az postgres flexible-server create \
  --resource-group rg-sales-jiyoon-dev --name pg-sales-jiyoon \
  --location koreacentral --tier Burstable --sku-name Standard_B1ms \
  --storage-size 32 --version 16 \
  --microsoft-entra-auth Enabled --password-auth Disabled \
  --admin-object-id "$ENTRA_ADMIN_OBJECT_ID" \
  --admin-display-name "$ENTRA_ADMIN_UPN" \
  --admin-type User \
  --yes --output none
```

암호 인증을 끄면 담당자 RG 안에서도 장기 비밀이 생기지 않습니다. Entra 그룹이나 서비스 주체를 관리자로 쓸 때는 해당 객체 ID·표시 이름과 `--admin-type`을 알맞게 바꿉니다.

**공유로 가야 한다면** 담당자마다 데이터베이스와 역할을 만들고 기본 접근을 회수해야 합니다. 이 단계는 ARM으로 할 수 없고 **데이터 평면 작업**이라 Entra 관리자로 `psql`을 실행해야 합니다.

```sql
-- 담당자 앱의 관리 ID를 Postgres 역할로 등록한다
SELECT * FROM pgaadauth_create_principal('id-sales-jiyoon-app', false, false);

CREATE DATABASE db_jiyoon OWNER "id-sales-jiyoon-app";

-- 이 한 줄이 빠지면 다른 담당자가 이 데이터베이스에 접속할 수 있다
REVOKE CONNECT ON DATABASE db_jiyoon FROM PUBLIC;
```

마지막 `REVOKE`가 공유 PostgreSQL에서 가장 흔한 사고 지점입니다. `CREATE DATABASE`만 하고 끝내면 격리가 되어 있지 않습니다.

앱은 Entra 토큰을 비밀번호 자리에 넣어 접속하므로 저장된 자격 증명이 없습니다.

```python
import os

import psycopg
from azure.identity import DefaultAzureCredential

cred = DefaultAzureCredential()
token = cred.get_token("https://ossrdbms-aad.database.windows.net/.default").token
conn = psycopg.connect(host=os.environ["PGHOST"], dbname=os.environ["PGDATABASE"],
                       user=os.environ["PGUSER"], password=token, sslmode="require")
```

### 4.5 담당자에게 제공하는 방식

담당자는 공유 RG에 권한이 없으므로 큐나 데이터베이스를 직접 만들 수 없습니다. 셀프서비스를 유지하려면 **선언 → 승인 → 대행 실행** 경로가 필요합니다.

```text
① 담당자가 저장소에 선언 파일을 PR
        ↓
② CODEOWNERS 기반 IT 승인 + 보호된 GitHub environment
        ↓
③ Actions가 플랫폼 관리 ID(OIDC)로 대행 실행
   ├─ 제어 평면: 큐·데이터베이스 생성, 엔티티 범위 역할 할당
   ├─ 데이터 평면: psql 로 ROLE 생성과 REVOKE
   └─ 앱에 엔드포인트를 환경 변수로 주입 (비밀 없음)
```

선언 파일은 담당자가 Azure를 몰라도 쓸 수 있어야 하고, PR diff 자체가 감사 기록이 됩니다.

```yaml
# platform/users/jiyoon.yaml
user: jiyoon@contoso.com
resourceGroup: rg-sales-jiyoon-dev
messaging:
  mode: shared
  queues: [orders]
database:
  mode: dedicated
  name: sales
```

Bicep과 스크립트를 직접 유지하고 싶지 않다면 **Azure Deployment Environments(Dev Center)** 가 이 파이프라인을 대체합니다. IT가 카탈로그에 템플릿을 등록하면 담당자가 Azure 권한 없이 환경을 요청하고, 승인·만료·자동 삭제가 내장되어 오프보딩 부담도 줄어듭니다. 다만 카탈로그 단위가 커서 "큐 하나만 추가" 같은 세밀한 요청에는 PR 방식이 더 적합합니다.

---

## 5. 모델 선택 기준

| 상황 | 권장 |
| --- | --- |
| 담당자 5명 이하, 실습 | 모델 A (현행 유지) |
| 담당자가 늘어 레지스트리 고정비와 환경 쿼터가 부담 | **모델 B** |
| 담당자 간 네트워크 격리가 요구사항 | 모델 A |
| 담당자가 서로 다른 리전·규정 준수 요건 | 모델 A 또는 구독 분리 |
| 운영 환경, 청구 분리가 필수 | 담당자별 구독 |

한 조직 안에서 섞어 써도 됩니다. 개발은 모델 B로 밀도를 높이고, 운영으로 승격할 때 모델 A나 별도 구독으로 옮기는 방식이 일반적입니다.

---

## 6. 더 넓은 격리 선택지

이 저장소가 다루지 않지만 규모가 커지면 검토해야 할 경계입니다.

| 방법 | 경계 | 얻는 것 | 치르는 비용 |
| --- | --- | --- | --- |
| 테넌트 분리 | Entra 테넌트 | 최상위 ID·정책 격리 | 운영 복잡도 급증 |
| 관리 그룹 계층 | Management Group | 정책·RBAC 상속을 부서·환경 단위로 일괄 적용 | 리소스를 직접 담지 못함 |
| 담당자별 구독 | Subscription | 쿼터·비용·정책 완전 분리, 청구서 분리 | 구독 수 증가, 생성 자동화 필요 |
| 담당자별 RG | Resource Group | 단순함, 삭제 한 번의 오프보딩 | 구독 쿼터와 리전 제한은 공유 |
| Entra PIM | 시간 | 상시 권한 제거, 승격 시에만 부여 | 승인 절차 운영 필요 |

현재 저장소는 담당자에게 자기 RG의 상시 `Owner`를 부여합니다. 개선 여지가 가장 큰 지점은 이를 `Contributor` + PIM 승격으로 낮추는 것입니다. `Owner`는 역할 위임과 예산 변경까지 가능하기 때문입니다.

---

## 공식 참고 자료

- [Azure Container Apps 환경](https://learn.microsoft.com/azure/container-apps/environment)
- [Azure Container Apps 할당량](https://learn.microsoft.com/azure/container-apps/quotas)
- [ACR ABAC 리포지토리 권한](https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions)
- [Service Bus 관리 ID 및 RBAC 범위](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity)
- [PostgreSQL Flexible Server의 Microsoft Entra 인증](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)
- [Azure Deployment Environments](https://learn.microsoft.com/azure/deployment-environments/overview-what-is-azure-deployment-environments)

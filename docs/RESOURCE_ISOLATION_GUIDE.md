# 공유 자원 격리 가이드

## 이 문서의 목적

이 저장소는 다음 구조를 고정 운영 모델로 사용합니다.

- ACA 환경, ACR, Log Analytics는 IT 소유 공유 RG에 배치
- Container App과 GitHub Actions 배포 ID는 담당자별 RG에 배치
- ACR 이미지는 담당자별 리포지토리와 ABAC 조건으로 격리
- 큐·데이터베이스는 서비스별 데이터 평면 격리 능력에 따라 공유 또는 담당자 RG 배치를 결정

이 문서는 공유 경계와 필수 가드레일, 새 자원을 추가할 때의 판단 기준을 설명합니다.

## 1. 고정 아키텍처

```text
rg-platform-shared                  ← IT 소유
  ├─ Container Apps environment     ← 네트워크·코어 쿼터 공유
  ├─ Container Registry             ← ABAC 리포지토리 격리
  └─ Log Analytics workspace        ← 로그 수집 공유

rg-sales-jiyoon-dev                 ← 현업 담당자 Owner
  ├─ Container App
  └─ GitHub Actions 배포 ID

rg-hr-minsu-dev                     ← 다른 현업 담당자 Owner
  ├─ Container App
  └─ GitHub Actions 배포 ID
```

리소스 그룹 자체는 무료이고 쿼터를 소비하지 않습니다. 담당자별 RG는 다음 경계로 유지합니다.

- 현업 담당자 RBAC 범위
- 앱 실행 비용 귀속
- Azure Policy 적용
- 담당자 이동·퇴사 시 오프보딩 단위

중복 비용과 쿼터를 만드는 플랫폼 리소스만 공유합니다.

## 2. 권한 경계

| 대상 | 범위 | 역할 |
| --- | --- | --- |
| 현업 담당자 | 자기 RG | `Owner` |
| 현업 담당자 | 공유 RG | **없음** |
| GitHub Actions 배포 ID | 자기 RG | `Contributor` |
| GitHub Actions 배포 ID | 공유 ACR | `Reader` |
| GitHub Actions 배포 ID | 공유 ACR | 조건부 `Container Registry Repository Writer` |
| GitHub Actions 배포 ID | 공유 ACA 환경 | `Container Apps Contributor` |
| Container App 시스템 ID | 공유 ACR | 조건부 `Container Registry Repository Reader` |

공유 ACR의 `Reader`는 `az acr show`와 `az acr login`에 필요한 관리 평면 읽기만 제공합니다. 이미지 데이터 읽기·쓰기는 Repository 역할과 ABAC 조건이 제어합니다.

공유 RG에 현업 담당자 `Contributor`를 부여하면 다른 담당자의 앱이 사용하는 환경과 레지스트리를 변경할 수 있으므로 금지합니다.

## 3. ACR 리포지토리 격리

`infra/platform.bicep`은 ACR을 ABAC 모드로 만듭니다.

```bicep
roleAssignmentMode: 'AbacRepositoryPermissions'
```

ABAC 모드에서는 다음 리포지토리 역할을 사용합니다.

- `Container Registry Repository Writer`
- `Container Registry Repository Reader`

`provision-user-workload.sh`는 담당자 RG 이름을 포함한 리포지토리 이름을 만듭니다.

```text
rg-sales-jiyoon-dev/business-app
```

역할 할당 조건:

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

Repository 역할에 조건이 없으면 레지스트리의 모든 리포지토리에 접근할 수 있습니다. 프로비저닝 스크립트는 다음을 확인하고 조건이 안전하지 않으면 중단합니다.

1. ACR이 `AbacRepositoryPermissions` 모드인지 확인
2. Repository Writer와 Reader에 담당자 리포지토리 조건 적용
3. 기존 역할의 조건이 예상과 다르면 재사용하지 않고 오류 처리

`infra/platform.bicep`은 `roleAssignmentMode`를 지원하는 ACR API 버전을 사용하며, `provision-shared-platform.sh`가 배포 후 실제 모드를 다시 확인합니다.

## 4. 반드시 적용할 공유 플랫폼 가드레일

### 4.1 환경 코어 쿼터

`Managed Environment Consumption Cores`는 공유 ACA 환경 안의 모든 활성 replica가 나눠 씁니다.

```bash
az containerapp env list-usages \
  --resource-group rg-platform-shared \
  --name cae-rg-platform-shared \
  --output table
```

`infra/user-workload.bicep`은 `maxReplicas`를 최대 10으로 제한하고 기본값 2를 사용합니다. 담당자 수가 증가하기 전에 코어 쿼터를 확인하고 상향합니다.

### 4.2 네트워크

같은 ACA 환경의 앱들은 같은 가상 네트워크에 있으며 내부 이름으로 서로 호출할 수 있습니다.

- 복제본 간 트래픽 암호화를 사용합니다.
- 앱 수준에서 Microsoft Entra 인증과 권한 검사를 적용합니다.
- 외부 공개가 필요 없는 앱은 `ingress.external: false`를 사용합니다.
- 담당자 간 네트워크 격리가 필수인 워크로드는 별도 플랫폼 또는 구독으로 이동합니다.

### 4.3 비용

담당자 RG 안의 앱 비용은 Resource group 필터로 집계할 수 있습니다. 공유 ACR, ACA 환경, Log Analytics의 비용은 담당자별로 자동 분리되지 않습니다.

- 공유 고정비는 균등 배분하거나 IT 공통 비용으로 처리
- 앱 실행 비용은 담당자 RG 기준으로 집계
- 로그 사용량은 `ContainerAppConsoleLogs_CL`을 앱 이름으로 그룹화해 근사
- 담당자 RG마다 월 예산과 알림 설정

### 4.4 오프보딩

담당자 RG를 삭제해도 공유 ACR 리포지토리와 공유 리소스 범위 역할 할당은 남습니다.

`offboard-business-user.sh`는 다음 순서로 처리합니다.

1. RG 삭제 전에 관리 ID principal ID 수집
2. 공유 ACR·ACA 환경 범위 역할 할당 삭제
3. 담당자 ACR 리포지토리 삭제
4. 담당자 직접 역할 할당 삭제
5. 담당자 RG 삭제

스크립트 실행자에게는 공유 ACR의 `Container Registry Repository Contributor`가 필요합니다. 권한이 없으면 리포지토리 조회 단계에서 삭제 전에 중단합니다.

`--delete-resource-group` 없이 실행하면 삭제 대상을 확인하는 시험 실행입니다.

## 5. 큐와 데이터베이스 추가 기준

### 5.1 자식 리소스는 부모 RG를 상속한다

공유 Service Bus Namespace 안의 Queue를 담당자 RG에 둘 수는 없습니다.

```text
/subscriptions/.../resourceGroups/rg-platform-shared/providers/
  Microsoft.ServiceBus/namespaces/sb-platform/queues/jiyoon-orders
```

Queue, Topic, Database, Container 같은 자식 리소스는 부모 리소스의 RG에 속합니다. 따라서 격리는 다음 중 하나로 구현합니다.

1. 공유 인스턴스 안에서 엔티티 범위 RBAC 또는 데이터베이스 권한 적용
2. 담당자 RG에 개별 인스턴스 배치

### 5.2 서비스별 권장 경계

| 서비스 | 공유 인스턴스 | 담당자 단위 | 격리 제어 | 권장 |
| --- | --- | --- | --- | --- |
| Service Bus | Namespace | Queue / Topic | Queue·Topic 범위 Azure RBAC | 공유 |
| Storage Queue / Blob | Storage Account | Queue / Container | 엔티티 범위 Azure RBAC | 공유 |
| Cosmos DB | Account | Database / Container | 데이터 평면 RBAC scope | 공유 |
| Azure SQL | Server / Elastic Pool | Database | Entra 포함 사용자와 DB 권한 | 요구사항별 |
| PostgreSQL Flexible | Server | Database / Schema | Postgres ROLE / GRANT | 담당자 RG 개별 서버 우선 |
| Redis | Instance | 키 공간 | 액세스 정책과 키 패턴 | 담당자 RG 개별 인스턴스 우선 |

판단 질문:

1. 담당자 엔티티가 Azure RBAC scope가 될 수 있는가?
2. 백업·복원·업그레이드·성능 계층이 인스턴스 단위인가?
3. 담당자 데이터의 삭제와 보존을 독립적으로 처리할 수 있는가?
4. 공유 장애와 쿼터 경합을 허용할 수 있는가?

## 6. Service Bus Queue 예시

공유 Namespace 안에 담당자 Queue를 만들고 Container App 시스템 ID에 Queue 범위 역할만 부여합니다.

```bash
PLATFORM_RG="rg-platform-shared"
NAMESPACE="sb-platform"
QUEUE="jiyoon-orders"
USER_RG="rg-sales-jiyoon-dev"

APP_PRINCIPAL_ID="$(az containerapp show \
  --name business-app \
  --resource-group "$USER_RG" \
  --query identity.principalId \
  --output tsv)"

az servicebus queue create \
  --resource-group "$PLATFORM_RG" \
  --namespace-name "$NAMESPACE" \
  --name "$QUEUE" \
  --output none

QUEUE_ID="$(az servicebus queue show \
  --resource-group "$PLATFORM_RG" \
  --namespace-name "$NAMESPACE" \
  --name "$QUEUE" \
  --query id --output tsv)"

az role assignment create \
  --role "Azure Service Bus Data Sender" \
  --assignee-object-id "$APP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$QUEUE_ID"

az role assignment create \
  --role "Azure Service Bus Data Receiver" \
  --assignee-object-id "$APP_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --scope "$QUEUE_ID"
```

공유 SAS 키로 다른 Queue에 접근하지 못하도록 Namespace의 로컬 인증을 끕니다.

```bash
az servicebus namespace update \
  --resource-group "$PLATFORM_RG" \
  --name "$NAMESPACE" \
  --disable-local-auth true \
  --output none
```

앱에는 비밀 대신 Namespace 주소와 Queue 이름만 제공합니다.

```bash
az containerapp update \
  --name business-app \
  --resource-group "$USER_RG" \
  --set-env-vars \
    "SERVICE_BUS_FQDN=${NAMESPACE}.servicebus.windows.net" \
    "SERVICE_BUS_QUEUE=${QUEUE}"
```

## 7. PostgreSQL 예시

PostgreSQL Flexible Server는 데이터베이스 단위 Azure RBAC가 없고 백업·복원이 서버 단위입니다. 기본은 담당자 RG에 개별 서버를 배치하는 것입니다.

```bash
USER_RG="rg-sales-jiyoon-dev"
ENTRA_ADMIN_UPN="$(az account show --query user.name --output tsv)"
ENTRA_ADMIN_OBJECT_ID="$(az ad signed-in-user show --query id --output tsv)"

az postgres flexible-server create \
  --resource-group "$USER_RG" \
  --name pg-sales-jiyoon \
  --location koreacentral \
  --tier Burstable \
  --sku-name Standard_B1ms \
  --storage-size 32 \
  --version 16 \
  --microsoft-entra-auth Enabled \
  --password-auth Disabled \
  --admin-object-id "$ENTRA_ADMIN_OBJECT_ID" \
  --admin-display-name "$ENTRA_ADMIN_UPN" \
  --admin-type User \
  --yes --output none
```

비용 때문에 서버를 공유해야 한다면 담당자별 Database와 ROLE을 만들고 기본 접속 권한을 회수합니다.

```sql
SELECT * FROM pgaadauth_create_principal('id-sales-jiyoon-app', false, false);
CREATE DATABASE db_jiyoon OWNER "id-sales-jiyoon-app";
REVOKE CONNECT ON DATABASE db_jiyoon FROM PUBLIC;
```

`REVOKE CONNECT ... FROM PUBLIC`이 빠지면 다른 역할이 Database에 접속할 수 있습니다.

앱은 Entra 토큰을 비밀번호 위치에 사용합니다.

```python
import os

import psycopg
from azure.identity import DefaultAzureCredential

credential = DefaultAzureCredential()
token = credential.get_token(
    "https://ossrdbms-aad.database.windows.net/.default"
).token

connection = psycopg.connect(
    host=os.environ["PGHOST"],
    dbname=os.environ["PGDATABASE"],
    user=os.environ["PGUSER"],
    password=token,
    sslmode="require",
)
```

## 8. 현업 요청 처리

현업 담당자는 공유 RG에 권한이 없으므로 큐나 데이터베이스를 직접 만들지 않습니다. 선언, 승인, 대행 실행 흐름을 사용합니다.

```text
① 현업 담당자가 선언 파일을 PR
        ↓
② CODEOWNERS 기반 IT 승인 + 보호된 GitHub Environment
        ↓
③ 플랫폼 관리 ID가 OIDC로 실행
   ├─ 자원과 엔티티 생성
   ├─ 엔티티 범위 역할 할당
   ├─ 필요한 데이터 평면 권한 구성
   └─ 앱에 비밀이 아닌 엔드포인트 주입
```

예시 선언:

```yaml
user: jiyoon@contoso.com
resourceGroup: rg-sales-jiyoon-dev
messaging:
  queues: [orders]
database:
  placement: user-resource-group
  name: sales
```

큐·데이터베이스 삭제는 보존 정책을 확인한 뒤 수행합니다. 담당자 RG 오프보딩 스크립트가 공유 인스턴스의 자식 데이터를 자동 삭제하지 않는 이유입니다.

## 9. 이 가이드의 범위 밖

다음 요구사항은 현재 공유 플랫폼에 수용하지 않습니다.

- 담당자 간 네트워크 완전 격리
- 담당자별 독립 리전 또는 규정 준수 경계
- 담당자별 독립 쿼터와 청구서
- 공유 환경 장애 영향을 허용할 수 없는 운영 워크로드

이 경우 별도 ACA 환경, 별도 플랫폼 RG, 또는 별도 구독을 IT 아키텍처 절차로 설계합니다.

## 공식 참고 자료

- [Azure Container Apps 환경](https://learn.microsoft.com/azure/container-apps/environment)
- [Azure Container Apps 할당량](https://learn.microsoft.com/azure/container-apps/quotas)
- [ACR ABAC 리포지토리 권한](https://learn.microsoft.com/azure/container-registry/container-registry-rbac-abac-repository-permissions)
- [Service Bus 관리 ID와 RBAC](https://learn.microsoft.com/azure/service-bus-messaging/service-bus-managed-service-identity)
- [PostgreSQL Flexible Server Microsoft Entra 인증](https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-azure-ad-authentication)

# 현업 담당자 가이드: Copilot으로 FastAPI 앱을 Azure에 자율 배포하기

## 이 가이드에서 할 일

1. GitHub `production` 환경을 만들고 `main` 배포와 IT/서비스 오너 승인을 설정합니다.
2. 모델 A는 프로비저닝 스크립트를 직접 실행합니다. 모델 B는 저장소 이름을 IT에 전달하고 프로비저닝 완료를 기다립니다.
3. 코드를 `main`에 푸시하고 승인을 완료합니다.

**완료 기준:** GitHub Actions가 성공하고 배포된 컨테이너 앱 URL의 `/healthz`가 `status: ok`, 커밋 SHA, `production` 환경을 반환합니다.

> **실습 원칙:** 각 체크포인트가 통과한 뒤 다음 단계로 진행합니다. 오류가 나면 마지막 표의 조치를 먼저 적용하고, 정상 상태를 확인한 뒤 재시도합니다.

## 1. 시작 전 확인

IT 부서에서 본인에게 전용 RG와 그 RG 범위의 `Owner`를 부여했는지 확인합니다. 예:

```text
rg-sales-jiyoon-dev
```

`Owner`는 이 RG 안에서 ACA, ACR, Log Analytics, 관리 ID와 역할을 만들 수 있게 합니다. **다른 RG, 구독, 고객 데이터에는 접근 권한이 아닙니다.** 자기 RG의 비용과 보안 설정도 본인이 책임지고, 다른 사용자에게 불필요한 역할을 부여하지 않습니다.

필수 준비물:

- GitHub 저장소 관리자 권한
- GitHub CLI 로그인: `gh auth login`
- Azure CLI 로그인: `az login`
- Python 3.12
- GitHub Copilot 또는 Claude Code

```bash
gh auth status
az account show --query "{subscription:id, tenant:tenantId}" --output table
python3 --version
```

**체크포인트:** GitHub CLI와 Azure CLI가 본인 계정으로 로그인됐고 Python 3.12가 출력됩니다. IT가 제공한 전용 RG 이름도 준비합니다.

## 2. GitHub 저장소와 배포 환경 만들기

이 저장소를 본인 또는 팀이 관리하는 저장소로 fork한 뒤, **fork한 저장소를 clone하고 그 디렉터리에서 이후 명령을 실행합니다.**

```bash
gh repo fork <source-owner>/azure-self-service --clone
cd azure-self-service
gh repo view --json nameWithOwner --jq .nameWithOwner
```

조직 소유 저장소로 fork하려면 `gh repo fork`에 `--org <organization>`을 추가합니다. 마지막 명령이 본인 또는 팀 소유의 `<owner>/<repository>`를 출력하는지 확인합니다.

GitHub Free에서는 Environment를 공개 저장소에만 구성할 수 있습니다. 비공개 저장소는 GitHub Pro 또는 조직의 GitHub Team 이상이 필요하며, 플랜에 따라 일부 보호 규칙의 사용 범위가 다를 수 있습니다. 실습 전에 **Settings → Environments**에서 `Required reviewers`가 보이는지 확인하고, 보이지 않으면 공개 실습 저장소 또는 해당 기능을 지원하는 조직 저장소를 사용합니다.

GitHub에서 **Settings → Environments → New environment**로 `production`을 생성하고 **Deployment branches and tags**에서 `main`만 허용합니다.

운영 배포에는 IT 또는 서비스 오너를 `Required reviewer`로 추가하고 관리자 우회를 끕니다. 승인자는 먼저 해당 저장소의 collaborator 또는 조직 팀으로 접근 권한을 갖고 있어야 합니다. 이것은 현업의 개발 자율성을 유지하면서 운영 반영을 검토하는 안전장치입니다.

**체크포인트:** `production` 환경에 `main` 배포 제한과 승인자가 보입니다. 이 설정이 없으면 배포 전에 중단합니다.

모델 B를 사용한다면 현재 저장소 이름을 확인해 IT에 전달합니다.

```bash
gh repo view --json nameWithOwner --jq .nameWithOwner
```

IT가 `provision-user-workload.sh` 실행을 완료하고 `Provisioning succeeded`를 확인했다는 응답을 줄 때까지 기다립니다. 완료 응답을 받으면 다음을 실행합니다.

```bash
gh variable list --env production
```

**모델 B 체크포인트:** 모델 A의 변수 여섯 개와 `AZURE_CONTAINER_REPOSITORY`가 모두 표시됩니다. 확인 후 3절을 건너뛰고 4절부터 진행합니다.

## 3. 내 RG에 Azure 배포 환경을 만든다

> **먼저 IT에 확인하세요.** 조직이 **공유 플랫폼 모델(모델 B)** 을 쓴다면 이 절을 실행하지 않습니다. 2절에서 저장소 이름을 전달받은 IT가 `provision-user-workload.sh`로 대신 프로비저닝합니다. 완료 후 4절부터 이어가며, `production` 변수에는 `AZURE_CONTAINER_REPOSITORY`가 하나 더 추가됩니다.

저장소 루트에서 본인 RG와 GitHub 저장소 이름을 넣어 실행합니다.

```bash
SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
RESOURCE_GROUP="rg-sales-jiyoon-dev"
GITHUB_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

./scripts/provision-team-environment.sh \
  --subscription-id "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --location "koreacentral" \
  --github-repository "$GITHUB_REPOSITORY"
```

스크립트가 만드는 리소스는 모두 내 RG에 들어갑니다.

| 리소스 | 용도 |
| --- | --- |
| Azure Container Registry | GitHub Actions가 만든 컨테이너 이미지 저장 |
| Container Apps environment와 Container App | FastAPI 앱 실행, HTTPS ingress, scale-to-zero |
| Log Analytics workspace | 컨테이너 로그 조회 |
| GitHub Actions 관리 ID | OIDC로 Azure에 로그인해 이미지 Push와 ACA 배포 |

스크립트는 GitHub CLI를 사용해 `production` 환경의 OIDC·RG·ACR·ACA 변수 여섯 개를 자동 등록합니다. 실행 전에 `production` 환경과 승인·브랜치 정책을 설정해야 하며, 스크립트는 이 보호 설정을 변경하지 않습니다.

```bash
gh variable list --env production
```

**체크포인트:** `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, `AZURE_CONTAINER_REGISTRY_NAME`, `AZURE_CONTAINER_APP_NAME`이 모두 표시되고 스크립트가 출력한 Bootstrap URL이 열립니다.

## 4. FastAPI 앱을 Copilot 또는 Claude Code로 개발한다

### 로컬 실행

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests -v
uvicorn src.app:app --reload
```

- 화면: `http://127.0.0.1:8000`
- 상태 점검: `http://127.0.0.1:8000/healthz`
- 자동 API 문서: `http://127.0.0.1:8000/docs`

별도 터미널에서 다음을 실행합니다.

```bash
curl --fail http://127.0.0.1:8000/healthz
```

**체크포인트:** JSON 응답의 `status`가 `ok`입니다.

### AI에 요청하는 예시

```text
src/app.py에 영업 요청을 등록하는 POST /requests API를 추가해줘.
Pydantic 모델로 요청 본문을 검증하고 OpenAPI 문서에 설명을 넣어줘.
/healthz 계약은 유지하고 tests/에 성공·검증 실패 테스트를 추가해줘.
Dockerfile과 GitHub Actions OIDC 인증은 변경하지 마.
```

AI가 만든 코드는 diff와 테스트 결과를 반드시 검토합니다. 고객 정보, 토큰, 비밀, Azure 자격 증명을 프롬프트·소스·로그에 넣지 않습니다.

## 5. GitHub Actions로 ACA에 배포한다

```bash
git add src tests
git commit -m "Add sales request API"
git push origin main
```

`.github/workflows/deploy.yml`은 테스트 후 GitHub OIDC 토큰으로 Azure에 로그인합니다. 커밋 SHA로 컨테이너 이미지를 ACR에 Push하고, ACA의 새 revision을 배포합니다. GitHub **Actions**에서 `Build and deploy to Azure Container Apps`가 성공하면 로그의 `Application URL`을 열고 `/healthz`를 확인합니다.

```bash
gh run list --workflow deploy.yml --limit 1
SUBSCRIPTION_ID="$(gh variable get AZURE_SUBSCRIPTION_ID --env production)"
RESOURCE_GROUP="$(gh variable get AZURE_RESOURCE_GROUP --env production)"
CONTAINER_APP_NAME="$(gh variable get AZURE_CONTAINER_APP_NAME --env production)"
FQDN="$(az containerapp show \
  --subscription "$SUBSCRIPTION_ID" \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CONTAINER_APP_NAME" \
  --query properties.configuration.ingress.fqdn \
  --output tsv)"
curl --fail "https://$FQDN/healthz"
```

**체크포인트:** 최근 workflow의 결론이 `success`이고 `/healthz`의 `release`는 방금 푸시한 커밋 SHA, `environment`는 `production`입니다.

## 6. 운영·비용 책임

- ACA **Revisions**에서 새 revision 상태와 이전 정상 revision을 확인합니다. 문제 시 이전 정상 commit을 다시 배포하거나 해당 revision으로 롤백합니다.
- Log Analytics workspace에서 애플리케이션 로그를 확인합니다.
- Azure portal의 내 RG **Cost Management**에서 일별 비용 추이를 봅니다. scale-to-zero가 필요한 개발 앱은 `minReplicas: 0`을 유지합니다.
- IT가 설정한 예산 알림을 받으면 불필요한 ACA revision, ACR 이미지, Log Analytics 보존 기간과 고정 replica 설정을 먼저 확인합니다.
- 사용을 종료한 실습 환경은 IT와 보존 정책을 확인한 뒤 RG를 삭제합니다.

## 7. 자주 발생하는 문제

| 증상 | 조치 |
| --- | --- |
| OIDC Azure 로그인 실패 | `production` environment와 GitHub CLI 로그인을 확인한 뒤 프로비저닝 스크립트를 다시 실행합니다. 스크립트가 현재 저장소의 OIDC subject와 환경 변수를 다시 검증합니다. |
| ACR Push 거부 | 모델 A는 배포 ID의 `AcrPush`를 확인합니다. 모델 B는 공유 ACR의 `Reader`, 조건이 붙은 `Container Registry Repository Writer`, `AZURE_CONTAINER_REPOSITORY` 값을 확인합니다. |
| 이미지 Pull 또는 앱 기동 실패 | 모델 A는 앱 시스템 ID의 `AcrPull`을 확인합니다. 모델 B는 조건이 붙은 `Container Registry Repository Reader`를 확인합니다. 공통으로 포트 8000, `/healthz`, Log Analytics 로그를 확인합니다. |
| 비용 급증 | ACA replica 수, ACR 저장 이미지, Log Analytics 보존 기간을 확인하고 IT 비용 담당자에게 알림 |

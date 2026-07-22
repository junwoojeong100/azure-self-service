# 현업 담당자 가이드: Copilot으로 FastAPI 앱을 Azure에 자율 배포하기

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
- Python 3.12, Docker
- GitHub Copilot 또는 Claude Code

## 2. GitHub 저장소와 배포 환경 만들기

이 저장소를 개인 또는 팀 저장소로 복제합니다. GitHub에서 **Settings → Environments → New environment**로 `production`을 생성하고 `main` 또는 보호된 릴리스 태그만 배포하도록 제한합니다.

운영 배포에는 IT 또는 서비스 오너를 `Required reviewer`로 추가합니다. 이것은 현업의 개발 자율성을 유지하면서 운영 반영을 검토하는 안전장치입니다.

## 3. 내 RG에 Azure 배포 환경을 만든다

저장소 루트에서 본인 RG와 GitHub 저장소 이름을 넣어 실행합니다.

```bash
chmod +x scripts/provision-team-environment.sh
./scripts/provision-team-environment.sh \
  --subscription-id "<SUBSCRIPTION_ID>" \
  --resource-group "rg-sales-jiyoon-dev" \
  --location "koreacentral" \
  --github-repository "contoso/sales-automation"
```

스크립트가 만드는 리소스는 모두 내 RG에 들어갑니다.

| 리소스 | 용도 |
| --- | --- |
| Azure Container Registry | GitHub Actions가 만든 컨테이너 이미지 저장 |
| Container Apps environment와 Container App | FastAPI 앱 실행, HTTPS ingress, scale-to-zero |
| Log Analytics workspace | 컨테이너 로그 조회 |
| GitHub Actions 관리 ID | OIDC로 Azure에 로그인해 이미지 Push와 ACA 배포 |

스크립트는 GitHub CLI를 사용해 `production` 환경에 필요한 여섯 변수를 자동 등록합니다. 실행 전에 `production` 환경과 필수 승인·브랜치 정책을 설정해야 하며, 스크립트가 이를 덮어쓰지 않습니다. 값은 식별자이며 비밀이 아닙니다.

| 변수 | 값 |
| --- | --- |
| `AZURE_CLIENT_ID` | 스크립트가 출력한 관리 ID client ID |
| `AZURE_TENANT_ID` | 스크립트가 출력한 tenant ID |
| `AZURE_SUBSCRIPTION_ID` | 내 Azure 구독 ID |
| `AZURE_RESOURCE_GROUP` | 내 RG 이름 |
| `AZURE_CONTAINER_REGISTRY_NAME` | 스크립트가 만든 ACR 이름 |
| `AZURE_CONTAINER_APP_NAME` | `business-app` |

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

`.github/workflows/deploy.yml`은 테스트 후 GitHub OIDC 토큰으로 Azure에 로그인합니다. 커밋 SHA로 컨테이너 이미지를 ACR에 Push하고, ACA의 새 revision을 배포합니다. GitHub **Actions**에서 `Build and deploy to Azure Container Apps` 실행이 완료되면 로그의 `Application URL`을 엽니다.

## 6. 운영·비용 책임

- ACA **Revisions**에서 새 revision 상태와 이전 정상 revision을 확인합니다. 문제 시 이전 정상 commit을 다시 배포하거나 해당 revision으로 롤백합니다.
- Log Analytics workspace에서 애플리케이션 로그를 확인합니다.
- Azure portal의 내 RG **Cost Management**에서 일별 비용 추이를 봅니다. scale-to-zero가 필요한 개발 앱은 `minReplicas: 0`을 유지합니다.
- IT가 설정한 예산 알림을 받으면 불필요한 ACA revision, ACR 이미지, Log Analytics 보존 기간과 고정 replica 설정을 먼저 확인합니다.
- 사용을 종료한 실습 환경은 IT와 보존 정책을 확인한 뒤 RG를 삭제합니다.

## 7. 자주 발생하는 문제

| 증상 | 조치 |
| --- | --- |
| OIDC Azure 로그인 실패 | `production` environment 이름, GitHub 저장소 이름, `AZURE_*` variables와 federated credential이 일치하는지 확인 |
| ACR Push 거부 | 스크립트가 완료됐는지, GitHub Actions 관리 ID에 해당 ACR `AcrPush`가 있는지 확인 |
| 이미지 Pull 또는 앱 기동 실패 | ACA의 시스템 할당 ID `AcrPull`, 포트 8000, `/healthz`, Log Analytics 로그 확인 |
| 비용 급증 | ACA replica 수, ACR 저장 이미지, Log Analytics 보존 기간을 확인하고 IT 비용 담당자에게 알림 |

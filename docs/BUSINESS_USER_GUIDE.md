# 현업 담당자 가이드: 공유 플랫폼에 FastAPI 앱 배포하기

## 이 가이드에서 할 일

1. GitHub 저장소와 보호된 `production` 환경을 준비합니다.
2. 저장소 이름을 IT에 전달하고 Azure 워크로드 프로비저닝을 기다립니다.
3. 앱을 개발하고 `main`에 푸시해 Azure Container Apps에 배포합니다.

**완료 기준:** GitHub Actions가 성공하고 `/healthz`가 `status: ok`, 방금 배포한 커밋 SHA, `production` 환경을 반환합니다.

> 각 체크포인트가 통과한 뒤 다음 단계로 진행합니다. 현업 담당자는 자기 RG만 관리하며 공유 플랫폼 RG에는 접근하지 않습니다.

## 1. 시작 전 확인

IT에서 다음 정보를 받습니다.

- 담당자 전용 RG 이름. 예: `rg-sales-jiyoon-dev`
- 해당 RG 범위의 `Owner`
- 이 문서의 저장소 주소

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

**체크포인트:** GitHub CLI와 Azure CLI가 본인 계정으로 로그인됐고 Python 3.12가 출력됩니다. IT가 제공한 RG 이름도 준비합니다.

## 2. GitHub 저장소와 배포 환경을 만든다

이 저장소를 본인 또는 팀이 관리하는 저장소로 fork하고 clone합니다.

```bash
SOURCE_REPOSITORY="junwoojeong100/azure-self-service"
gh repo fork "$SOURCE_REPOSITORY" --clone
cd azure-self-service
gh repo view --json nameWithOwner --jq .nameWithOwner
```

조직 저장소로 fork하려면 `--org <organization>`을 추가합니다. 마지막 명령이 본인 또는 팀 소유의 `<owner>/<repository>`를 출력해야 합니다.

GitHub Free에서는 Environment를 공개 저장소에만 구성할 수 있습니다. 비공개 저장소는 GitHub Pro 또는 조직의 GitHub Team 이상이 필요합니다.

GitHub에서 **Settings → Environments → New environment**로 `production`을 만들고 다음을 설정합니다.

1. **Deployment branches and tags:** `main`만 허용
2. **Required reviewers:** IT 또는 서비스 오너
3. **Allow administrators to bypass configured protection rules:** 해제

승인자는 먼저 저장소 collaborator 또는 조직 팀으로 접근 권한을 갖고 있어야 합니다.

**체크포인트:** `production` 환경에 `main` 제한과 승인자가 표시됩니다. 설정이 없으면 다음 단계로 진행하지 않습니다.

## 3. 저장소 이름을 IT에 전달한다

```bash
GITHUB_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
echo "$GITHUB_REPOSITORY"
```

출력된 `<owner>/<repository>`를 IT에 전달합니다. IT는 담당자 RG에 Container App과 GitHub Actions 배포 ID를 만들고 `production` 환경 변수를 등록합니다.

IT가 `Provisioning succeeded`를 확인했다는 응답을 줄 때까지 기다린 뒤 다음을 실행합니다.

```bash
gh variable list --env production
```

**체크포인트:** 다음 변수가 모두 표시됩니다.

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `AZURE_RESOURCE_GROUP`
- `AZURE_CONTAINER_REGISTRY_NAME`
- `AZURE_CONTAINER_REPOSITORY`
- `AZURE_CONTAINER_APP_NAME`

IT가 전달한 Bootstrap URL도 열려야 합니다.

## 4. FastAPI 앱을 개발한다

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

별도 터미널에서 확인합니다.

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

AI가 만든 diff와 테스트 결과를 검토합니다. 고객 정보, 토큰, 비밀, Azure 자격 증명을 프롬프트·소스·로그에 넣지 않습니다.

## 5. GitHub Actions로 배포한다

```bash
git add src tests
git commit -m "Add sales request API"
git push origin main
```

워크플로는 다음 순서로 실행됩니다.

1. Python 단위 테스트
2. GitHub OIDC로 Azure 로그인
3. 담당자 전용 ACR 리포지토리에 커밋 SHA 태그로 이미지 Push
4. Container App 새 revision 배포

GitHub **Actions**에서 `Build and deploy to Azure Container Apps`의 `deploy` job이 `production` 승인을 기다리면 IT 또는 서비스 오너가 검토하고 승인합니다.

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

## 6. 운영과 비용 책임

- ACA **Revisions**에서 새 revision과 이전 정상 revision을 확인합니다.
- 문제 발생 시 이전 정상 커밋을 다시 배포하거나 정상 revision으로 롤백합니다.
- Log Analytics에서 애플리케이션 로그를 확인합니다.
- 자기 RG의 **Cost Management**에서 일별 비용을 확인합니다.
- 개발 앱은 `minReplicas: 0`을 유지합니다.
- 예산 알림을 받으면 revision 수, 로그 수집량, replica 설정을 먼저 확인하고 IT에 알립니다.
- 큐나 데이터베이스가 필요하면 직접 공유 RG를 변경하지 말고 IT 승인 절차로 요청합니다.
- 사용 종료 시 IT에 오프보딩을 요청합니다. 담당자 RG만 삭제하면 공유 ACR 리포지토리와 역할 할당이 남을 수 있습니다.

## 7. 자주 발생하는 문제

| 증상 | 조치 |
| --- | --- |
| `production` Environment를 만들 수 없음 | 저장소 공개 여부와 GitHub 플랜, 본인의 저장소 관리자 권한 확인 |
| 프로비저닝 변수가 없음 | IT가 `provision-user-workload.sh`를 완료했는지 확인하고 `gh variable list --env production` 재실행 |
| OIDC Azure 로그인 실패 | `production` Environment 이름, GitHub 승인 상태, `AZURE_CLIENT_ID` 확인 후 IT에 재프로비저닝 요청 |
| ACR 조회 또는 Push 거부 | 배포 ID의 공유 ACR `Reader`, 조건부 Repository Writer, `AZURE_CONTAINER_REPOSITORY` 확인 요청 |
| 이미지 Pull 실패 | Container App 시스템 ID의 조건부 Repository Reader 확인 요청 |
| 앱 기동 실패 | 포트 8000, `/healthz`, Container App revision 상태, Log Analytics 로그 확인 |
| 다른 담당자 앱과 네트워크 격리가 필요함 | 공유 ACA 환경은 네트워크 격리 경계가 아님. 별도 플랫폼 또는 구독을 IT에 요청 |
| 비용 급증 | replica 수, revision, 로그 수집량을 확인하고 IT 비용 담당자에게 알림 |

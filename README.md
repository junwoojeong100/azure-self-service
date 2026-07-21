# 현업 앱 배포 실습: GitHub Actions + Azure Container Apps

현업 담당자가 Claude Code 또는 GitHub Copilot으로 Python 앱을 변경해 GitHub에 푸시하면, GitHub Actions가 컨테이너 이미지를 빌드하고 Azure Container Apps에 새 리비전으로 배포하는 데모입니다.

## 빠른 시작

1. IT 담당자는 [`docs/IT_DEPARTMENT_GUIDE.md`](docs/IT_DEPARTMENT_GUIDE.md)로 담당자 전용 RG, RG 범위 `Owner`, 비용 거버넌스를 준비합니다.
2. 현업 담당자는 [`docs/BUSINESS_USER_GUIDE.md`](docs/BUSINESS_USER_GUIDE.md)로 자신의 RG에서 환경을 만들고 이 저장소를 GitHub에 올립니다.
3. `main`에 푸시하면 GitHub Actions가 배포하고, 출력된 앱 URL에서 배포 상태를 확인합니다.

## 구성

| 경로 | 용도 |
| --- | --- |
| `src/` | 실행 가능한 FastAPI 데모 앱과 단위 테스트 |
| `Dockerfile` | Azure Container Apps용 컨테이너 이미지 정의 |
| `.github/workflows/deploy.yml` | OIDC 인증, ACR 빌드/푸시, Container Apps 배포 |
| `infra/main.bicep` | 담당자별 격리 환경(ACR, Container Apps, 관리 ID) |
| `scripts/assign-resource-group-owner.sh` | IT의 담당자별 RG 범위 Owner 위임 |
| `scripts/provision-team-environment.sh` | 현업 Owner의 ACA·ACR·GitHub OIDC 환경 구성 |
| `docs/IT_DEPARTMENT_GUIDE.md` | IT 부서: RG 위임, 비용 및 거버넌스 가이드 |
| `docs/BUSINESS_USER_GUIDE.md` | 현업 담당자: Copilot 기반 자율 배포 가이드 |

## 로컬 실행

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn src.app:app --reload
```

브라우저에서 `http://127.0.0.1:8000`을 엽니다. 상태 점검은 `http://127.0.0.1:8000/healthz`, 자동 API 문서는 `http://127.0.0.1:8000/docs`입니다.

## 핵심 원칙

- GitHub Actions는 Microsoft Entra workload identity federation(OIDC)을 사용합니다. 클라이언트 비밀이나 ACR 관리자 암호를 저장하지 않습니다.
- 현업 담당자마다 전용 리소스 그룹을 만들고, 담당자에게 그 RG에만 `Owner`를 부여합니다.
- 배포용 관리 ID는 해당 리소스 그룹의 `Contributor` 및 해당 ACR의 `AcrPush`만 갖습니다.
- 실행 중인 Container App의 시스템 할당 관리 ID만 해당 ACR의 `AcrPull`을 갖습니다.

역할 경계와 비용 관리는 [IT 부서 가이드](docs/IT_DEPARTMENT_GUIDE.md), 앱 배포는 [현업 담당자 가이드](docs/BUSINESS_USER_GUIDE.md)를 참조하세요.

# 현업 앱 배포 실습: GitHub Actions + Azure Container Apps

**목표:** IT가 전용 RG와 비용 가드레일을 제공하면, 현업 담당자가 코드 변경을 `main`에 푸시해 Azure Container Apps(ACA)에 안전하게 배포합니다.

## 가장 짧은 실행 순서

1. **IT 담당자:** [IT 부서 가이드](docs/IT_DEPARTMENT_GUIDE.md)에서 전용 RG 생성, 해당 RG 범위 `Owner` 위임, 월 예산 알림을 설정합니다.
2. **현업 담당자:** [현업 담당자 가이드](docs/BUSINESS_USER_GUIDE.md)에서 GitHub `production` 보호를 설정하고 환경 프로비저닝 스크립트를 실행합니다.
3. **현업 담당자:** `main`에 푸시하고 `production` 승인을 완료합니다.
4. **완료:** GitHub Actions가 성공하고 배포된 컨테이너 앱 URL의 `/healthz`가 `{"status":"ok"}`을 반환합니다.

> 현업 담당자는 자신의 RG에만 `Owner`를 갖습니다. 구독 `Owner`, 클라이언트 비밀, ACR 관리자 암호는 사용하지 않습니다.

## 구성

| 경로 | 용도 |
| --- | --- |
| `src/` | 실행 가능한 FastAPI 실습 앱과 단위 테스트 |
| `Dockerfile` | Azure Container Apps용 컨테이너 이미지 정의 |
| `.github/workflows/deploy.yml` | OIDC 인증, ACR 빌드/푸시, Container Apps 배포 |
| `infra/main.bicep` | 담당자별 격리 환경(ACR, Container Apps, 관리 ID) |
| `scripts/assign-resource-group-owner.sh` | IT의 담당자별 RG 범위 Owner 위임 |
| `scripts/provision-team-environment.sh` | 현업 Owner의 ACA·ACR·GitHub OIDC 환경 구성 |
| `docs/IT_DEPARTMENT_GUIDE.md` | IT 부서: RG 위임, 비용 및 거버넌스 가이드 |
| `docs/BUSINESS_USER_GUIDE.md` | 현업 담당자: Copilot 기반 자율 배포 가이드 |

## 로컬 실행 및 확인

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests -v
uvicorn src.app:app --reload
```

브라우저에서 `http://127.0.0.1:8000`을 엽니다. 상태 점검은 `http://127.0.0.1:8000/healthz`, 자동 API 문서는 `http://127.0.0.1:8000/docs`입니다.

## 핵심 원칙

- GitHub Actions는 Microsoft Entra workload identity federation(OIDC)을 사용합니다. 클라이언트 비밀이나 ACR 관리자 암호를 저장하지 않습니다.
- 현업 담당자마다 전용 리소스 그룹을 만들고, 담당자에게 그 RG에만 `Owner`를 부여합니다.
- 배포용 관리 ID는 해당 리소스 그룹의 `Contributor` 및 해당 ACR의 `AcrPush`만 갖습니다.
- 실행 중인 Container App의 시스템 할당 관리 ID만 해당 ACR의 `AcrPull`을 갖습니다.

역할 경계와 비용 관리는 [IT 부서 가이드](docs/IT_DEPARTMENT_GUIDE.md), 앱 배포는 [현업 담당자 가이드](docs/BUSINESS_USER_GUIDE.md)를 참조하세요.

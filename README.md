# 현업 앱 배포 실습: 공유 Azure Container Apps 플랫폼

**목표:** IT가 공유 Container Apps 환경과 ACR을 운영하고, 현업 담당자는 자기 RG의 앱을 GitHub Actions로 안전하게 배포합니다.

## 가장 짧은 실행 순서

1. **IT 담당자:** [IT 부서 가이드](docs/IT_DEPARTMENT_GUIDE.md)에 따라 공유 플랫폼을 한 번 만듭니다.
2. **IT 담당자:** 담당자 전용 RG를 만들고 해당 RG 범위 `Owner`와 월 예산 알림을 설정합니다.
3. **현업 담당자:** [현업 담당자 가이드](docs/BUSINESS_USER_GUIDE.md)에서 저장소와 GitHub `production` 보호를 준비한 뒤 저장소 이름을 IT에 전달합니다.
4. **IT 담당자:** 담당자 RG에 앱과 배포 ID를 프로비저닝하고 GitHub 환경 변수를 등록합니다.
5. **현업 담당자:** 코드를 `main`에 푸시하고 `production` 승인을 완료합니다.
6. **완료:** GitHub Actions가 성공하고 배포 URL의 `/healthz`가 `status: ok`, 커밋 SHA, `production` 환경을 반환합니다.

> 현업 담당자는 자신의 RG에만 권한을 갖습니다. 공유 플랫폼 RG, 구독 `Owner`, 클라이언트 비밀, ACR 관리자 암호는 사용하지 않습니다.

## 구조

```text
rg-platform-shared              ← IT 소유
  ├─ Container Apps environment
  ├─ Container Registry (ABAC)
  └─ Log Analytics workspace

rg-sales-jiyoon-dev             ← 현업 담당자 Owner
  ├─ Container App
  └─ GitHub Actions 배포 ID
```

담당자별 RG는 RBAC, 비용 귀속, 오프보딩 경계로 유지합니다. 중복 비용이 발생하는 ACA 환경, ACR, Log Analytics만 공유합니다.

## 구성

| 경로 | 용도 |
| --- | --- |
| `src/` | 실행 가능한 FastAPI 실습 앱과 단위 테스트 |
| `Dockerfile` | Azure Container Apps용 컨테이너 이미지 정의 |
| `.github/workflows/deploy.yml` | OIDC 인증, 담당자 전용 ACR 리포지토리 Push, Container Apps 배포 |
| `infra/platform.bicep` | 공유 ACA 환경, ABAC ACR, Log Analytics |
| `infra/user-workload.bicep` | 담당자 RG의 Container App과 배포 ID |
| `scripts/assign-resource-group-owner.sh` | 담당자 RG 범위 Owner 위임 |
| `scripts/provision-shared-platform.sh` | 공유 플랫폼 1회 구성 |
| `scripts/provision-user-workload.sh` | 담당자별 워크로드와 GitHub OIDC 구성 |
| `scripts/offboard-business-user.sh` | 담당자 역할·ACR 리포지토리·RG 정리 |
| `docs/IT_DEPARTMENT_GUIDE.md` | IT의 플랫폼 운영, 온보딩, 비용, 오프보딩 절차 |
| `docs/BUSINESS_USER_GUIDE.md` | 현업 담당자의 저장소 준비, 개발, 배포 절차 |
| `docs/RESOURCE_ISOLATION_GUIDE.md` | 공유 플랫폼의 격리 경계와 큐·DB 추가 기준 |

## 로컬 실행

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

## 핵심 원칙

- GitHub Actions는 Microsoft Entra workload identity federation(OIDC)을 사용합니다.
- 현업 담당자는 자기 RG에만 `Owner`를 가지며 공유 플랫폼 RG에는 역할이 없습니다.
- 배포 ID는 자기 RG `Contributor`, 공유 ACR 관리 평면 `Reader`, 자기 리포지토리로 제한된 Repository Writer를 가집니다.
- Container App의 시스템 할당 ID는 자기 ACR 리포지토리만 Pull합니다.
- 담당자 앱은 같은 ACA 환경 네트워크와 코어 쿼터를 공유합니다. 네트워크 격리가 필요한 워크로드는 이 저장소의 범위가 아닙니다.
- ABAC Repository 역할에 조건이 없으면 레지스트리 전체 권한이 되므로 프로비저닝 스크립트가 조건을 강제합니다.

# 현업 앱 배포 실습: GitHub Actions + Azure Container Apps

**목표:** IT가 전용 RG와 비용 가드레일을 제공하면, 현업 담당자가 코드 변경을 `main`에 푸시해 Azure Container Apps(ACA)에 안전하게 배포합니다.

## 가장 짧은 실행 순서

1. **IT 담당자:** [IT 부서 가이드](docs/IT_DEPARTMENT_GUIDE.md)에서 격리 모델을 고르고, 전용 RG 생성, 해당 RG 범위 `Owner` 위임, 월 예산 알림을 설정합니다. 모델 B라면 공유 플랫폼도 만듭니다.
2. **현업 담당자:** [현업 담당자 가이드](docs/BUSINESS_USER_GUIDE.md) 1~2절에서 저장소와 GitHub `production` 보호를 준비합니다. 모델 B는 저장소 이름을 IT에 전달합니다.
3. **Azure 환경 구성:** 모델 A는 현업 담당자가 직접 프로비저닝하고, 모델 B는 IT가 담당자 워크로드를 프로비저닝합니다.
4. **현업 담당자:** 코드를 `main`에 푸시하고 `production` 승인을 완료합니다.
5. **완료:** GitHub Actions가 성공하고 배포된 컨테이너 앱 URL의 `/healthz`가 `{"status":"ok"}`을 반환합니다.

> 현업 담당자는 자신의 RG에만 권한을 갖습니다. 구독 `Owner`, 클라이언트 비밀, ACR 관리자 암호는 사용하지 않습니다.

## 구성

| 경로 | 용도 |
| --- | --- |
| `src/` | 실행 가능한 FastAPI 실습 앱과 단위 테스트 |
| `Dockerfile` | Azure Container Apps용 컨테이너 이미지 정의 |
| `.github/workflows/deploy.yml` | OIDC 인증, ACR 빌드/푸시, Container Apps 배포 |
| `infra/main.bicep` | **모델 A** 담당자별 전용 환경(ACR, Container Apps, 관리 ID) |
| `infra/platform.bicep` | **모델 B** 공유 플랫폼(ACA 환경, ABAC 레지스트리, Log Analytics) |
| `infra/user-workload.bicep` | **모델 B** 담당자별 앱과 배포 ID |
| `scripts/assign-resource-group-owner.sh` | IT의 담당자별 RG 범위 Owner 위임 |
| `scripts/provision-team-environment.sh` | **모델 A** 현업 Owner의 ACA·ACR·GitHub OIDC 환경 구성 |
| `scripts/provision-shared-platform.sh` | **모델 B** IT의 공유 플랫폼 1회 구성 |
| `scripts/provision-user-workload.sh` | **모델 B** IT의 담당자별 워크로드 배포 |
| `scripts/offboard-business-user.sh` | 담당자 오프보딩(역할·리포지토리·RG 정리) |
| `docs/RESOURCE_ISOLATION_GUIDE.md` | **자원 격리 모델 선택 기준과 큐·DB 격리 가이드** |
| `docs/IT_DEPARTMENT_GUIDE.md` | IT 부서: RG 위임, 비용 및 거버넌스 가이드 |
| `docs/BUSINESS_USER_GUIDE.md` | 현업 담당자: Copilot 기반 자율 배포 가이드 |

## 두 가지 격리 모델

담당자가 늘면 담당자마다 ACA 환경과 레지스트리를 만드는 방식이 부담이 됩니다. 이 저장소는 두 모델을 제공합니다.

| | **모델 A. 전용** | **모델 B. 공유 플랫폼** |
| --- | --- | --- |
| 공유되는 것 | 없음 | ACA 환경, ACR, Log Analytics |
| 담당자 RG 안에 있는 것 | 전부 | 앱과 배포용 관리 ID |
| ACR 고정비 | 담당자 수에 비례 | 레지스트리 1개 |
| 이미지 격리 | RG 분리 | ACR **ABAC** 리포지토리 조건 |
| 담당자 간 네트워크 격리 | 있음 | **없음** |
| 프로비저닝 주체 | 현업 담당자 | IT 또는 파이프라인 |

두 모델 모두 **담당자별 RG를 유지합니다.** 리소스 그룹은 무료이고 RBAC 범위·비용 귀속·오프보딩의 기준이 되므로 없애지 않습니다. 모델 B는 RG가 아니라 그 안에서 중복되던 플랫폼 리소스만 걷어냅니다.

선택 기준, 공유 시 필요한 가드레일, 큐·데이터베이스를 어떻게 나눌지는 [자원 격리 가이드](docs/RESOURCE_ISOLATION_GUIDE.md)를 참조하세요.

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
- 배포용 관리 ID는 해당 리소스 그룹의 `Contributor`만 갖습니다. 모델 A에서는 해당 ACR의 `AcrPush`를, 모델 B에서는 공유 ACR의 관리 평면 `Reader`와 자기 리포지토리로 제한된 `Container Registry Repository Writer`를 갖습니다.
- 실행 중인 Container App의 시스템 할당 관리 ID는 자기 이미지만 Pull합니다. 모델 A는 `AcrPull`, 모델 B는 리포지토리 조건이 붙은 `Container Registry Repository Reader`입니다.
- ABAC 역할을 **조건 없이** 부여하면 레지스트리 전체 권한이 됩니다. 조건이 곧 격리입니다.

역할 경계와 비용 관리는 [IT 부서 가이드](docs/IT_DEPARTMENT_GUIDE.md), 격리 모델 선택은 [자원 격리 가이드](docs/RESOURCE_ISOLATION_GUIDE.md), 앱 배포는 [현업 담당자 가이드](docs/BUSINESS_USER_GUIDE.md)를 참조하세요.

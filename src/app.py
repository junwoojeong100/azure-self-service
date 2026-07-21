import os
import platform
from datetime import UTC, datetime
from uuid import uuid4

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel


app = FastAPI(
    title="현업 앱 배포 데모",
    description="GitHub Actions와 Azure Container Apps 배포 상태를 보여주는 데모 API입니다.",
    version="1.0.0",
)
templates = Jinja2Templates(directory="src/templates")
STARTED_AT = datetime.now(UTC)


class HealthResponse(BaseModel):
    status: str
    release: str
    environment: str
    hostname: str
    started_at: str


def release_metadata() -> dict[str, str]:
    return {
        "release": os.getenv("APP_RELEASE", "local"),
        "environment": os.getenv("APP_ENVIRONMENT", "local"),
        "hostname": platform.node(),
        "started_at": STARTED_AT.isoformat(),
    }


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
async def index(request: Request) -> HTMLResponse:
    request_id = request.headers.get("X-Request-ID", str(uuid4()))
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={"request_id": request_id, **release_metadata()},
    )


@app.get("/healthz", response_model=HealthResponse, tags=["operations"])
async def healthz() -> HealthResponse:
    return HealthResponse(status="ok", **release_metadata())

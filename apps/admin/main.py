"""
Olimpo Admin API — panel Superadmin.

Arranque:
    uvicorn main:app --reload --port 8001

Acceso exclusivo: IP allowlist + X-Admin-API-Key en cada request.
"""

from contextlib import asynccontextmanager
from typing import AsyncIterator

import structlog
from fastapi import FastAPI, Request, status
from fastapi.responses import JSONResponse

from core.config import get_settings
from routers import auth, licencias, stats, tenants, usuarios_maestros

log = structlog.get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    s = get_settings()
    log.info("olimpo_admin_arrancando", environment=s.ENVIRONMENT)
    yield
    log.info("olimpo_admin_detenida")


def create_app() -> FastAPI:
    s = get_settings()

    app = FastAPI(
        title="Olimpo Admin API",
        description="Panel Superadmin — gestión de tenants y usuarios maestros.",
        version="0.1.0",
        docs_url="/docs" if not s.is_production else None,
        redoc_url=None,
        lifespan=lifespan,
    )

    # -------------------------------------------------------------------------
    # Middleware: IP allowlist
    # El admin solo responde a IPs configuradas en ADMIN_ALLOWED_IPS.
    #
    # IMPORTANTE: en Railway (y otros PaaS) el tráfico pasa por un reverse proxy.
    # request.client.host devuelve la IP del proxy, no la del cliente real.
    # La IP del cliente viene en X-Forwarded-For (formato: "cliente, proxy1, proxy2").
    # -------------------------------------------------------------------------
    @app.middleware("http")
    async def ip_allowlist(request: Request, call_next):
        forwarded = request.headers.get("x-forwarded-for", "")
        if forwarded:
            client_ip = forwarded.split(",")[0].strip()
        else:
            client_ip = request.client.host if request.client else ""
        if client_ip not in s.allowed_ips:
            log.warning("acceso_denegado_ip", ip=client_ip, path=request.url.path)
            return JSONResponse(
                status_code=status.HTTP_403_FORBIDDEN,
                content={"detail": "Acceso denegado."},
            )
        return await call_next(request)

    # -------------------------------------------------------------------------
    # Manejador global de excepciones no controladas
    # -------------------------------------------------------------------------
    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception) -> JSONResponse:
        log.error(
            "excepcion_no_controlada",
            path=request.url.path,
            error=str(exc),
            exc_info=True,
        )
        return JSONResponse(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            content={"detail": "Error interno del servidor."},
        )

    # -------------------------------------------------------------------------
    # Routers
    # -------------------------------------------------------------------------
    app.include_router(auth.router, prefix="/api/v1")
    app.include_router(tenants.router, prefix="/api/v1")
    app.include_router(usuarios_maestros.router, prefix="/api/v1")
    app.include_router(licencias.router, prefix="/api/v1")
    app.include_router(stats.router, prefix="/api/v1")

    return app


app = create_app()

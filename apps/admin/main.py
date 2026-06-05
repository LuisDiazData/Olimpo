"""
Olimpo Admin API — panel Superadmin.

Arranque:
    uvicorn main:app --reload --port 8001

Acceso exclusivo: IP allowlist + X-Admin-API-Key en cada request.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

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


def _resolver_ip_cliente(request: Request, trusted_proxy_count: int) -> str | None:
    """
    Devuelve la IP real del cliente de forma resistente a spoofing de X-Forwarded-For.

    El cliente puede prepender valores arbitrarios al header, pero cada proxy de
    confianza añade al final la IP del peer del que recibió la conexión. Por eso
    la IP del cliente es el `trusted_proxy_count`-ésimo valor desde el final.
    Si el header trae menos saltos de los esperados, la cadena de proxies no es
    la configurada → se rechaza (fail-closed) devolviendo None.
    """
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        partes = [p.strip() for p in forwarded.split(",") if p.strip()]
        if len(partes) >= trusted_proxy_count >= 1:
            return partes[-trusted_proxy_count]
        return None
    return request.client.host if request.client else None


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
    # La IP real viene en X-Forwarded-For, pero ese header es controlado por el
    # cliente: cualquiera puede prepender valores falsos. El proxy de confianza
    # SIEMPRE añade la IP TCP real al final, así que la IP del cliente es el
    # ADMIN_TRUSTED_PROXY_COUNT-ésimo valor desde el final. NUNCA el primero.
    # -------------------------------------------------------------------------
    @app.middleware("http")
    async def ip_allowlist(request: Request, call_next):
        if request.url.path == "/health":
            return await call_next(request)
        client_ip = _resolver_ip_cliente(request, s.ADMIN_TRUSTED_PROXY_COUNT)
        if client_ip is None or client_ip not in s.allowed_ips:
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
    # Health — exempt from IP allowlist, used by Railway healthcheck
    # -------------------------------------------------------------------------
    @app.get("/health", include_in_schema=False)
    async def health():
        return {"status": "ok"}

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

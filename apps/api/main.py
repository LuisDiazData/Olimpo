"""
Olimpo API — punto de entrada de FastAPI.

Arranque:
    uvicorn main:app --reload --port 8000
"""

from contextlib import asynccontextmanager
from typing import AsyncIterator

import logfire
import structlog
from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from core.config import get_settings
from core.logging import setup_observability
from routers import (
    activaciones,
    agentes,
    asignaciones,
    coberturas,
    comunicaciones,
    correos,
    gmail_webhook,
    health,
    notificaciones,
    permisos,
    pipeline,
    polizas,
    slas,
    test_ia,
    tramites,
    usuarios,
)

log = structlog.get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    setup_observability()
    s = get_settings()
    log.info("olimpo_api_arrancando", environment=s.ENVIRONMENT)
    yield
    log.info("olimpo_api_detenida")


def create_app() -> FastAPI:
    s = get_settings()

    app = FastAPI(
        title="Olimpo CRM API",
        description="Backend para Olimpo — CRM con IA para promotorias de seguros en México.",
        version="0.1.0",
        docs_url="/docs" if not s.is_production else None,
        redoc_url="/redoc" if not s.is_production else None,
        lifespan=lifespan,
    )

    # -------------------------------------------------------------------------
    # Logfire — instrumentación automática de FastAPI
    # -------------------------------------------------------------------------
    logfire.instrument_fastapi(app)

    # -------------------------------------------------------------------------
    # CORS — solo orígenes configurados en CORS_ORIGINS
    # -------------------------------------------------------------------------
    app.add_middleware(
        CORSMiddleware,
        allow_origins=s.cors_origins_list,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Agent-API-Key"],
    )

    # -------------------------------------------------------------------------
    # Manejador global de excepciones no controladas
    # -------------------------------------------------------------------------
    @app.exception_handler(Exception)
    async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
        log.error(
            "excepcion_no_controlada",
            path=request.url.path,
            method=request.method,
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
    app.include_router(health.router)
    app.include_router(gmail_webhook.router)   # sin prefix: /webhook/gmail (URL fija para Pub/Sub)
    app.include_router(usuarios.router, prefix="/api/v1")
    app.include_router(agentes.router, prefix="/api/v1")
    app.include_router(asignaciones.router, prefix="/api/v1")
    app.include_router(tramites.router, prefix="/api/v1")
    app.include_router(polizas.router, prefix="/api/v1")
    app.include_router(correos.router, prefix="/api/v1")
    app.include_router(comunicaciones.router, prefix="/api/v1")
    app.include_router(activaciones.router, prefix="/api/v1")
    app.include_router(notificaciones.router, prefix="/api/v1")
    app.include_router(slas.router, prefix="/api/v1")
    app.include_router(coberturas.router, prefix="/api/v1")
    app.include_router(pipeline.router, prefix="/api/v1")
    app.include_router(permisos.router, prefix="/api/v1")
    app.include_router(test_ia.router, prefix="/api/v1")

    return app


app = create_app()

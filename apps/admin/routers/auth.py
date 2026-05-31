"""
Router: autenticación interna del Superadmin.

Endpoints:
  POST /auth/verify — valida la API key contra la variable de entorno (sin consultar DB).
                       Ideal para el flujo de login, donde aún no hay sesión y
                       el Supabase del admin podría estar caído.
"""

from fastapi import APIRouter, Request, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from core.config import get_settings

router = APIRouter(tags=["Auth"])


class VerifyResponse(BaseModel):
    valido: bool
    environment: str


@router.post("/auth/verify")
def verificar_api_key(request: Request) -> JSONResponse:
    """
    Valida la API key contra ADMIN_API_KEY sin consultar la base de datos.
    Devuelve 200 con {"valido": true} si es correcta, 401 si no.
    """
    api_key = request.headers.get("x-admin-api-key", "")
    s = get_settings()

    if api_key != s.ADMIN_API_KEY:
        return JSONResponse(
            status_code=status.HTTP_401_UNAUTHORIZED,
            content={"valido": False, "detail": "API key inválida."},
        )

    return JSONResponse(
        status_code=status.HTTP_200_OK,
        content={"valido": True, "environment": s.ENVIRONMENT},
    )

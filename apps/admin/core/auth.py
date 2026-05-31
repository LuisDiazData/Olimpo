"""
Autenticación del Superadmin.

Un solo mecanismo: API key estática en el header X-Admin-API-Key.
El panel Admin también está protegido por IP allowlist en el middleware de main.py.
La doble protección (IP + API key) compensa la simplicidad del esquema.
"""

from fastapi import HTTPException, Security, status
from fastapi.security import APIKeyHeader

from core.config import get_settings

_api_key_header = APIKeyHeader(name="X-Admin-API-Key", auto_error=True)


def require_superadmin(api_key: str = Security(_api_key_header)) -> None:
    """
    Dependencia FastAPI que valida la API key del Superadmin.
    Uso: dependencies=[Depends(require_superadmin)]
    """
    s = get_settings()
    if api_key != s.ADMIN_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "error_code": "API_KEY_INVALIDA",
                "mensaje": "API key de Superadmin inválida.",
            },
        )

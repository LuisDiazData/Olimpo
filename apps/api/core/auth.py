"""
Autenticación JWT y API key para Olimpo API.

Dos mecanismos de autenticación:

1. JWT de Supabase (usuarios humanos — frontend):
   - El frontend obtiene un JWT al hacer login con Supabase Auth.
   - Cada request incluye: Authorization: Bearer <jwt>
   - Se verifica la firma con SUPABASE_JWT_SECRET (HS256).
   - Extrae sub (user UUID), rol y ramo de app_metadata.

2. API key (agentes externos — MCP):
   - Agentes de IA, n8n, integraciones externas sin sesión interactiva.
   - Cada request incluye: X-Agent-API-Key: <key>
   - Se valida contra la tabla agent_api_keys (solo hash SHA-256 almacenado).
   - El agente opera con el rol y ramo asignados a esa key.
"""

import hashlib
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import APIKeyHeader, HTTPAuthorizationCredentials, HTTPBearer

from core.config import get_settings
from models.usuario import RamoUsuario, RolUsuario, UsuarioToken

_bearer = HTTPBearer(auto_error=True)
_api_key_header = APIKeyHeader(name="X-Agent-API-Key", auto_error=False)


# =============================================================================
# MECANISMO 1: JWT de Supabase (usuarios humanos)
# =============================================================================

def _decode_jwt(token: str) -> dict:
    """Decodifica y valida la firma del JWT de Supabase. Lanza HTTPException si es inválido."""
    s = get_settings()
    try:
        payload = jwt.decode(
            token,
            s.SUPABASE_JWT_SECRET,
            algorithms=["HS256"],
            audience="authenticated",
            options={"require": ["sub", "exp", "aud"]},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Sesión expirada. Inicia sesión nuevamente.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except jwt.InvalidTokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Token inválido: {exc}",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return payload


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> UsuarioToken:
    """
    Dependencia FastAPI para usuarios humanos (frontend).
    Extrae y valida el usuario del JWT de Supabase.
    Uso: usuario: UsuarioToken = Depends(get_current_user)
    """
    payload = _decode_jwt(credentials.credentials)

    app_metadata: dict = payload.get("app_metadata", {})
    rol_raw: str | None = app_metadata.get("rol")
    ramo_raw: str | None = app_metadata.get("ramo")

    if rol_raw is None:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="El token no contiene rol en app_metadata. Contacta al administrador.",
        )

    try:
        rol = RolUsuario(rol_raw)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Rol desconocido en token: '{rol_raw}'",
        )

    ramo: RamoUsuario | None = None
    if ramo_raw is not None:
        try:
            ramo = RamoUsuario(ramo_raw)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Ramo desconocido en token: '{ramo_raw}'",
            )

    return UsuarioToken(
        id=UUID(payload["sub"]),
        email=payload.get("email", ""),
        rol=rol,
        ramo=ramo,
        access_token=credentials.credentials,
    )


def require_roles(*roles: RolUsuario):
    """
    Dependencia de fábrica que restringe un endpoint a roles específicos.

    Uso:
        @router.get("/admin", dependencies=[Depends(require_roles(RolUsuario.director_general))])
    """
    def _check(usuario: UsuarioToken = Depends(get_current_user)) -> UsuarioToken:
        if usuario.rol not in roles:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Acceso denegado. Roles requeridos: {[r.value for r in roles]}",
            )
        return usuario
    return _check


# =============================================================================
# MECANISMO 2: API key para agentes externos (MCP, n8n, integraciones)
# =============================================================================

def get_agent_token(
    api_key: str | None = Depends(_api_key_header),
) -> UsuarioToken:
    """
    Dependencia FastAPI para agentes externos sin sesión interactiva.
    Valida X-Agent-API-Key contra la tabla agent_api_keys (hash SHA-256).

    Uso: agente: UsuarioToken = Depends(get_agent_token)

    Endpoints protegidos con este mecanismo son accesibles por agentes MCP,
    workers de n8n, y cualquier integración sin login interactivo.
    La API key se crea desde admin.olimpo.mx y nunca se almacena en texto plano.
    """
    if not api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "error_code": "API_KEY_REQUERIDA",
                "mensaje": "Se requiere el header X-Agent-API-Key para este endpoint.",
            },
            headers={"WWW-Authenticate": "ApiKey"},
        )

    key_hash = hashlib.sha256(api_key.encode()).hexdigest()
    from core.database import get_admin_db
    db = get_admin_db()

    result = db.rpc("validar_agent_api_key", {"p_key_hash": key_hash}).execute()

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "error_code": "API_KEY_INVALIDA",
                "mensaje": "API key inválida, revocada o expirada.",
            },
            headers={"WWW-Authenticate": "ApiKey"},
        )

    key_data: dict = result.data

    try:
        rol = RolUsuario(key_data["rol"])
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "error_code": "ROL_INVALIDO",
                "mensaje": f"La API key tiene un rol inválido: '{key_data['rol']}'",
            },
        )

    ramo: RamoUsuario | None = None
    if key_data.get("ramo"):
        try:
            ramo = RamoUsuario(key_data["ramo"])
        except ValueError:
            pass

    return UsuarioToken(
        id=UUID(key_data["id"]),
        email=f"{key_data['nombre']}@agent.olimpo.internal",
        rol=rol,
        ramo=ramo,
        access_token="",
    )


def get_current_user_or_agent(
    credentials: HTTPAuthorizationCredentials | None = Depends(HTTPBearer(auto_error=False)),
    api_key: str | None = Depends(_api_key_header),
) -> UsuarioToken:
    """
    Dependencia flexible: acepta JWT (usuario humano) O API key (agente).
    Para endpoints que deben ser accesibles tanto desde el frontend como desde MCP.

    Uso: actor: UsuarioToken = Depends(get_current_user_or_agent)
    """
    if api_key:
        return get_agent_token(api_key)
    if credentials:
        return get_current_user(credentials)
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail={
            "error_code": "AUTENTICACION_REQUERIDA",
            "mensaje": "Se requiere Authorization: Bearer <jwt> o X-Agent-API-Key: <key>.",
        },
        headers={"WWW-Authenticate": "Bearer"},
    )

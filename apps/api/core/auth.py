"""
Autenticación JWT y API key para Olimpo API.

Dos mecanismos de autenticación:

1. JWT de Supabase (usuarios humanos — frontend):
   - El frontend obtiene un JWT al hacer login con Supabase Auth.
   - Cada request incluye: Authorization: Bearer <jwt>
   - Se verifica la firma con JWKS (ES256) o secret legacy (HS256).
   - Extrae sub (user UUID), rol y ramo de app_metadata.

2. API key (agentes externos — MCP):
   - Agentes de IA, n8n, integraciones externas sin sesión interactiva.
   - Cada request incluye: X-Agent-API-Key: <key>
   - Se valida contra la tabla agent_api_keys (solo hash SHA-256 almacenado).
   - El agente opera con el rol y ramo asignados a esa key.
"""

import base64
import contextlib
import hashlib
import json
from uuid import UUID

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import APIKeyHeader, HTTPAuthorizationCredentials, HTTPBearer

from core.config import get_settings
from models.usuario import RamoUsuario, RolUsuario, UsuarioToken

_bearer = HTTPBearer(auto_error=True)
_api_key_header = APIKeyHeader(name="X-Agent-API-Key", auto_error=False)

_JWKS_CACHE: dict | None = None
_JWKS_CACHE_TTL = 3600
_JWKS_FETCHED_AT = 0.0


# =============================================================================
# JWKS helpers (ES256 verification for Supabase v2)
# =============================================================================

def _get_jwks(supabase_url: str, anon_key: str) -> dict:
    """Fetch and cache JWKS from Supabase Auth, fallback to hardcoded keys."""
    global _JWKS_CACHE, _JWKS_FETCHED_AT
    import time

    if _JWKS_CACHE is not None and (time.time() - _JWKS_FETCHED_AT) < _JWKS_CACHE_TTL:
        return _JWKS_CACHE

    try:
        import httpx
        resp = httpx.get(
            f"{supabase_url}/auth/v1/.well-known/jwks.json",
            headers={"apikey": anon_key},
            timeout=10,
        )
        resp.raise_for_status()
        _JWKS_CACHE = resp.json()
        _JWKS_FETCHED_AT = time.time()
        return _JWKS_CACHE
    except Exception:
        pass

    s = get_settings()
    return s.supabase_jwks


def _build_public_key(jwk: dict) -> bytes:
    """Build a raw EC public key from JWK x/y coordinates (P-256 / ES256)."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ec import (
        SECP256R1,
        EllipticCurvePublicKey,
    )

    x_bytes = base64url_decode(jwk["x"])
    y_bytes = base64url_decode(jwk["y"])
    public_key = EllipticCurvePublicKey.from_encoded_point(
        SECP256R1(), b"\x04" + x_bytes + y_bytes
    )
    return public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )


def base64url_decode(data: str) -> bytes:
    """Decode a base64url string (URL-safe base64 without padding)."""
    data = data + "=" * (4 - len(data) % 4)
    return base64.urlsafe_b64decode(data)


def _decode_jwt_es256(token: str, supabase_url: str, anon_key: str) -> dict:
    """Verify ES256 JWT using JWKS."""
    parts = token.split(".")
    header_raw = parts[0]
    header = json.loads(base64url_decode(header_raw))
    kid = header.get("kid")

    jwks = _get_jwks(supabase_url, anon_key)
    jwk = None
    for k in jwks.get("keys", []):
        if k.get("kid") == kid:
            jwk = k
            break

    if jwk is None:
        raise ValueError(f"Key {kid} not found in JWKS")

    public_key = _build_public_key(jwk)
    return jwt.decode(token, public_key, algorithms=["ES256"], audience="authenticated")


# =============================================================================
# MECANISMO 1: JWT de Supabase (usuarios humanos)
# =============================================================================

def _decode_jwt(token: str) -> dict:
    """Decodifica y valida la firma del JWT de Supabase. Lanza HTTPException si es inválido."""
    s = get_settings()

    # Intentar ES256 primero (Supabase v2 JWKS)
    try:
        header_raw = token.split(".")[0]
        header = json.loads(base64url_decode(header_raw))
        if header.get("alg") == "ES256":
            return _decode_jwt_es256(token, s.SUPABASE_URL, s.SUPABASE_ANON_KEY)
    except (ValueError, KeyError, jwt.InvalidTokenError, Exception):
        pass

    # Fallback a HS256 con secret legacy
    try:
        return jwt.decode(
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
        with contextlib.suppress(ValueError):
            ramo = RamoUsuario(key_data["ramo"])

    return UsuarioToken(
        id=UUID(key_data["id"]),
        email=f"{key_data['nombre']}@agent.olimpo.internal",
        rol=rol,
        ramo=ramo,
        access_token="",
    )


# =============================================================================
# PERMISOS GRANULARES
# =============================================================================

def require_permiso(clave: str):
    """
    Dependencia de fábrica que valida un permiso granular del usuario autenticado.
    Consulta la función SQL tiene_permiso() que resuelve overrides de usuario y
    defaults de rol en una sola llamada.

    Uso:
        @router.post("/reasignar", dependencies=[Depends(require_permiso("tramites.reasignar"))])

    El permiso se evalúa en el cliente admin (service_role) para evitar que RLS
    sobre las tablas de permisos bloquee la verificación.
    """
    def _check(caller: UsuarioToken = Depends(get_current_user)) -> UsuarioToken:
        from core.database import get_admin_db
        admin = get_admin_db()
        result = admin.rpc(
            "tiene_permiso",
            {"p_usuario_id": str(caller.id), "p_clave": clave},
        ).execute()
        if not result.data:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail={
                    "error_code": "PERMISO_DENEGADO",
                    "mensaje": f"No tienes el permiso requerido: '{clave}'.",
                    "permiso_requerido": clave,
                },
            )
        return caller
    return _check


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

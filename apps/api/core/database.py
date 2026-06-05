"""
Clientes de Supabase para el backend Olimpo.

Dos patrones de uso:
  - get_db(usuario)     → PostgREST autenticado como el usuario (RLS activo) via dependencia Depends
  - get_admin_db_dep()  → PostgREST con service_role (bypasa RLS, para ops internas) via dependencia Depends

El cliente de admin se inicializa una vez al arranque (singleton). El cliente de
usuario se crea por request con el JWT del usuario para que RLS funcione. Ambas
opciones reutilizan un pool de conexiones HTTP compartido para mayor rendimiento.
"""

import httpx
from fastapi import Depends
from supabase import Client, ClientOptions, create_client

from core.auth import get_current_user
from core.config import get_settings
from models.usuario import UsuarioToken

# Cliente HTTP compartido con pooling para evitar agotamiento de sockets bajo carga
_shared_http_client = httpx.Client(
    limits=httpx.Limits(max_connections=100, max_keepalive_connections=20),
    timeout=30.0,
)

_admin_client: Client | None = None


def get_admin_db() -> Client:
    """Cliente Supabase con service_role. Bypasa RLS. Solo para operaciones internas (Singleton)."""
    global _admin_client
    if _admin_client is None:
        s = get_settings()
        options = ClientOptions(httpx_client=_shared_http_client)
        _admin_client = create_client(s.SUPABASE_URL, s.SUPABASE_SERVICE_ROLE_KEY, options=options)
    return _admin_client


def get_user_db(access_token: str) -> Client:
    """
    Cliente Supabase autenticado como el usuario actual.
    El PostgREST respeta las policies RLS usando el JWT del usuario.
    Reutiliza el cliente HTTP compartido con pooling para rendimiento óptimo.

    Se construye con la ANON_KEY (no la service_role) para que el modo de falla
    sea fail-closed: si el JWT del usuario no se aplicara correctamente, el cliente
    operaría como rol anónimo (RLS niega todo) en lugar de service_role (RLS bypass).
    """
    s = get_settings()
    options = ClientOptions(httpx_client=_shared_http_client)
    client = create_client(s.SUPABASE_URL, s.SUPABASE_ANON_KEY, options=options)
    client.postgrest.auth(access_token)
    return client


# -----------------------------------------------------------------------------
# DEPENDENCIAS DE FASTAPI (Inyectables en Routers)
# -----------------------------------------------------------------------------


def get_db(usuario: UsuarioToken = Depends(get_current_user)) -> Client:
    """
    Dependencia de FastAPI para obtener el cliente de base de datos del usuario autenticado.
    Esto permite mockear la base de datos fácilmente en los tests.
    """
    return get_user_db(usuario.access_token)


def get_admin_db_dep() -> Client:
    """
    Dependencia de FastAPI para obtener el cliente admin (service_role).
    Se usa para operaciones del sistema que requieren bypass de RLS.
    """
    return get_admin_db()

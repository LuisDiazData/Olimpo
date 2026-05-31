"""
Clientes Supabase para el panel Superadmin.

get_admin_db()          → cliente service_role al Supabase del Superadmin
                          (donde vive la tabla tenant)

get_tenant_client(url, key) → cliente service_role al Supabase de un tenant específico
                               (para gestionar sus auth.users y public.usuario)
"""

import httpx
from supabase import Client, ClientOptions, create_client

from core.config import get_settings

_shared_http = httpx.Client(
    limits=httpx.Limits(max_connections=50, max_keepalive_connections=10),
    timeout=30.0,
)

_admin_client: Client | None = None


def get_admin_db() -> Client:
    """Cliente service_role al Supabase del Superadmin. Singleton."""
    global _admin_client
    if _admin_client is None:
        s = get_settings()
        options = ClientOptions(httpx_client=_shared_http)
        _admin_client = create_client(
            s.ADMIN_SUPABASE_URL,
            s.ADMIN_SUPABASE_SERVICE_ROLE_KEY,
            options=options,
        )
    return _admin_client


def get_tenant_client(supabase_url: str, service_role_key: str) -> Client:
    """
    Cliente service_role al Supabase de un tenant.
    Se crea por operación (no es singleton) porque cada tenant tiene URL y key distintas.
    """
    options = ClientOptions(httpx_client=_shared_http)
    return create_client(supabase_url, service_role_key, options=options)

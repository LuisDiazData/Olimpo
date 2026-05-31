"""
Cliente Supabase con service_role para el MCP server.

Los agentes IA corren del lado del servidor con privilegios completos.
El service_role bypasa RLS — la responsabilidad de acceso la gestiona
la lógica de negocio de cada agente, no las policies de DB.
"""

import httpx
from supabase import Client, ClientOptions, create_client

from core.config import get_settings

_http_client = httpx.Client(
    limits=httpx.Limits(max_connections=50, max_keepalive_connections=10),
    timeout=30.0,
)

_client: Client | None = None


def get_db() -> Client:
    """Singleton del cliente Supabase con service_role."""
    global _client
    if _client is None:
        s = get_settings()
        options = ClientOptions(httpx_client=_http_client)
        _client = create_client(s.SUPABASE_URL, s.SUPABASE_SERVICE_ROLE_KEY, options=options)
    return _client

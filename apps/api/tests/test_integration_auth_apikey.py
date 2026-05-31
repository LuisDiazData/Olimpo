"""
Tests de integración — autenticación con API key (X-Agent-API-Key).

Requiere: conexión a Supabase activa con las credenciales en .env.
Ejecutar con: pytest tests/ -m integration -v

Estos tests verifican el flujo completo de autenticación por API key:
inserción en agent_api_keys con hash SHA-256, validación vía RPC, y acceso
a endpoints protegidos con get_current_user_or_agent.
"""
import hashlib
import secrets

import pytest

pytestmark = pytest.mark.integration


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def api_key_activa(admin_db):
    """Crea una API key activa en agent_api_keys y la elimina al finalizar."""
    from core.database import get_admin_db
    db = get_admin_db()

    raw_key = secrets.token_hex(32)  # 64 chars hex
    key_hash = hashlib.sha256(raw_key.encode()).hexdigest()

    result = db.table("agent_api_keys").insert({
        "nombre": "agente_test_integration",
        "key_hash": key_hash,
        "rol": "analista",
        "ramo": "vida",
        "activo": True,
    }).select("id").execute()

    key_id = result.data[0]["id"]
    yield raw_key

    db.table("agent_api_keys").delete().eq("id", key_id).execute()


@pytest.fixture
def admin_db():
    from core.database import get_admin_db
    return get_admin_db()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_api_key_invalida_retorna_401(client):
    """X-Agent-API-Key con valor falso debe retornar 401 API_KEY_INVALIDA."""
    response = client.get(
        "/api/v1/pipeline/schema/estados",
        headers={"X-Agent-API-Key": "clave_falsa_que_no_existe"},
    )
    assert response.status_code == 401
    detail = response.json()["detail"]
    assert detail["error_code"] == "API_KEY_INVALIDA"


def test_api_key_vacia_no_autentifica(client):
    """Un header X-Agent-API-Key vacío no debe autentificar."""
    response = client.get(
        "/api/v1/pipeline/schema/estados",
        headers={"X-Agent-API-Key": ""},
    )
    # Sin credenciales válidas debe fallar
    assert response.status_code in (401, 422)


def test_api_key_valida_accede_a_endpoint(client, api_key_activa):
    """API key válida debe acceder a endpoints protegidos con get_current_user_or_agent."""
    response = client.get(
        "/api/v1/pipeline/schema/estados",
        headers={"X-Agent-API-Key": api_key_activa},
    )
    assert response.status_code == 200
    data = response.json()
    assert "estados" in data
    assert "transiciones" in data


def test_api_key_valida_puede_consultar_tramites(client, api_key_activa):
    """API key válida puede acceder a GET /tramites (RLS usa el rol de la key)."""
    response = client.get(
        "/api/v1/tramites",
        headers={"X-Agent-API-Key": api_key_activa},
    )
    assert response.status_code == 200
    data = response.json()
    assert "items" in data

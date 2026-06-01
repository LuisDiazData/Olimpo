"""
Tests de integración — trámites con DB real.

Requiere: conexión a Supabase activa con las credenciales en .env o variables de entorno.
Ejecutar con: pytest tests/ -m integration -v

Estos tests crean datos reales en la DB y los limpian al finalizar.
Usan el cliente admin (service_role) para setup/teardown, y el cliente autenticado
para verificar el comportamiento de los endpoints con RLS activo.
"""

from uuid import uuid4

import pytest

pytestmark = pytest.mark.integration


# ---------------------------------------------------------------------------
# Fixtures de integración
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def admin_db():
    """Cliente Supabase con service_role para setup/teardown."""
    from core.database import get_admin_db

    return get_admin_db()


@pytest.fixture
def tramite_recibido(admin_db, director_token):
    """Crea un trámite en estado 'recibido' y lo elimina al finalizar el test."""
    # Insertar con admin para bypasear RLS
    result = (
        admin_db.table("tramite")
        .insert(
            {
                "tipo_tramite": "alta",
                "titulo": "Test trámite integración",
                "descripcion": "Creado por suite de integración",
                "canal_origen": "manual",
                "prioridad": "normal",
            }
        )
        .select("id, folio, estado")
        .execute()
    )

    tramite_id = result.data[0]["id"]
    yield result.data[0]

    # Limpieza: primero eliminar eventos (FK), luego el trámite
    admin_db.table("tramite_evento").delete().eq("tramite_id", tramite_id).execute()
    admin_db.table("tramite").delete().eq("id", tramite_id).execute()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_crear_tramite_retorna_201_con_folio(client_director):
    """POST /tramites crea un trámite con folio generado por trigger DB."""
    response = client_director.post(
        "/api/v1/tramites",
        json={
            "tipo_tramite": "alta",
            "titulo": "Trámite de prueba integración",
            "canal_origen": "manual",
            "prioridad": "normal",
        },
    )
    assert response.status_code == 201
    data = response.json()
    assert "folio" in data
    assert data["folio"]  # no vacío — generado por trigger
    assert data["estado"] == "recibido"
    assert data["transiciones_disponibles"] == ["en_revision"]

    # Limpieza
    from core.database import get_admin_db

    db = get_admin_db()
    tramite_id = data["id"]
    db.table("tramite_evento").delete().eq("tramite_id", tramite_id).execute()
    db.table("tramite").delete().eq("id", tramite_id).execute()


def test_listar_tramites_retorna_estructura_paginada(client_analista):
    """GET /tramites retorna PaginatedResponse con total >= 0."""
    response = client_analista.get("/api/v1/tramites")
    assert response.status_code == 200
    data = response.json()
    assert "items" in data
    assert "total" in data
    assert "has_more" in data
    assert data["total"] >= 0


def test_obtener_tramite_incluye_transiciones(client_director, tramite_recibido):
    """GET /tramites/{id} devuelve transiciones_disponibles correctas para el estado actual."""
    tramite_id = tramite_recibido["id"]
    response = client_director.get(f"/api/v1/tramites/{tramite_id}")

    assert response.status_code == 200
    data = response.json()
    assert data["estado"] == "recibido"
    assert data["transiciones_disponibles"] == ["en_revision"]


def test_transicion_valida_recibido_a_en_revision(client_director, tramite_recibido):
    """recibido → en_revision es la única transición válida desde recibido."""
    tramite_id = tramite_recibido["id"]
    response = client_director.post(
        f"/api/v1/tramites/{tramite_id}/cambiar-estado",
        json={"estado_nuevo": "en_revision"},
    )
    assert response.status_code == 200
    assert response.json()["estado"] == "en_revision"


def test_transicion_invalida_recibido_a_completado(client_director, tramite_recibido):
    """recibido → completado debe retornar 422 TRANSICION_INVALIDA."""
    tramite_id = tramite_recibido["id"]
    response = client_director.post(
        f"/api/v1/tramites/{tramite_id}/cambiar-estado",
        json={"estado_nuevo": "completado"},
    )
    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["error_code"] == "TRANSICION_INVALIDA"


def test_tramite_inexistente_retorna_404(client_analista):
    """GET /tramites/{uuid_falso} debe retornar 404."""
    fake_id = uuid4()
    response = client_analista.get(f"/api/v1/tramites/{fake_id}")
    assert response.status_code == 404
    assert response.json()["detail"]["error_code"] == "TRAMITE_NO_ENCONTRADO"


def test_agregar_nota_analista(client_analista, tramite_recibido):
    """POST /tramites/{id}/eventos con tipo nota_analista retorna 201."""
    tramite_id = tramite_recibido["id"]
    response = client_analista.post(
        f"/api/v1/tramites/{tramite_id}/eventos",
        json={
            "descripcion": "Nota de prueba de integración",
            "tipo_evento": "nota_analista",
        },
    )
    assert response.status_code == 201
    data = response.json()
    assert data["tipo_evento"] == "nota_analista"
    assert data["descripcion"] == "Nota de prueba de integración"


def test_tipo_evento_no_permitido_retorna_422(client_analista, tramite_recibido):
    """POST /eventos con tipo correo_recibido (no permitido manualmente) retorna 422."""
    tramite_id = tramite_recibido["id"]
    response = client_analista.post(
        f"/api/v1/tramites/{tramite_id}/eventos",
        json={
            "descripcion": "Intento de evento no permitido",
            "tipo_evento": "correo_recibido",
        },
    )
    assert response.status_code == 422
    assert response.json()["detail"]["error_code"] == "TIPO_EVENTO_NO_PERMITIDO"

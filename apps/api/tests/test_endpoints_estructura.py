"""
Smoke tests de estructura de endpoints — Capa 1.

Verifica que los endpoints responden con los códigos correctos y que las respuestas
tienen la estructura esperada (campos presentes, tipos correctos).
Los endpoints que acceden a DB tienen la DB mockeada vía monkeypatch.
"""
from unittest.mock import MagicMock
from uuid import uuid4

# ---------------------------------------------------------------------------
# Helpers para mocking
# ---------------------------------------------------------------------------

def _mock_db_vacio():
    """Mock de cliente Supabase que devuelve listas y conteos vacíos."""
    db = MagicMock()
    vacío = MagicMock()
    vacío.count = 0
    vacío.data = []
    # Cubre: select().eq().execute() y select().eq().order().range().execute()
    db.table.return_value.select.return_value.eq.return_value.execute.return_value = vacío
    db.table.return_value.select.return_value.eq.return_value.order.return_value.range.return_value.execute.return_value = vacío
    # Cubre: select().eq().eq().execute() (notificaciones/conteo)
    db.table.return_value.select.return_value.eq.return_value.eq.return_value.execute.return_value = vacío
    # Cubre: select().lte().gte().eq().execute() (coberturas/vigentes)
    db.table.return_value.select.return_value.lte.return_value.gte.return_value.eq.return_value.execute.return_value = vacío
    return db


# ---------------------------------------------------------------------------
# Health check — sin auth
# ---------------------------------------------------------------------------

def test_health_retorna_200_sin_auth(client):
    response = client.get("/health")
    assert response.status_code == 200


# ---------------------------------------------------------------------------
# Auth requerida — sin token
# ---------------------------------------------------------------------------

def test_tramites_sin_token_retorna_401_o_403(client):
    """HTTPBearer con auto_error=True devuelve 401 o 403 cuando no hay Authorization header."""
    response = client.get("/api/v1/tramites")
    assert response.status_code in (401, 403)


def test_notificaciones_sin_token_retorna_401_o_403(client):
    response = client.get("/api/v1/notificaciones/conteo")
    assert response.status_code in (401, 403)


def test_pipeline_schema_sin_token_retorna_401_o_403(client):
    """get_current_user_or_agent devuelve 401 cuando no hay ningún header de auth."""
    response = client.get("/api/v1/pipeline/schema/estados")
    assert response.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Pipeline schema — sin DB (solo JWT auth + retorno estático)
# ---------------------------------------------------------------------------

def test_pipeline_schema_estados_estructura(client_analista):
    """GET /pipeline/schema/estados no necesita DB; devuelve el grafo estático."""
    response = client_analista.get("/api/v1/pipeline/schema/estados")

    assert response.status_code == 200
    data = response.json()
    assert "estados" in data
    assert "transiciones" in data
    assert "estados_terminales" in data
    assert isinstance(data["estados"], list)
    assert isinstance(data["transiciones"], dict)
    # Los terminales deben incluir completado, rechazado_gnp y cancelado
    assert "completado" in data["estados_terminales"]
    assert "rechazado_gnp" in data["estados_terminales"]
    assert "cancelado" in data["estados_terminales"]
    # Todos los estados conocidos están en la respuesta
    assert "recibido" in data["estados"]
    assert "en_revision" in data["estados"]


def test_pipeline_schema_transiciones_coherentes(client_analista):
    """Las transiciones en el schema deben coincidir con el estado 'recibido'."""
    response = client_analista.get("/api/v1/pipeline/schema/estados")
    data = response.json()
    assert data["transiciones"]["recibido"] == ["en_revision"]
    assert data["transiciones"]["completado"] == []


# ---------------------------------------------------------------------------
# Pipeline iniciar — validación sin DB
# ---------------------------------------------------------------------------

def test_pipeline_iniciar_agente_invalido_retorna_422(client_analista):
    """El agente_inicio invalido falla ANTES de consultar la DB — no necesita mock."""
    tramite_id = uuid4()
    response = client_analista.post(
        f"/api/v1/pipeline/tramites/{tramite_id}/iniciar",
        json={"agente_inicio": "agente_99", "forzar": False},
    )

    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["error_code"] == "AGENTE_INVALIDO"
    assert "agente_99" in detail["mensaje"]
    # Debe listar los valores válidos
    assert "valores_validos" in detail
    assert "agente_1" in detail["valores_validos"]


def test_pipeline_iniciar_agentes_validos_son_1_a_6(client_analista):
    """Verifica que el schema muestra los 6 agentes como opciones válidas."""
    tramite_id = uuid4()
    response = client_analista.post(
        f"/api/v1/pipeline/tramites/{tramite_id}/iniciar",
        json={"agente_inicio": "agente_7"},  # agente_7 no existe
    )
    detail = response.json()["detail"]
    validos = detail["valores_validos"]
    assert sorted(validos) == ["agente_1", "agente_2", "agente_3", "agente_4", "agente_5", "agente_6"]


# ---------------------------------------------------------------------------
# Tramites — estructura PaginatedResponse (DB mockeada)
# ---------------------------------------------------------------------------

def test_tramites_lista_retorna_estructura_paginada(client_analista, monkeypatch):
    monkeypatch.setattr("routers.tramites.get_user_db", lambda token: _mock_db_vacio())

    response = client_analista.get("/api/v1/tramites")

    assert response.status_code == 200
    data = response.json()
    assert "items" in data
    assert "total" in data
    assert "offset" in data
    assert "limit" in data
    assert "has_more" in data
    assert isinstance(data["items"], list)
    assert data["total"] == 0
    assert data["has_more"] is False


def test_tramites_lista_respeta_limit_offset_defaults(client_analista, monkeypatch):
    monkeypatch.setattr("routers.tramites.get_user_db", lambda token: _mock_db_vacio())

    response = client_analista.get("/api/v1/tramites")
    data = response.json()
    assert data["offset"] == 0
    assert data["limit"] == 50  # default del endpoint


# ---------------------------------------------------------------------------
# Notificaciones conteo — estructura (DB mockeada)
# ---------------------------------------------------------------------------

def test_notificaciones_conteo_retorna_no_leidas(client_analista, monkeypatch):
    mock_db = MagicMock()
    mock_db.table.return_value.select.return_value.eq.return_value.eq.return_value.execute.return_value.count = 5
    monkeypatch.setattr("routers.notificaciones.get_user_db", lambda token: mock_db)

    response = client_analista.get("/api/v1/notificaciones/conteo")

    assert response.status_code == 200
    data = response.json()
    assert "no_leidas" in data
    assert data["no_leidas"] == 5


def test_notificaciones_conteo_retorna_cero_cuando_no_hay(client_analista, monkeypatch):
    mock_db = MagicMock()
    mock_db.table.return_value.select.return_value.eq.return_value.eq.return_value.execute.return_value.count = 0
    monkeypatch.setattr("routers.notificaciones.get_user_db", lambda token: mock_db)

    response = client_analista.get("/api/v1/notificaciones/conteo")
    assert response.json()["no_leidas"] == 0


# ---------------------------------------------------------------------------
# Coberturas vigentes — estructura (DB mockeada)
# ---------------------------------------------------------------------------

def test_coberturas_vigentes_retorna_lista(client_analista, monkeypatch):
    monkeypatch.setattr("routers.coberturas.get_user_db", lambda token: _mock_db_vacio())

    response = client_analista.get("/api/v1/coberturas/vigentes")

    assert response.status_code == 200
    assert isinstance(response.json(), list)


# ---------------------------------------------------------------------------
# Actualizar trámite — sin_cambios retorna 422
# ---------------------------------------------------------------------------

def test_patch_tramite_sin_campos_retorna_422(client_analista, monkeypatch):
    """PATCH /tramites/{id} sin ningún campo debe devolver SIN_CAMBIOS."""
    tramite_id = uuid4()
    monkeypatch.setattr("routers.tramites.get_user_db", lambda token: _mock_db_vacio())

    response = client_analista.patch(
        f"/api/v1/tramites/{tramite_id}",
        json={},  # sin campos
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error_code"] == "SIN_CAMBIOS"

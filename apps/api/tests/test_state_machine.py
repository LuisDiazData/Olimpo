"""
Tests de la máquina de estados del trámite — Capa 1 (sin DB real).

Cubre:
  - Completitud y coherencia del dict TRANSICIONES_VALIDAS
  - Lógica de _enriquecer_tramite (transiciones_disponibles, campos relacionales)
  - Validaciones del endpoint cambiar-estado: transición inválida, motivos requeridos
"""
from unittest.mock import MagicMock
from uuid import uuid4

from models.tramite import TRANSICIONES_VALIDAS, EstadoTramite
from routers.tramites import _enriquecer_tramite

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _tramite_fake(estado: str) -> dict:
    return {
        "id": str(uuid4()),
        "estado": estado,
        "analista_id": None,
        "ramo": None,
        "activo": True,
        "folio_ot": None,
    }


def _base_enriquecer(estado: str) -> dict:
    """Devuelve el dict mínimo necesario para _enriquecer_tramite."""
    return {
        "id": str(uuid4()),
        "estado": estado,
        "analista_id": None,
        "ramo": "vida",
        "activo": True,
        "folio_ot": None,
        "agente": None,
        "usuario": None,
        "poliza": None,
        "asegurado": None,
    }


# ---------------------------------------------------------------------------
# TRANSICIONES_VALIDAS — integridad del grafo
# ---------------------------------------------------------------------------

class TestTransicionesValidas:
    def test_todos_los_estados_estan_en_el_dict(self):
        for estado in EstadoTramite:
            assert estado in TRANSICIONES_VALIDAS, f"'{estado}' no está en TRANSICIONES_VALIDAS"

    def test_estados_terminales_tienen_lista_vacia(self):
        assert TRANSICIONES_VALIDAS[EstadoTramite.completado] == []
        assert TRANSICIONES_VALIDAS[EstadoTramite.rechazado_gnp] == []
        assert TRANSICIONES_VALIDAS[EstadoTramite.cancelado] == []

    def test_recibido_solo_transiciona_a_en_revision(self):
        destinos = TRANSICIONES_VALIDAS[EstadoTramite.recibido]
        assert destinos == [EstadoTramite.en_revision]

    def test_todos_los_destinos_son_estados_validos(self):
        estados_validos = set(EstadoTramite)
        for estado, destinos in TRANSICIONES_VALIDAS.items():
            for destino in destinos:
                assert destino in estados_validos, f"Destino desconocido: '{destino}' desde '{estado}'"

    def test_no_hay_ciclos_simples_en_terminales(self):
        for estado_terminal in [EstadoTramite.completado, EstadoTramite.rechazado_gnp, EstadoTramite.cancelado]:
            assert EstadoTramite.recibido not in TRANSICIONES_VALIDAS[estado_terminal]

    def test_pendiente_documentos_agente_puede_volver_a_en_revision(self):
        destinos = TRANSICIONES_VALIDAS[EstadoTramite.pendiente_documentos_agente]
        assert EstadoTramite.en_revision in destinos

    def test_turnado_a_gnp_puede_llegar_a_completado_y_rechazado(self):
        destinos = TRANSICIONES_VALIDAS[EstadoTramite.turnado_a_gnp]
        assert EstadoTramite.completado in destinos
        assert EstadoTramite.rechazado_gnp in destinos


# ---------------------------------------------------------------------------
# _enriquecer_tramite — lógica de transformación
# ---------------------------------------------------------------------------

class TestEnriquecerTramite:
    def test_transiciones_desde_recibido(self):
        data = _enriquecer_tramite(_base_enriquecer("recibido"))
        assert data["transiciones_disponibles"] == ["en_revision"]

    def test_transiciones_desde_completado_vacio(self):
        data = _enriquecer_tramite(_base_enriquecer("completado"))
        assert data["transiciones_disponibles"] == []

    def test_transiciones_desde_rechazado_gnp_vacio(self):
        data = _enriquecer_tramite(_base_enriquecer("rechazado_gnp"))
        assert data["transiciones_disponibles"] == []

    def test_transiciones_desde_cancelado_vacio(self):
        data = _enriquecer_tramite(_base_enriquecer("cancelado"))
        assert data["transiciones_disponibles"] == []

    def test_transiciones_desde_en_revision(self):
        data = _enriquecer_tramite(_base_enriquecer("en_revision"))
        assert set(data["transiciones_disponibles"]) == {
            "pendiente_documentos_agente", "turnado_a_gnp", "escalado"
        }

    def test_transiciones_desde_turnado_a_gnp(self):
        data = _enriquecer_tramite(_base_enriquecer("turnado_a_gnp"))
        assert set(data["transiciones_disponibles"]) == {"activado_gnp", "completado", "rechazado_gnp"}

    def test_estado_invalido_retorna_transiciones_vacias(self):
        data = _enriquecer_tramite(_base_enriquecer("estado_inventado"))
        assert data["transiciones_disponibles"] == []

    def test_agente_none_cuando_no_hay_relacion(self):
        data = _enriquecer_tramite(_base_enriquecer("recibido"))
        assert data["agente_nombre"] is None
        assert data["agente_cua"] is None

    def test_analista_nombre_none_cuando_no_hay_relacion(self):
        data = _enriquecer_tramite(_base_enriquecer("recibido"))
        assert data["analista_nombre"] is None

    def test_agente_aplanado_correctamente(self):
        base = _base_enriquecer("recibido")
        base["agente"] = {"nombre": "Agente Test", "cua": "CUA123"}
        data = _enriquecer_tramite(base)
        assert data["agente_nombre"] == "Agente Test"
        assert data["agente_cua"] == "CUA123"
        assert "agente" not in data  # La clave original se eliminó (pop)

    def test_poliza_numero_extraido(self):
        base = _base_enriquecer("recibido")
        base["poliza"] = {"numero_poliza": "POL-001"}
        data = _enriquecer_tramite(base)
        assert data["poliza_numero"] == "POL-001"


# ---------------------------------------------------------------------------
# Endpoint POST /tramites/{id}/cambiar-estado — validaciones sin DB real
# ---------------------------------------------------------------------------

def test_cambiar_estado_transicion_invalida_retorna_422(client_analista, monkeypatch):
    """recibido → completado es una transición inválida; debe devolver TRANSICION_INVALIDA."""
    tramite = _tramite_fake("recibido")
    monkeypatch.setattr("routers.tramites._get_tramite_o_404", lambda db, tid: tramite)
    monkeypatch.setattr("routers.tramites.get_user_db", lambda token: MagicMock())

    response = client_analista.post(
        f"/api/v1/tramites/{tramite['id']}/cambiar-estado",
        json={"estado_nuevo": "completado"},
    )

    assert response.status_code == 422
    detail = response.json()["detail"]
    assert detail["error_code"] == "TRANSICION_INVALIDA"
    assert "en_revision" in detail["transiciones_validas"]
    assert detail["estado_actual"] == "recibido"
    assert detail["estado_solicitado"] == "completado"


def test_cambiar_estado_rechazo_sin_motivo_gnp(client_analista, monkeypatch):
    """turnado_a_gnp → rechazado_gnp sin motivo_rechazo_gnp debe devolver MOTIVO_REQUERIDO."""
    tramite = _tramite_fake("turnado_a_gnp")
    monkeypatch.setattr("routers.tramites._get_tramite_o_404", lambda db, tid: tramite)
    monkeypatch.setattr("routers.tramites.get_user_db", lambda token: MagicMock())

    response = client_analista.post(
        f"/api/v1/tramites/{tramite['id']}/cambiar-estado",
        json={"estado_nuevo": "rechazado_gnp"},  # sin motivo_rechazo_gnp
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error_code"] == "MOTIVO_REQUERIDO"


def test_cambiar_estado_pendiente_docs_sin_motivo(client_analista, monkeypatch):
    """en_revision → pendiente_documentos_agente sin motivo debe devolver MOTIVO_REQUERIDO."""
    tramite = _tramite_fake("en_revision")
    monkeypatch.setattr("routers.tramites._get_tramite_o_404", lambda db, tid: tramite)
    monkeypatch.setattr("routers.tramites.get_user_db", lambda token: MagicMock())

    response = client_analista.post(
        f"/api/v1/tramites/{tramite['id']}/cambiar-estado",
        json={"estado_nuevo": "pendiente_documentos_agente"},  # sin motivo
    )

    assert response.status_code == 422
    assert response.json()["detail"]["error_code"] == "MOTIVO_REQUERIDO"

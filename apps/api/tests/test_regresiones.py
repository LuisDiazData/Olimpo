"""
Tests de regresión — Capa 1 (sin DB).

Verifica que los bugs identificados y corregidos durante el desarrollo
no vuelvan a aparecer. Cada test está vinculado a un fix específico.
"""

import inspect

# ---------------------------------------------------------------------------
# Regresión 1: Importación de todos los routers sin errores
# ---------------------------------------------------------------------------


def test_from_main_import_app_no_lanza_excepcion():
    """from main import app debe completar sin ImportError ni ValidationError."""
    from main import app  # noqa: F401 — solo verificamos que importa

    assert app is not None


def test_los_12_routers_estan_registrados():
    """Verifica que los 12 routers están registrados en la app de FastAPI."""
    from main import app

    # Recopilamos todos los tags de las rutas registradas
    tags_registrados: set[str] = set()
    for route in app.routes:
        if hasattr(route, "tags"):
            tags_registrados.update(route.tags)

    tags_esperados = {
        "sistema",  # health.router usa tags=["sistema"]
        "usuarios",
        "agentes",
        "asignaciones",
        "tramites",
        "polizas",
        "correos",
        "activaciones",
        "notificaciones",
        "slas",
        "coberturas",
        "pipeline",
    }
    faltantes = tags_esperados - tags_registrados
    assert not faltantes, f"Routers no registrados: {faltantes}"


# ---------------------------------------------------------------------------
# Regresión 2: Bug get_db en asignaciones.py
# El router original importaba get_db que no existe como función directa.
# El fix fue usar get_user_db(usuario.access_token) correctamente.
# ---------------------------------------------------------------------------


def test_asignaciones_router_importa_sin_error():
    """from routers.asignaciones import router no debe lanzar ImportError."""
    from routers.asignaciones import router  # noqa: F401

    assert router is not None


def test_asignaciones_usa_get_user_db_no_get_db():
    """asignaciones.py debe importar get_user_db y get_admin_db, NO llamar get_db directamente."""
    import inspect

    import routers.asignaciones as mod

    source = inspect.getsource(mod)
    # get_user_db debe estar presente
    assert "get_user_db" in source, "get_user_db no encontrado en asignaciones.py"
    # Verificar que no hay un import incorrecto de get_db como función independiente
    # (get_db existe en database.py como dependencia FastAPI, no para uso directo)
    assert "get_db(usuario" not in source, "Se encontró uso directo de get_db() como llamada"


# ---------------------------------------------------------------------------
# Regresión 3: Bug double-auth en correos.py
# DELETE /tramites/{id}/correos/{correo_id} tenía tanto dependencies=_SOLO_DIRECTORES
# como usuario: UsuarioToken = Depends(get_current_user) en la firma — el JWT
# se decodificaba dos veces.
# ---------------------------------------------------------------------------


def test_desvincular_correo_tramite_no_tiene_doble_auth():
    """
    La función desvincular_correo_tramite NO debe tener 'usuario' como parámetro
    cuando ya tiene dependencies=_SOLO_DIRECTORES. El bug era doble decodificación del JWT.
    """
    from routers.correos import desvincular_correo_tramite

    sig = inspect.signature(desvincular_correo_tramite)
    assert "usuario" not in sig.parameters, (
        "desvincular_correo_tramite tiene el parámetro 'usuario' pero ya usa "
        "dependencies=_SOLO_DIRECTORES — esto causaría doble decodificación del JWT."
    )


def test_desvincular_correo_tramite_tiene_parametros_correctos():
    """La función solo debe tener tramite_id y correo_id como parámetros."""
    from routers.correos import desvincular_correo_tramite

    sig = inspect.signature(desvincular_correo_tramite)
    params = set(sig.parameters.keys())
    assert params == {"tramite_id", "correo_id"}, f"Parámetros inesperados: {params}"


# ---------------------------------------------------------------------------
# Regresión 4: Modelos clave importan correctamente
# ---------------------------------------------------------------------------


def test_pagination_model_importa():
    from models.pagination import PaginatedResponse

    assert PaginatedResponse is not None


def test_tramite_models_importan():
    from models.tramite import (
        TRANSICIONES_VALIDAS,
        EstadoTramite,
    )

    assert len(TRANSICIONES_VALIDAS) == len(EstadoTramite)


def test_asignacion_model_importa():
    from models.asignacion import AsignacionCreate, ResolverAsignacionResponse

    assert AsignacionCreate is not None
    assert ResolverAsignacionResponse is not None


def test_usuario_model_importa():
    from models.usuario import RamoUsuario, RolUsuario

    assert len(list(RolUsuario)) == 4
    assert len(list(RamoUsuario)) == 4


# ---------------------------------------------------------------------------
# Regresión 5: TramiteResponse incluye transiciones_disponibles
# ---------------------------------------------------------------------------


def test_tramite_response_tiene_transiciones_disponibles():
    """TramiteResponse debe tener el campo transiciones_disponibles para compatibilidad MCP."""
    from models.tramite import TramiteResponse

    campos = TramiteResponse.model_fields
    assert "transiciones_disponibles" in campos


def test_cambiar_estado_body_tiene_motivo():
    """CambiarEstadoBody debe tener el campo 'motivo' para pendiente_documentos."""
    from models.tramite import CambiarEstadoBody

    campos = CambiarEstadoBody.model_fields
    assert "motivo" in campos
    assert "motivo_rechazo_gnp" in campos
    assert "folio_ot" in campos

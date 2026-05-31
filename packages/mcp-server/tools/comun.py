"""
Herramientas transversales — usadas por todos los agentes.
Incluye: log de ejecución, configuración del sistema, lectura de trámites.
"""

from __future__ import annotations

from typing import Any

import structlog

from core.db import get_db
from core.mcp_instance import mcp

log = structlog.get_logger(__name__)


# =============================================================================
# CONFIGURACIÓN DEL SISTEMA
# =============================================================================

@mcp.tool()
def obtener_configuracion_agentes() -> dict[str, Any]:
    """Retorna todos los umbrales y parámetros de IA configurados en el sistema.

    Llamar al inicio de cada pipeline para cachear los valores.
    Incluye: CONFIDENCE_AGENTE, CONFIDENCE_DOCUMENTO, FUZZY_MATCH_NOMBRE,
    TIMEOUT_PASSWORD_HORAS, umbrales RAG y otros parámetros operativos.

    Returns: {"configuracion": {"CLAVE": {"valor": "...", "tipo": "..."}}}
    """
    db = get_db()
    result = db.rpc("obtener_config_agentes", {}).execute()
    config: dict[str, dict] = {}
    for row in (result.data or []):
        config[row["clave"]] = {"valor": row["valor"], "tipo": row["tipo_valor"]}
    return {"configuracion": config}


# =============================================================================
# LECTURA DE TRÁMITES
# =============================================================================

@mcp.tool()
def obtener_tramite(tramite_id: str) -> dict[str, Any]:
    """Lee un trámite completo por su ID UUID.

    Retorna todos los campos del trámite incluyendo estado, analista asignado,
    folio, ramo, tipo, prioridad y timestamps.

    Args:
        tramite_id: UUID del trámite.

    Returns: {"tramite": {...}} o {"error": "no encontrado"}
    """
    db = get_db()
    result = db.table("tramite").select("*").eq("id", tramite_id).maybe_single().execute()
    if not result.data:
        return {"error": f"Trámite no encontrado: {tramite_id}"}
    return {"tramite": result.data}


@mcp.tool()
def obtener_contexto_tramite_completo(tramite_id: str) -> dict[str, Any]:
    """Lee el trámite con todos sus datos relacionados para el Agente 6 (Redacción).

    Retorna tramite, eventos recientes, documentos, datos del agente de seguros,
    analista asignado y póliza vinculada. Diseñado para que el Agente 6 tenga
    todo el contexto necesario para redactar el correo sin queries adicionales.

    Args:
        tramite_id: UUID del trámite.

    Returns: {"tramite": {...}, "eventos": [...], "documentos": [...],
              "agente_seguro": {...}, "analista": {...}, "poliza": {...}}
    """
    db = get_db()

    tramite_result = db.table("tramite").select(
        "*, poliza(*), agente(*), asistente(*)"
    ).eq("id", tramite_id).maybe_single().execute()

    if not tramite_result.data:
        return {"error": f"Trámite no encontrado: {tramite_id}"}

    tramite = tramite_result.data

    # Analista asignado con firma HTML
    analista = None
    if tramite.get("analista_id"):
        r = db.table("usuario").select(
            "id, nombre, email, telefono, firma_html, ramo"
        ).eq("id", tramite["analista_id"]).maybe_single().execute()
        analista = r.data

    # Últimos 10 eventos del historial
    eventos_r = db.table("tramite_evento").select("*").eq(
        "tramite_id", tramite_id
    ).order("created_at", desc=True).limit(10).execute()

    # Documentos con estado de validación
    docs_r = db.table("documento").select(
        "id, tipo_documento, estado_validacion, datos_extraidos, confianza_ocr, "
        "confianza_clasificacion, observaciones_validacion, adjunto_id"
    ).eq("tramite_id", tramite_id).execute()

    return {
        "tramite": tramite,
        "analista": analista,
        "eventos": eventos_r.data or [],
        "documentos": docs_r.data or [],
    }


@mcp.tool()
def agregar_evento_tramite(
    tramite_id: str,
    tipo_evento: str,
    descripcion: str,
    agente_ia_nombre: str | None = None,
    usuario_id: str | None = None,
    datos: dict | None = None,
    visible_en_timeline: bool = True,
) -> dict[str, Any]:
    """Registra un evento en el historial inmutable del trámite.

    El historial tramite_evento es append-only. Nunca se edita ni borra.
    Alimenta el RAG con contexto cronológico del trámite.

    Args:
        tramite_id: UUID del trámite.
        tipo_evento: Uno de: creacion, cambio_estado, asignacion, reasignacion,
            nota_analista, documento_agregado, correo_recibido, correo_enviado,
            accion_agente_ia, activacion_gnp, solicitud_documentos, rechazo_gnp,
            aprendizaje_rag.
        descripcion: Texto legible y autocontenido del evento. REQUERIDO.
            Ej: 'El Agente 5 validó 3 documentos. Falta: carta médica.'.
        agente_ia_nombre: Nombre del agente IA si el actor es IA.
            Ej: 'agente_1', 'agente_5'. Mutuamente excluyente con usuario_id.
        usuario_id: UUID del usuario humano si el actor es un analista/gerente.
            Mutuamente excluyente con agente_ia_nombre.
        datos: Datos estructurados del evento en JSON.
            Ej: {"numero_agente": 3, "confianza": 0.87, "documentos_validos": 2}.
        visible_en_timeline: False para eventos internos de IA que no necesitan
            aparecer en la UI del analista pero sí en el RAG (default True).

    Returns: {"evento_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "tramite_id": tramite_id,
        "tipo_evento": tipo_evento,
        "descripcion": descripcion,
        "visible_en_timeline": visible_en_timeline,
    }
    if agente_ia_nombre:
        payload["agente_ia_nombre"] = agente_ia_nombre
    if usuario_id:
        payload["usuario_id"] = usuario_id
    if datos:
        payload["datos"] = datos

    result = db.table("tramite_evento").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo registrar el evento"}
    return {"evento_id": result.data[0]["id"]}


# =============================================================================
# LOG DE EJECUCIÓN DE AGENTES IA
# =============================================================================

@mcp.tool()
def registrar_log_agente(
    numero_agente: int,
    nombre_agente: str,
    tramite_id: str | None,
    estado: str,
    tokens_entrada: int | None = None,
    tokens_salida: int | None = None,
    costo_usd: float | None = None,
    duracion_ms: int | None = None,
    modelo_llm: str | None = None,
    langfuse_trace_id: str | None = None,
    resultado: dict | None = None,
    error: str | None = None,
) -> dict[str, Any]:
    """Registra la ejecución de un agente IA en el log de auditoría.

    Llamar al finalizar cada agente (éxito o fallo). El log es append-only
    y se usa para métricas de rendimiento, costos y debugging en Langfuse.

    Args:
        numero_agente: 1-6 (número del agente en el pipeline).
        nombre_agente: Nombre descriptivo. Ej: 'Agente 1 - Ingesta'.
        tramite_id: UUID del trámite procesado (None si no aplica).
        estado: 'iniciado' | 'completado' | 'fallido'.
        tokens_entrada: Tokens consumidos en el prompt.
        tokens_salida: Tokens generados en la respuesta.
        costo_usd: Costo aproximado en USD (calculado por LiteLLM).
        duracion_ms: Duración total de ejecución del agente en milisegundos.
        modelo_llm: Modelo usado. Ej: 'gpt-4o', 'claude-sonnet-4-6'.
        langfuse_trace_id: ID del trace en Langfuse para correlación.
        resultado: Resultado estructurado del agente (JSON serializable).
        error: Mensaje de error si estado='fallido'.

    Returns: {"log_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "numero_agente": numero_agente,
        "nombre_agente": nombre_agente,
        "estado": estado,
    }
    if tramite_id:
        payload["tramite_id"] = tramite_id
    if tokens_entrada is not None:
        payload["tokens_entrada"] = tokens_entrada
    if tokens_salida is not None:
        payload["tokens_salida"] = tokens_salida
    if costo_usd is not None:
        payload["costo_usd"] = str(costo_usd)
    if duracion_ms is not None:
        payload["duracion_ms"] = duracion_ms
    if modelo_llm:
        payload["modelo_llm"] = modelo_llm
    if langfuse_trace_id:
        payload["langfuse_trace_id"] = langfuse_trace_id
    if resultado:
        payload["resultado"] = resultado
    if error:
        payload["error"] = error

    result = db.table("agente_ia_log").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo registrar el log"}
    return {"log_id": result.data[0]["id"]}

"""
Herramientas para el Agente 2 — Comprensión del correo.

Extrae datos estructurados del cuerpo del correo y crea el trámite en la DB.
"""

from __future__ import annotations

from typing import Any

from core.db import get_db
from core.mcp_instance import mcp


@mcp.tool()
def crear_tramite(
    correo_id: str,
    tipo_tramite: str,
    ramo: str,
    canal_origen: str = "email",
    numero_poliza: str | None = None,
    agente_id: str | None = None,
    asistente_id: str | None = None,
    poliza_id: str | None = None,
    asegurado_id: str | None = None,
    prioridad: str = "normal",
    datos_extraidos: dict | None = None,
    confianza_comprension: float | None = None,
    notas_agente: str | None = None,
) -> dict[str, Any]:
    """Crea un nuevo trámite a partir de los datos extraídos del correo.

    El Agente 2 llama esto después de analizar el cuerpo del correo con el LLM.
    El folio TRM-YYYY-NNNNN se genera automáticamente por la DB.

    Args:
        correo_id: UUID del correo que originó este trámite.
        tipo_tramite: alta | endoso | renovacion | cancelacion | siniestro |
            reactivacion | consulta | desconocido.
        ramo: vida | gmm | autos | pyme.
        canal_origen: email | manual | portal. Default: 'email'.
        numero_poliza: Número de póliza extraído del correo (texto libre).
        agente_id: UUID del agente de seguros (si ya fue identificado).
        asistente_id: UUID del asistente del agente (si aplica).
        poliza_id: UUID de la póliza en el catálogo (si ya se vinculó).
        asegurado_id: UUID del asegurado (si ya se identificó).
        prioridad: normal | alta | urgente. Default: 'normal'.
        datos_extraidos: Datos estructurados del LLM en JSON.
        confianza_comprension: Score de confianza del Agente 2 (0.0-1.0).
        notas_agente: Observaciones del Agente 2 para el analista.

    Returns: {"tramite_id": "<uuid>", "folio": "TRM-2025-NNNNN"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "tipo_tramite": tipo_tramite,
        "ramo": ramo,
        "canal_origen": canal_origen,
        "estado": "recibido",
        "prioridad": prioridad,
    }
    if numero_poliza:
        payload["numero_poliza_referencia"] = numero_poliza
    if agente_id:
        payload["agente_id"] = agente_id
    if asistente_id:
        payload["asistente_id"] = asistente_id
    if poliza_id:
        payload["poliza_id"] = poliza_id
    if asegurado_id:
        payload["asegurado_id"] = asegurado_id
    if datos_extraidos:
        payload["datos_extraidos_agente2"] = datos_extraidos
    if confianza_comprension is not None:
        payload["confianza_comprension"] = confianza_comprension
    if notas_agente:
        payload["notas_agente_ia"] = notas_agente

    result = db.table("tramite").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo crear el trámite"}

    tramite = result.data[0]

    # Vincular correo ↔ trámite como correo origen
    db.table("correo_tramite").insert({
        "correo_id": correo_id,
        "tramite_id": tramite["id"],
        "es_origen": True,
    }).execute()

    return {"tramite_id": tramite["id"], "folio": tramite.get("folio", "")}


@mcp.tool()
def vincular_correo_tramite(
    correo_id: str,
    tramite_id: str,
    es_origen: bool = False,
) -> dict[str, Any]:
    """Vincula un correo de seguimiento a un trámite existente.

    Un correo puede estar vinculado a múltiples trámites y un trámite puede
    tener múltiples correos. Solo uno puede ser es_origen=True.

    Args:
        correo_id: UUID del correo.
        tramite_id: UUID del trámite.
        es_origen: True si este correo creó el trámite (default False).

    Returns: {"ok": true} o {"error": "ya vinculado"}
    """
    db = get_db()

    # Idempotencia
    existing = db.table("correo_tramite").select("correo_id").eq(
        "correo_id", correo_id
    ).eq("tramite_id", tramite_id).maybe_single().execute()

    if existing.data:
        return {"ok": True, "ya_existia": True}

    db.table("correo_tramite").insert({
        "correo_id": correo_id,
        "tramite_id": tramite_id,
        "es_origen": es_origen,
    }).execute()
    return {"ok": True, "ya_existia": False}


@mcp.tool()
def actualizar_tramite(
    tramite_id: str,
    campos: dict[str, Any],
) -> dict[str, Any]:
    """Actualiza campos específicos de un trámite.

    Usar solo para campos de datos (tipo, ramo, agente_id, etc.).
    Para cambios de estado usar cambiar_estado_tramite que valida la máquina de estados.

    Args:
        tramite_id: UUID del trámite.
        campos: Diccionario de campos a actualizar. Ejemplo:
            {"agente_id": "uuid...", "confianza_comprension": 0.92,
             "datos_extraidos_agente2": {"nombre_asegurado": "Juan García"}}

    Returns: {"ok": true}
    """
    db = get_db()
    # Nunca permitir actualizar estado por esta vía
    campos.pop("estado", None)
    campos.pop("id", None)
    campos.pop("folio", None)
    campos.pop("created_at", None)

    db.table("tramite").update(campos).eq("id", tramite_id).execute()
    return {"ok": True}

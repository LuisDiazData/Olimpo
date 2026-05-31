"""
Herramientas para el Agente 6 — Redacción de correos de respuesta.

El Agente 6 genera borradores de correos profesionales para que el analista
los revise y apruebe antes de enviar vía Gmail API.
"""

from __future__ import annotations

from typing import Any

from core.db import get_db
from core.mcp_instance import mcp


@mcp.tool()
def obtener_firma_analista(analista_id: str) -> dict[str, Any]:
    """Obtiene la firma HTML del analista para incluir en el correo borrador.

    Args:
        analista_id: UUID del analista asignado al trámite.

    Returns: {"nombre": "...", "email": "...", "telefono": "...", "firma_html": "..."}
    """
    db = get_db()
    result = db.table("usuario").select(
        "nombre, email, telefono, firma_html"
    ).eq("id", analista_id).maybe_single().execute()

    if not result.data:
        return {"error": f"Analista no encontrado: {analista_id}"}
    return result.data


@mcp.tool()
def crear_correo_borrador(
    tramite_id: str,
    analista_id: str,
    destinatario_email: str,
    destinatario_nombre: str,
    asunto: str,
    cuerpo_html: str,
    cuerpo_texto: str | None = None,
    correo_origen_id: str | None = None,
    gmail_thread_id: str | None = None,
) -> dict[str, Any]:
    """Crea un borrador de correo saliente para revisión del analista.

    El borrador queda en estado 'borrador' hasta que el analista lo apruebe
    desde la UI del CRM. Solo entonces se envía vía Gmail API.

    Args:
        tramite_id: UUID del trámite al que responde este correo.
        analista_id: UUID del analista que revisará y enviará el correo.
        destinatario_email: Email del agente/asistente destinatario.
        destinatario_nombre: Nombre del destinatario.
        asunto: Asunto del correo (incluir Re: si es respuesta).
        cuerpo_html: HTML del correo generado por el Agente 6.
        cuerpo_texto: Versión texto plano del correo (fallback).
        correo_origen_id: UUID del correo entrante al que responde.
        gmail_thread_id: ID del hilo de Gmail para mantener la conversación.

    Returns: {"correo_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "tipo": "saliente",
        "estado": "borrador",
        "analista_id": analista_id,
        "remitente_email": "",  # se llena con el email del analista al enviar
        "remitente_nombre": "",
        "destinatario_email": destinatario_email,
        "destinatario_nombre": destinatario_nombre,
        "asunto": asunto,
        "cuerpo_html": cuerpo_html,
    }
    if cuerpo_texto:
        payload["cuerpo_texto"] = cuerpo_texto
    if gmail_thread_id:
        payload["gmail_thread_id"] = gmail_thread_id

    result = db.table("correo").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo crear el borrador"}

    correo_id = result.data[0]["id"]

    # Vincular el borrador al trámite
    db.table("correo_tramite").insert({
        "correo_id": correo_id,
        "tramite_id": tramite_id,
        "es_origen": False,
    }).execute()

    # Si es respuesta a un correo específico, vincular también
    if correo_origen_id:
        db.table("correo").update({
            "correo_responde_a_id": correo_origen_id,
        }).eq("id", correo_id).execute()

    return {"correo_id": correo_id}


@mcp.tool()
def listar_plantillas_correo(
    tipo_tramite: str | None = None,
    ramo: str | None = None,
) -> dict[str, Any]:
    """Lista plantillas de correo disponibles para el Agente 6.

    Las plantillas dan estructura al borrador y aseguran un tono profesional
    consistente con la imagen de la promotoría.

    Args:
        tipo_tramite: Filtrar por tipo de trámite (opcional).
        ramo: Filtrar por ramo (opcional).

    Returns: {"plantillas": [...]}
    """
    db = get_db()
    query = db.table("plantilla_correo").select(
        "id, nombre, asunto_template, cuerpo_html_template, tipo_tramite, ramo, activa"
    ).eq("activa", True)

    if tipo_tramite:
        query = query.eq("tipo_tramite", tipo_tramite)
    if ramo:
        query = query.eq("ramo", ramo)

    result = query.execute()
    return {"plantillas": result.data or []}

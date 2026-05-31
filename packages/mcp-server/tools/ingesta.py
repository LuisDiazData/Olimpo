"""
Herramientas para el Agente 1 — Ingesta de correos y adjuntos.

Pipeline:
  Gmail → registrar_correo → registrar_adjunto (x N) →
  registrar_adjunto_hijo (si ZIP) → limpiar_password_adjunto →
  actualizar_estado_correo('procesado')
"""

from __future__ import annotations

from typing import Any

from core.db import get_db
from core.mcp_instance import mcp


@mcp.tool()
def registrar_correo(
    gmail_message_id: str,
    gmail_thread_id: str,
    remitente_email: str,
    remitente_nombre: str,
    asunto: str,
    fecha_recibido: str,
    cuerpo_texto: str | None = None,
    cuerpo_html: str | None = None,
    analista_id: str | None = None,
) -> dict[str, Any]:
    """Registra un correo entrante de Gmail en la base de datos.

    Idempotente: si el gmail_message_id ya existe, retorna el registro existente
    sin crear duplicado. Llamar al inicio del pipeline del Agente 1.

    Args:
        gmail_message_id: ID único del mensaje en Gmail (Message-ID header).
        gmail_thread_id: ID del hilo de Gmail para agrupar conversaciones.
        remitente_email: Email del remitente (agente o asistente).
        remitente_nombre: Nombre del remitente extraído del header.
        asunto: Asunto del correo.
        fecha_recibido: Timestamp ISO 8601 de recepción. Ej: '2025-05-24T10:30:00Z'.
        cuerpo_texto: Cuerpo del correo en texto plano (optional).
        cuerpo_html: Cuerpo del correo en HTML (optional).
        analista_id: UUID del analista asignado (si ya se conoce).

    Returns: {"correo_id": "<uuid>", "ya_existia": bool}
    """
    db = get_db()

    # Idempotencia: verificar si ya existe
    existing = db.table("correo").select("id").eq(
        "gmail_message_id", gmail_message_id
    ).maybe_single().execute()

    if existing.data:
        return {"correo_id": existing.data["id"], "ya_existia": True}

    payload: dict[str, Any] = {
        "gmail_message_id": gmail_message_id,
        "gmail_thread_id": gmail_thread_id,
        "remitente_email": remitente_email,
        "remitente_nombre": remitente_nombre,
        "asunto": asunto,
        "fecha_recibido": fecha_recibido,
        "tipo": "entrante",
        "estado": "recibido",
    }
    if cuerpo_texto:
        payload["cuerpo_texto"] = cuerpo_texto
    if cuerpo_html:
        payload["cuerpo_html"] = cuerpo_html
    if analista_id:
        payload["analista_id"] = analista_id

    result = db.table("correo").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo registrar el correo"}
    return {"correo_id": result.data[0]["id"], "ya_existia": False}


@mcp.tool()
def registrar_adjunto(
    correo_id: str,
    nombre_archivo: str,
    mime_type: str,
    tamano_bytes: int,
    gmail_attachment_id: str | None = None,
    storage_path: str | None = None,
    es_zip: bool = False,
    password: str | None = None,
    adjunto_padre_id: str | None = None,
) -> dict[str, Any]:
    """Registra un adjunto del correo en la base de datos.

    Para archivos descomprimidos de un ZIP, usar adjunto_padre_id apuntando
    al adjunto ZIP original. El password es TEMPORAL — eliminar con
    limpiar_password_adjunto después de descomprimir.

    Args:
        correo_id: UUID del correo al que pertenece.
        nombre_archivo: Nombre original del archivo. Ej: 'solicitud_alta.pdf'.
        mime_type: MIME type. Ej: 'application/pdf', 'application/zip'.
        tamano_bytes: Tamaño en bytes.
        gmail_attachment_id: ID del adjunto en la API de Gmail.
        storage_path: Ruta en Supabase Storage (si ya se subió).
        es_zip: True si es un archivo ZIP que requiere descompresión.
        password: Contraseña del ZIP (TEMPORAL — se elimina después de descomprimir).
        adjunto_padre_id: UUID del ZIP padre si este adjunto proviene de uno.

    Returns: {"adjunto_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "correo_id": correo_id,
        "nombre_archivo": nombre_archivo,
        "mime_type": mime_type,
        "tamano_bytes": tamano_bytes,
        "estado": "pendiente",
    }
    if gmail_attachment_id:
        payload["gmail_attachment_id"] = gmail_attachment_id
    if storage_path:
        payload["storage_path"] = storage_path
    if es_zip:
        payload["es_zip"] = es_zip
    if password:
        payload["password"] = password
    if adjunto_padre_id:
        payload["adjunto_padre_id"] = adjunto_padre_id

    result = db.table("adjunto").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo registrar el adjunto"}
    return {"adjunto_id": result.data[0]["id"]}


@mcp.tool()
def actualizar_estado_adjunto(
    adjunto_id: str,
    estado: str,
    storage_path: str | None = None,
    error_detalle: str | None = None,
) -> dict[str, Any]:
    """Actualiza el estado de procesamiento de un adjunto.

    Estados válidos: pendiente | procesando | procesado | ilegible | error.

    Args:
        adjunto_id: UUID del adjunto.
        estado: Nuevo estado del adjunto.
        storage_path: Ruta en Supabase Storage (si se subió en este paso).
        error_detalle: Descripción del error (si estado='error' o 'ilegible').

    Returns: {"ok": true}
    """
    db = get_db()
    payload: dict[str, Any] = {"estado": estado}
    if storage_path:
        payload["storage_path"] = storage_path
    if error_detalle:
        payload["error_detalle"] = error_detalle

    db.table("adjunto").update(payload).eq("id", adjunto_id).execute()
    return {"ok": True}


@mcp.tool()
def limpiar_password_adjunto(adjunto_id: str) -> dict[str, Any]:
    """Elimina la contraseña del ZIP después de descomprimir todos sus archivos.

    CRÍTICO: Regla de seguridad del sistema — las contraseñas ZIP son temporales.
    Deben eliminarse inmediatamente después de extraer los archivos.
    Nunca persisten en la base de datos.

    Args:
        adjunto_id: UUID del adjunto ZIP cuya contraseña se debe eliminar.

    Returns: {"ok": true}
    """
    db = get_db()
    db.table("adjunto").update({"password": None}).eq("id", adjunto_id).execute()
    return {"ok": True}


@mcp.tool()
def actualizar_estado_correo(
    correo_id: str,
    estado: str,
    error_detalle: str | None = None,
) -> dict[str, Any]:
    """Actualiza el estado de procesamiento de un correo entrante.

    Estados para correos entrantes: recibido | procesando | procesado | error_procesamiento.

    Args:
        correo_id: UUID del correo.
        estado: Nuevo estado.
        error_detalle: Descripción del error si estado='error_procesamiento'.

    Returns: {"ok": true}
    """
    db = get_db()
    payload: dict[str, Any] = {"estado": estado}
    if error_detalle:
        payload["error_detalle"] = error_detalle

    db.table("correo").update(payload).eq("id", correo_id).execute()
    return {"ok": True}


@mcp.tool()
def listar_adjuntos_correo(correo_id: str) -> dict[str, Any]:
    """Lista todos los adjuntos de un correo.

    Incluye adjuntos directos y los hijos descomprimidos de ZIPs.

    Args:
        correo_id: UUID del correo.

    Returns: {"adjuntos": [...]}
    """
    db = get_db()
    result = db.table("adjunto").select(
        "id, nombre_archivo, mime_type, tamano_bytes, estado, "
        "es_zip, storage_path, adjunto_padre_id"
    ).eq("correo_id", correo_id).execute()
    return {"adjuntos": result.data or []}

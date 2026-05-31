"""
Herramientas para el Agente 3 — OCR y Clasificación de documentos.

El Agente 3 recibe los adjuntos procesados (PDFs, imágenes), los envía
a Phi-3/Mistral en RunPod para OCR, clasifica el tipo de documento,
y almacena los resultados estructurados en la tabla `documento`.
"""

from __future__ import annotations

from typing import Any

from core.db import get_db
from core.mcp_instance import mcp


@mcp.tool()
def listar_adjuntos_pendientes_ocr(tramite_id: str) -> dict[str, Any]:
    """Lista los adjuntos procesados que aún no tienen OCR.

    El Agente 3 llama esto para saber qué archivos debe procesar.
    Retorna adjuntos en estado 'procesado' sin documento asociado.

    Args:
        tramite_id: UUID del trámite.

    Returns: {"adjuntos": [{"id": ..., "nombre_archivo": ..., "storage_path": ...,
              "mime_type": ...}]}
    """
    db = get_db()

    # Adjuntos procesados del trámite via sus correos vinculados
    correos_r = db.table("correo_tramite").select("correo_id").eq(
        "tramite_id", tramite_id
    ).execute()
    correo_ids = [r["correo_id"] for r in (correos_r.data or [])]

    if not correo_ids:
        return {"adjuntos": []}

    # IDs de adjuntos que ya tienen documento
    docs_r = db.table("documento").select("adjunto_id").eq(
        "tramite_id", tramite_id
    ).execute()
    ya_procesados = {r["adjunto_id"] for r in (docs_r.data or [])}

    result = db.table("adjunto").select(
        "id, nombre_archivo, mime_type, storage_path, tamano_bytes"
    ).in_("correo_id", correo_ids).eq("estado", "procesado").execute()

    adjuntos = [
        a for a in (result.data or [])
        if a["id"] not in ya_procesados and a.get("storage_path")
    ]
    return {"adjuntos": adjuntos}


@mcp.tool()
def crear_documento(
    adjunto_id: str,
    tramite_id: str,
    tipo_documento: str,
    confianza_clasificacion: float,
    texto_ocr: str | None = None,
    datos_extraidos: dict | None = None,
    confianza_ocr: float | None = None,
    modelo_ocr: str | None = None,
    estado_validacion: str = "pendiente",
    observaciones: str | None = None,
) -> dict[str, Any]:
    """Crea el registro de documento con los resultados del OCR y clasificación.

    El Agente 3 llama esto después de procesar cada adjunto con el modelo OCR.

    Args:
        adjunto_id: UUID del adjunto físico que se procesó.
        tramite_id: UUID del trámite al que pertenece.
        tipo_documento: Tipo identificado. Ej: 'ine', 'solicitud_alta', 'carta_medica'.
            Valores válidos: ine, pasaporte, acta_nacimiento, curp, comprobante_domicilio,
            solicitud_alta, formulario_gnp, carta_medica, dictamen_medico,
            cuestionario_salud, poliza_anterior, estado_cuenta, comprobante_ingresos,
            escrituras, acta_constitutiva, poder_notarial, otro, no_identificado.
        confianza_clasificacion: Score de confianza en la clasificación (0.0-1.0).
        texto_ocr: Texto extraído por OCR (para búsqueda y auditoría).
        datos_extraidos: Campos estructurados extraídos. Ej:
            {"nombre": "Juan García", "fecha_vencimiento": "2028-03-15",
             "numero_ine": "GRJN850312..."}.
        confianza_ocr: Score de confianza del modelo OCR (0.0-1.0).
        modelo_ocr: Modelo usado. Ej: 'phi-3-vision', 'google-vision'.
        estado_validacion: pendiente | valido | invalido | requiere_revision.
        observaciones: Notas del Agente 3 para el analista.

    Returns: {"documento_id": "<uuid>"}
    """
    db = get_db()
    payload: dict[str, Any] = {
        "adjunto_id": adjunto_id,
        "tramite_id": tramite_id,
        "tipo_documento": tipo_documento,
        "confianza_clasificacion": confianza_clasificacion,
        "estado_validacion": estado_validacion,
    }
    if texto_ocr:
        payload["texto_ocr"] = texto_ocr
    if datos_extraidos:
        payload["datos_extraidos"] = datos_extraidos
    if confianza_ocr is not None:
        payload["confianza_ocr"] = confianza_ocr
    if modelo_ocr:
        payload["modelo_ocr"] = modelo_ocr
    if observaciones:
        payload["observaciones_validacion"] = observaciones

    result = db.table("documento").insert(payload).execute()
    if not result.data:
        return {"error": "No se pudo crear el documento"}
    return {"documento_id": result.data[0]["id"]}


@mcp.tool()
def actualizar_estado_validacion_documento(
    documento_id: str,
    estado_validacion: str,
    observaciones: str | None = None,
    datos_extraidos: dict | None = None,
) -> dict[str, Any]:
    """Actualiza el estado de validación de un documento ya existente.

    El Agente 5 llama esto después de validar cada documento contra los
    requisitos de GNP.

    Args:
        documento_id: UUID del documento.
        estado_validacion: pendiente | valido | invalido | requiere_revision.
        observaciones: Razón de la validación o rechazo (para el analista).
        datos_extraidos: Datos actualizados si el OCR necesitó corrección.

    Returns: {"ok": true}
    """
    db = get_db()
    payload: dict[str, Any] = {"estado_validacion": estado_validacion}
    if observaciones:
        payload["observaciones_validacion"] = observaciones
    if datos_extraidos:
        payload["datos_extraidos"] = datos_extraidos

    db.table("documento").update(payload).eq("id", documento_id).execute()
    return {"ok": True}


@mcp.tool()
def listar_documentos_tramite(tramite_id: str) -> dict[str, Any]:
    """Lista todos los documentos procesados de un trámite.

    Retorna tipo, estado de validación, confianzas y datos extraídos.
    El Agente 5 lo usa para obtener el inventario de documentos a validar.

    Args:
        tramite_id: UUID del trámite.

    Returns: {"documentos": [...], "resumen": {"total": N, "validos": N, ...}}
    """
    db = get_db()
    result = db.table("documento").select(
        "id, tipo_documento, estado_validacion, confianza_clasificacion, "
        "confianza_ocr, datos_extraidos, observaciones_validacion, adjunto_id, "
        "created_at"
    ).eq("tramite_id", tramite_id).execute()

    docs = result.data or []
    resumen = {
        "total": len(docs),
        "validos": sum(1 for d in docs if d["estado_validacion"] == "valido"),
        "invalidos": sum(1 for d in docs if d["estado_validacion"] == "invalido"),
        "pendientes": sum(1 for d in docs if d["estado_validacion"] == "pendiente"),
        "requieren_revision": sum(1 for d in docs if d["estado_validacion"] == "requiere_revision"),
    }
    return {"documentos": docs, "resumen": resumen}

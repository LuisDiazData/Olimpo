import sys
import os
import json
import base64
import requests
from enum import Enum
from typing import Optional

import structlog
from celery_app import celery_app
import litellm
from pydantic import BaseModel, Field

import fitz  # PyMuPDF

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from tools.ocr_clasificacion import listar_adjuntos_pendientes_ocr, crear_documento
from core.database import get_admin_db
from core.config import get_settings

log = structlog.get_logger(__name__)

class TipoDocumentoEnum(str, Enum):
    ine = "ine"
    pasaporte = "pasaporte"
    acta_nacimiento = "acta_nacimiento"
    curp = "curp"
    comprobante_domicilio = "comprobante_domicilio"
    solicitud_alta = "solicitud_alta"
    formulario_gnp = "formulario_gnp"
    carta_medica = "carta_medica"
    dictamen_medico = "dictamen_medico"
    cuestionario_salud = "cuestionario_salud"
    poliza_anterior = "poliza_anterior"
    endoso = "endoso"
    tarjeta_circulacion = "tarjeta_circulacion"
    factura_vehiculo = "factura_vehiculo"
    fotografia_vehiculo = "fotografia_vehiculo"
    acta_constitutiva = "acta_constitutiva"
    poder_notarial = "poder_notarial"
    cedula_fiscal = "cedula_fiscal"
    estado_cuenta = "estado_cuenta"
    comprobante_pago = "comprobante_pago"
    recibo_prima = "recibo_prima"
    otro = "otro"

class OCRDocumento(BaseModel):
    tipo_documento: TipoDocumentoEnum
    texto_ocr: str = Field(description="El texto crudo extraído del documento.")
    datos_extraidos: dict = Field(default_factory=dict, description="Diccionario con datos estructurados clave (ej. nombre, vigencia, número de póliza, etc.)")
    confianza_clasificacion: float = Field(description="Nivel de certeza de la clasificación (0.0 a 1.0)")
    confianza_ocr: float = Field(description="Nivel de certeza de la extracción de texto (0.0 a 1.0)")
    observaciones: Optional[str] = Field(None, description="Observaciones útiles sobre la calidad del documento o datos faltantes.")

def _hacer_ocr(images_b64: list[str], digital_text: str = "") -> tuple[OCRDocumento, str]:
    """
    Envía las imágenes o el texto a OCR y Clasificación.
    Estructurado para intentar primero con un endpoint custom de RunPod (Phi-3/Mistral)
    y si no está configurado, usa un fallback con GPT-4o-mini (litellm).
    Retorna (OCRDocumento, modelo_usado).
    """
    settings = get_settings()
    
    # Intento 1: Custom RunPod Endpoint
    if settings.RUNPOD_ENDPOINT_OCR and settings.RUNPOD_API_KEY:
        try:
            headers = {
                "Authorization": f"Bearer {settings.RUNPOD_API_KEY}",
                "Content-Type": "application/json"
            }
            payload = {
                "input": {
                    "images_base64": images_b64,
                    "text": digital_text
                }
            }
            response = requests.post(settings.RUNPOD_ENDPOINT_OCR, json=payload, headers=headers, timeout=60)
            response.raise_for_status()
            
            # Asumimos que el endpoint devuelve un JSON compatible con OCRDocumento
            data = response.json()
            if "output" in data:
                data = data["output"]
                
            doc = OCRDocumento.model_validate(data)
            return doc, "runpod-custom-vision"
        except Exception as e:
            log.warning("error_runpod_endpoint", error=str(e))
            # Si falla RunPod, seguimos al fallback de litellm
            pass
            
    # Intento 2: Fallback con GPT-4o-mini via litellm
    prompt = f"""
    Eres un clasificador experto de documentos para seguros GNP.
    Analiza este documento y extrae la información requerida en JSON estricto.
    
    Si hay texto digital proporcionado, úsalo. Si hay imágenes, analízalas.
    
    Texto digital previo (si existe):
    {digital_text}
    """
    
    messages = [
        {"role": "system", "content": "Retorna exclusivamente un JSON que cumpla el esquema requerido."}
    ]
    
    user_content = [{"type": "text", "text": prompt}]
    for img_b64 in images_b64:
        user_content.append({
            "type": "image_url",
            "image_url": {
                "url": f"data:image/jpeg;base64,{img_b64}"
            }
        })
        
    messages.append({"role": "user", "content": user_content})
    
    try:
        response = litellm.completion(
            model="gpt-4o-mini",
            messages=messages,
            response_format={"type": "json_object"},
            temperature=0.0
        )
        content = response.choices[0].message.content
        doc = OCRDocumento.model_validate_json(content)
        return doc, "gpt-4o-mini"
    except Exception as e:
        log.error("error_litellm_ocr", error=str(e))
        # Fallback de emergencia
        return OCRDocumento(
            tipo_documento=TipoDocumentoEnum.otro,
            texto_ocr=digital_text or "Error OCR",
            datos_extraidos={},
            confianza_clasificacion=0.0,
            confianza_ocr=0.0,
            observaciones="Fallo general en extracción OCR."
        ), "fallback-error"


def _procesar_pdf(file_bytes: bytes, max_pages: int = 3) -> tuple[list[str], str]:
    """
    Usa PyMuPDF para procesar un PDF.
    Intenta extraer texto digital. Si no hay suficiente texto, renderiza a imágenes base64.
    """
    images_b64 = []
    text_content = ""
    
    try:
        doc = fitz.open(stream=file_bytes, filetype="pdf")
        pages_to_process = min(len(doc), max_pages)
        
        for i in range(pages_to_process):
            page = doc[i]
            # Extraer texto digital
            text = page.get_text()
            if text:
                text_content += text + "\n"
                
            # Renderizar a imagen si el texto es muy poco (indicativo de escaneo)
            # Para estar seguros, también sacamos las imágenes si el texto es menor a 150 caracteres
            if len(text.strip()) < 150:
                pix = page.get_pixmap(matrix=fitz.Matrix(2, 2))  # Zoom 2x para mejor resolución
                img_bytes = pix.tobytes("jpeg")
                images_b64.append(base64.b64encode(img_bytes).decode("utf-8"))
                
        doc.close()
    except Exception as e:
        log.error("error_pymupdf", error=str(e))
        
    return images_b64, text_content.strip()

@celery_app.task(name="agentes.agente_3.ocr_y_clasificar", bind=True, max_retries=3)
def ocr_y_clasificar(self, tramite_id: str, correo_id: str):
    log.info("iniciando_agente_3_ocr", tramite_id=tramite_id, correo_id=correo_id)
    
    try:
        db = get_admin_db()
        
        # 1. Obtener adjuntos pendientes
        res_adjuntos = listar_adjuntos_pendientes_ocr(tramite_id=tramite_id)
        adjuntos = res_adjuntos.get("adjuntos", [])
        
        if not adjuntos:
            log.info("sin_adjuntos_pendientes_ocr", tramite_id=tramite_id)
            # Handoff directo
            celery_app.send_task("agentes.agente_4.asignacion", kwargs={"tramite_id": tramite_id}, queue="procesamiento")
            return
            
        for adjunto in adjuntos:
            adjunto_id = adjunto["id"]
            storage_path = adjunto.get("storage_path")
            mime_type = adjunto.get("mime_type", "")
            
            if not storage_path:
                continue
                
            # 2. Descargar archivo físico
            try:
                # El bucket predeterminado es "adjuntos" según Agente 1
                file_data = db.storage.from_("adjuntos").download(storage_path)
            except Exception as e:
                log.error("error_descarga_storage", storage_path=storage_path, error=str(e))
                continue
                
            images_b64 = []
            digital_text = ""
            
            # 3. Procesar según MIME Type
            if mime_type == "application/pdf":
                images_b64, digital_text = _procesar_pdf(file_data, max_pages=3)
            elif mime_type.startswith("image/"):
                images_b64.append(base64.b64encode(file_data).decode("utf-8"))
            else:
                log.info("tipo_no_soportado_ocr", mime_type=mime_type, adjunto_id=adjunto_id)
                # Registramos como documento "otro"
                crear_documento(
                    adjunto_id=adjunto_id,
                    tramite_id=tramite_id,
                    tipo_documento="otro",
                    confianza_clasificacion=1.0,
                    observaciones=f"Tipo de archivo no soportado para OCR: {mime_type}"
                )
                continue
                
            if not images_b64 and not digital_text:
                log.warning("adjunto_vacio_o_error", adjunto_id=adjunto_id)
                continue
                
            # 4. LLM / RunPod OCR
            doc_result, modelo_usado = _hacer_ocr(images_b64, digital_text)
            
            # 5. Guardar resultados
            crear_documento(
                adjunto_id=adjunto_id,
                tramite_id=tramite_id,
                tipo_documento=doc_result.tipo_documento.value,
                confianza_clasificacion=doc_result.confianza_clasificacion,
                texto_ocr=doc_result.texto_ocr,
                datos_extraidos=doc_result.datos_extraidos,
                confianza_ocr=doc_result.confianza_ocr,
                modelo_ocr=modelo_usado,
                estado_validacion="pendiente",
                observaciones=doc_result.observaciones
            )
            
            log.info("documento_ocr_creado", adjunto_id=adjunto_id, tipo_documento=doc_result.tipo_documento.value)
            
        # 6. Finalizado, encolar Agente 4
        log.info("handoff_agente_4", tramite_id=tramite_id)
        celery_app.send_task(
            "agentes.agente_4.asignacion",
            kwargs={"tramite_id": tramite_id},
            queue="procesamiento"
        )
        
    except Exception as exc:
        log.error("error_general_ocr", error=str(exc))
        self.retry(exc=exc)

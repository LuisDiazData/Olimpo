import sys
import os
import json
from enum import Enum
from typing import Optional

import structlog
from celery_app import celery_app
import litellm
from pydantic import BaseModel, Field

# Ensure mcp-server path is in sys.path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from tools.comprension import crear_tramite, vincular_correo_tramite
from tools.ingesta import actualizar_estado_correo
from core.database import get_admin_db

log = structlog.get_logger(__name__)

class TipoTramiteEnum(str, Enum):
    alta = "alta"
    endoso = "endoso"
    renovacion = "renovacion"
    cancelacion = "cancelacion"
    siniestro = "siniestro"
    reactivacion = "reactivacion"
    consulta = "consulta"
    desconocido = "desconocido"

class RamoEnum(str, Enum):
    vida = "vida"
    gmm = "gmm"
    autos = "autos"
    pyme = "pyme"
    desconocido = "desconocido"

class Agente2Extraction(BaseModel):
    tipo_tramite: TipoTramiteEnum
    ramo: RamoEnum
    numero_poliza: Optional[str] = None
    nombre_asegurado: Optional[str] = None
    rfc: Optional[str] = None
    numero_cotizacion: Optional[str] = None
    confianza: float
    resumen_corto: str
    notas_agente: str

@celery_app.task(name="agentes.agente_2.comprender_correo", bind=True, max_retries=3)
def comprender_correo(self, correo_id: str):
    log.info("iniciando_comprension", correo_id=correo_id)
    
    try:
        db = get_admin_db()
        
        # 1. Obtener correo
        correo_res = db.table("correo").select("id, thread_id, asunto, cuerpo_texto, de_email").eq("id", correo_id).maybe_single().execute()
        if not correo_res.data:
            log.error("correo_no_encontrado", correo_id=correo_id)
            return
            
        correo = correo_res.data
        thread_id = correo.get("thread_id")
        
        # 2. Revisión de hilo (¿es un correo de seguimiento?)
        tramite_id_existente = None
        if thread_id:
            # Query the database to see if any email in this thread is already linked to a tramite
            correos_thread = db.table("correo").select("id").eq("thread_id", thread_id).execute()
            if correos_thread.data:
                ids = [c["id"] for c in correos_thread.data]
                ct_res = db.table("correo_tramite").select("tramite_id").in_("correo_id", ids).execute()
                if ct_res.data:
                    tramite_id_existente = ct_res.data[0]["tramite_id"]

        # 3. LLM Call
        prompt = f"""
        Analiza el siguiente correo y extrae los datos solicitados en formato JSON estricto.
        El JSON debe coincidir exactamente con este esquema:
        {{
            "tipo_tramite": "alta|endoso|renovacion|cancelacion|siniestro|reactivacion|consulta|desconocido",
            "ramo": "vida|gmm|autos|pyme|desconocido",
            "numero_poliza": "str o null",
            "nombre_asegurado": "str o null",
            "rfc": "str o null",
            "numero_cotizacion": "str o null",
            "confianza": float de 0.0 a 1.0,
            "resumen_corto": "str max 10 palabras",
            "notas_agente": "str detallando la intención o datos inusuales"
        }}
        
        Asunto: {correo.get('asunto')}
        Remitente: {correo.get('de_email')}
        
        Cuerpo:
        {correo.get('cuerpo_texto') or 'Sin cuerpo'}
        """
        
        extraction = None
        try:
            response = litellm.completion(
                model="gpt-4o",
                messages=[
                    {"role": "system", "content": "Eres un asistente experto en seguros GNP en México. Extrae información de correos y retorna ÚNICAMENTE JSON válido."},
                    {"role": "user", "content": prompt}
                ],
                response_format={"type": "json_object"},
                temperature=0.0
            )
            content = response.choices[0].message.content
            extraction = Agente2Extraction.model_validate_json(content)
        except Exception as e:
            log.warning("error_llm_comprension", error=str(e))
            extraction = Agente2Extraction(
                tipo_tramite=TipoTramiteEnum.desconocido,
                ramo=RamoEnum.desconocido,
                confianza=0.0,
                resumen_corto=correo.get("asunto", "")[:100] if correo.get("asunto") else "Sin Asunto",
                notas_agente="Error al procesar con LLM."
            )
            
        datos_extraidos = {
            "nombre_asegurado": extraction.nombre_asegurado,
            "rfc": extraction.rfc,
            "numero_cotizacion": extraction.numero_cotizacion
        }
        
        # 4. Vinculación o Creación
        tramite_id = tramite_id_existente
        
        if tramite_id:
            # Vincular
            vincular_correo_tramite(correo_id=correo_id, tramite_id=tramite_id, es_origen=False)
            log.info("correo_vinculado_a_tramite", correo_id=correo_id, tramite_id=tramite_id)
        else:
            # Crear
            ramo_value = extraction.ramo.value if extraction.ramo.value != "desconocido" else None
            res_crear = crear_tramite(
                correo_id=correo_id,
                tipo_tramite=extraction.tipo_tramite.value,
                ramo=ramo_value,
                numero_poliza=extraction.numero_poliza,
                datos_extraidos=datos_extraidos,
                confianza_comprension=extraction.confianza,
                notas_agente=extraction.notas_agente
            )
            if "error" in res_crear:
                raise Exception(f"Error creando tramite: {res_crear['error']}")
            tramite_id = res_crear["tramite_id"]
            log.info("tramite_creado", correo_id=correo_id, tramite_id=tramite_id)
            
        # Actualizar datos extraídos en la tabla de correos (auditoría / RAG en el futuro)
        db.table("correo").update({
            "datos_agente2": extraction.model_dump(mode='json')
        }).eq("id", correo_id).execute()
        
        # 5. Verificar adjuntos para Handoff
        adjuntos_res = db.table("adjunto").select("id").eq("correo_id", correo_id).in_("estado", ["pendiente", "procesando", "procesado"]).execute()
        
        if adjuntos_res.data and len(adjuntos_res.data) > 0:
            # Ir al Agente 3 (OCR)
            log.info("handoff_agente_3", tramite_id=tramite_id, correo_id=correo_id)
            celery_app.send_task(
                "agentes.agente_3.ocr_y_clasificar",
                kwargs={"tramite_id": tramite_id, "correo_id": correo_id},
                queue="procesamiento"
            )
        else:
            # Sin adjuntos -> ir al Agente 4 (Asignación)
            log.info("handoff_agente_4", tramite_id=tramite_id, correo_id=correo_id)
            celery_app.send_task(
                "agentes.agente_4.asignacion",
                kwargs={"tramite_id": tramite_id},
                queue="procesamiento"
            )
            
    except Exception as exc:
        log.error("error_procesamiento_comprension", error=str(exc))
        try:
            actualizar_estado_correo(correo_id, "error_procesamiento", error_detalle=str(exc))
        except:
            pass
        self.retry(exc=exc)

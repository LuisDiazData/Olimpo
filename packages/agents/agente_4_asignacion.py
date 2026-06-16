import sys
import os
import re

import structlog
from celery_app import celery_app
import litellm
from pydantic import BaseModel, Field

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from tools.asignacion import (
    buscar_agente_por_cua,
    buscar_agente_fuzzy,
    obtener_asignacion_agente,
    asignar_analista_tramite,
    buscar_poliza_por_numero
)
from core.database import get_admin_db
from core.config import get_settings

log = structlog.get_logger(__name__)

class ExtraccionAgenteLLM(BaseModel):
    cua: str | None = Field(None, description="La Clave Única de Agente extraída del texto, si existe.")
    nombre: str | None = Field(None, description="El nombre del agente de seguros remitente, si existe.")

def _buscar_agente_por_email(db, email: str) -> str | None:
    """
    Busca si el email remitente pertenece a un agente o a un asistente.
    Retorna el agente_id o None.
    """
    # 1. Buscar en agente_email
    res_agente = db.table("agente_email").select("agente_id").eq("email", email).maybe_single().execute()
    if res_agente.data and res_agente.data.get("agente_id"):
        return res_agente.data["agente_id"]
        
    # 2. Buscar en asistente
    res_asistente = db.table("asistente").select("agente_id").eq("email", email).eq("activo", True).maybe_single().execute()
    if res_asistente.data and res_asistente.data.get("agente_id"):
        return res_asistente.data["agente_id"]
        
    return None

def _extraer_datos_agente_llm(cuerpo_texto: str, datos_agente2: dict) -> ExtraccionAgenteLLM:
    """
    Usa LLM para extraer CUA o nombre del agente desde el cuerpo o la firma.
    """
    prompt = f"""
    Eres un asistente experto en seguros GNP.
    Tu tarea es encontrar la Clave Única de Agente (CUA) o el Nombre del Agente de Seguros 
    en el siguiente cuerpo de correo o datos extraídos.
    El CUA suele ser un número o código corto (ej. 123456).
    El nombre suele venir en la firma del correo.
    
    Cuerpo de correo:
    {cuerpo_texto[:2000]}  # limitamos tamaño
    
    Datos previos:
    {datos_agente2}
    """
    
    messages = [
        {"role": "system", "content": "Retorna exclusivamente un objeto JSON válido con los campos cua y nombre, o null si no los encuentras."},
        {"role": "user", "content": prompt}
    ]
    
    try:
        response = litellm.completion(
            model="gpt-4o-mini",
            messages=messages,
            response_format={"type": "json_object"},
            temperature=0.0
        )
        content = response.choices[0].message.content
        return ExtraccionAgenteLLM.model_validate_json(content)
    except Exception as e:
        log.error("error_extraccion_llm_agente", error=str(e))
        return ExtraccionAgenteLLM()

@celery_app.task(name="agentes.agente_4.asignacion", bind=True, max_retries=3)
def asignacion(self, tramite_id: str):
    log.info("iniciando_agente_4_asignacion", tramite_id=tramite_id)
    db = get_admin_db()
    
    try:
        # 1. Recuperar Trámite
        res_tramite = db.table("tramite").select("ramo, numero_poliza_referencia").eq("id", tramite_id).maybe_single().execute()
        if not res_tramite.data:
            log.error("tramite_no_encontrado", tramite_id=tramite_id)
            return
            
        tramite_data = res_tramite.data
        ramo = tramite_data.get("ramo", "desconocido")
        num_poliza = tramite_data.get("numero_poliza_referencia")
        
        # 2. Recuperar primer correo (origen)
        res_correo = db.table("correo_tramite").select("correo_id").eq("tramite_id", tramite_id).order("created_at").limit(1).execute()
        
        de_email = ""
        cuerpo_texto = ""
        datos_agente2 = {}
        
        if res_correo.data:
            correo_id = res_correo.data[0]["correo_id"]
            res_c = db.table("correo").select("de_email, cuerpo_texto, datos_agente2").eq("id", correo_id).maybe_single().execute()
            if res_c.data:
                de_email = res_c.data.get("de_email", "")
                cuerpo_texto = res_c.data.get("cuerpo_texto", "")
                datos_agente2 = res_c.data.get("datos_agente2", {})
                
        # 3. Identificación del Agente (Cascada CUA)
        agente_id = None
        metodo_asignacion = "desconocido"
        confianza = 0.0
        
        # Paso 3a: Búsqueda exacta por email
        if de_email:
            # Limpiar el email de formato "Nombre <email@domain>"
            match = re.search(r'<([^>]+)>', de_email)
            email_clean = match.group(1).lower().strip() if match else de_email.lower().strip()
            
            ag_id = _buscar_agente_por_email(db, email_clean)
            if ag_id:
                agente_id = ag_id
                metodo_asignacion = "email_exacto"
                confianza = 1.0
                
        # Paso 3b: Extracción LLM (CUA o Nombre)
        if not agente_id and cuerpo_texto:
            extraccion = _extraer_datos_agente_llm(cuerpo_texto, datos_agente2)
            
            # Intentar CUA Exacto
            if extraccion.cua:
                res_cua = buscar_agente_por_cua(cua=extraccion.cua)
                if res_cua.get("encontrado") and res_cua.get("agente"):
                    agente_id = res_cua["agente"]["id"]
                    metodo_asignacion = "cua_exacto_llm"
                    confianza = 0.95
                    
            # Intentar Búsqueda Fuzzy por Nombre
            if not agente_id and extraccion.nombre:
                res_fuzzy = buscar_agente_fuzzy(nombre=extraccion.nombre, ramo=ramo)
                agentes_fuzzy = res_fuzzy.get("agentes", [])
                if agentes_fuzzy:
                    mejor_candidato = agentes_fuzzy[0]
                    # Solo asignar si la similitud supera el umbral configurable
                    # (settings.FUZZY_MATCH_NOMBRE, editable desde Superadmin).
                    if mejor_candidato.get("similitud", 0) >= get_settings().FUZZY_MATCH_NOMBRE:
                        agente_id = mejor_candidato["id"]
                        metodo_asignacion = "fuzzy_nombre"
                        confianza = mejor_candidato.get("similitud", 0.0)
                        
        # 4. Vincular Póliza (Opcional)
        if num_poliza:
            res_poliza = buscar_poliza_por_numero(numero_poliza=num_poliza, ramo=ramo)
            poliza = res_poliza.get("poliza")
            if poliza:
                # Actualizar el trámite para vincularlo a la póliza encontrada
                db.table("tramite").update({"poliza_id": poliza["id"]}).eq("id", tramite_id).execute()
                log.info("poliza_vinculada", tramite_id=tramite_id, poliza_id=poliza["id"])

        # 5. Asignar Analista
        if agente_id:
            res_asig = obtener_asignacion_agente(agente_id=agente_id, ramo=ramo)
        else:
            # Si no hay agente, intentamos buscar asignación por defecto del ramo enviando null
            try:
                # El MCP tool actual requiere agente_id string, vamos a emular la consulta si agente_id is None
                # Asignación por defecto del ramo (agente_id IS NULL)
                default = db.table("asignacion").select("analista_id, gerente_id").is_("agente_id", "null").eq("ramo", ramo).eq("activo", True).maybe_single().execute()
                res_asig = {
                    "analista_id": default.data["analista_id"] if default.data else None,
                    "tipo": "default"
                }
            except Exception as e:
                log.warning("error_asignacion_default", error=str(e))
                res_asig = {"analista_id": None}
            
        analista_id = res_asig.get("analista_id")
        
        if analista_id:
            # Asignación exitosa
            asignar_analista_tramite(
                tramite_id=tramite_id,
                analista_id=analista_id,
                agente_id=agente_id,
                confianza_asignacion=confianza,
                metodo_asignacion=metodo_asignacion
            )
            log.info("analista_asignado", tramite_id=tramite_id, analista_id=analista_id, agente_id=agente_id)
        else:
            # Trámite Huérfano -> Escalamos para asignación manual
            payload_huerfano = {
                "estado": "escalado",
                "requiere_atencion": True,
                "metodo_asignacion": "fallido_sin_analista"
            }
            if agente_id:
                payload_huerfano["agente_id"] = agente_id
                
            db.table("tramite").update(payload_huerfano).eq("id", tramite_id).execute()
            log.warning("tramite_huerfano_escalado", tramite_id=tramite_id, agente_id=agente_id)
            
        # 6. Handoff al Agente 5
        log.info("handoff_agente_5", tramite_id=tramite_id)
        celery_app.send_task("agentes.agente_5.validacion", kwargs={"tramite_id": tramite_id}, queue="procesamiento")
        
    except Exception as exc:
        log.error("error_general_asignacion", error=str(exc))
        self.retry(exc=exc)

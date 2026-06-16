import sys
import os

import structlog
from celery_app import celery_app
import litellm
from pydantic import BaseModel, Field

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from tools.redaccion import (
    obtener_firma_analista,
    crear_correo_borrador,
    listar_plantillas_correo
)
from core.database import get_admin_db

log = structlog.get_logger(__name__)

class BorradorCorreo(BaseModel):
    asunto: str = Field(description="Asunto del correo. Debe incluir Re: si es respuesta.")
    cuerpo_html: str = Field(description="Cuerpo del correo en formato HTML, con tono corporativo y la firma del analista al final.")
    cuerpo_texto: str = Field(description="Versión en texto plano del correo.")

@celery_app.task(name="agentes.agente_6.redaccion", bind=True, max_retries=3)
def redaccion(self, tramite_id: str, documentos_faltantes: list[str] = None, razonamiento: str = "", es_proactivo: bool = False):
    log.info("iniciando_agente_6_redaccion", tramite_id=tramite_id)
    db = get_admin_db()
    
    if documentos_faltantes is None:
        documentos_faltantes = []
        
    try:
        # 1. Recuperar Trámite
        res_tramite = db.table("tramite").select("estado, ramo, tipo_tramite, analista_id, poliza_id").eq("id", tramite_id).maybe_single().execute()
        if not res_tramite.data:
            log.error("tramite_no_encontrado_redaccion", tramite_id=tramite_id)
            return
            
        tramite_data = res_tramite.data
        estado_tramite = tramite_data.get("estado")
        analista_id = tramite_data.get("analista_id")
        ramo = tramite_data.get("ramo", "")
        tipo_tramite = tramite_data.get("tipo_tramite", "")
        
        # 2. Recuperar el Correo de Origen (para responder)
        res_correo = db.table("correo_tramite").select("correo_id, es_origen").eq("tramite_id", tramite_id).eq("es_origen", True).maybe_single().execute()
        
        correo_origen_id = None
        de_email = ""
        remitente_nombre = ""
        gmail_thread_id = None
        asunto_original = ""
        
        if res_correo.data:
            correo_origen_id = res_correo.data["correo_id"]
            res_c = db.table("correo").select("de_email, remitente_nombre, gmail_thread_id, asunto").eq("id", correo_origen_id).maybe_single().execute()
            if res_c.data:
                de_email = res_c.data.get("de_email", "")
                remitente_nombre = res_c.data.get("remitente_nombre", "")
                gmail_thread_id = res_c.data.get("gmail_thread_id")
                asunto_original = res_c.data.get("asunto", "Trámite")
                
        # Validar destino (si no hay correo origen, no podemos responder)
        if not de_email:
            if es_proactivo:
                res_ag = db.table("tramite").select("agente:agente_id(nombre)").eq("id", tramite_id).maybe_single().execute()
                if res_ag.data and res_ag.data.get("agente"):
                    remitente_nombre = res_ag.data["agente"].get("nombre", "")
                    
                res_ag_id = db.table("tramite").select("agente_id").eq("id", tramite_id).maybe_single().execute()
                if res_ag_id.data and res_ag_id.data.get("agente_id"):
                    res_correo_ag = db.table("agente_email").select("email").eq("agente_id", res_ag_id.data["agente_id"]).limit(1).execute()
                    if res_correo_ag.data:
                        de_email = res_correo_ag.data[0]["email"]
                        
            if not de_email:
                log.warning("tramite_sin_correo_origen_ni_agente", tramite_id=tramite_id)
                # Solo guardamos un aviso interno o finalizamos.
                return
            
        # 3. Obtener Firma del Analista
        firma_html = ""
        if analista_id:
            res_firma = obtener_firma_analista(analista_id=analista_id)
            firma_html = res_firma.get("firma_html", "")
            if not firma_html:
                # Fallback genérico si no hay firma configurada
                nombre_analista = res_firma.get("nombre", "Equipo Olimpo")
                firma_html = f"<br><br>Atentamente,<br><b>{nombre_analista}</b><br>Asesor de Soporte - Promotoría GNP"
        else:
            firma_html = "<br><br>Atentamente,<br><b>Equipo Olimpo</b><br>Asesor de Soporte - Promotoría GNP"
            
        # 4. Obtener Plantilla
        res_plantilla = listar_plantillas_correo(tipo_tramite=tipo_tramite, ramo=ramo)
        plantillas = res_plantilla.get("plantillas", [])
        plantilla_texto = ""
        if plantillas:
            # Tomamos la primera plantilla activa
            p = plantillas[0]
            plantilla_texto = f"Utiliza esta plantilla estructural (Asunto: {p.get('asunto_template')}): \n {p.get('cuerpo_html_template')}"
            
        # 5. Redacción con Claude
        prompt_sistema = """
        Eres un Asesor de Soporte especializado en Seguros GNP (Agente 6 del CRM Olimpo).
        Tu trabajo es redactar un borrador de correo electrónico cordial, profesional y corporativo 
        dirigido a un Agente de Seguros.
        Deberás explicar la situación de su trámite basándote en el dictamen del sistema.
        Si es un correo proactivo (como aviso de renovación), actúa con iniciativa y recuérdale la importancia de iniciar el trámite.
        Asegúrate de incluir la firma HTML al final del correo exactamente como se te proporcione.
        Responde exclusivamente con el JSON en el esquema especificado.
        """
        
        estado_desc = "Renovación Proactiva" if es_proactivo else ("Faltan documentos" if documentos_faltantes else "Todo en orden")
        
        prompt_usuario = f"""
        # DATOS DEL DESTINATARIO
        Nombre: {remitente_nombre or 'Agente de Seguros'}
        Asunto original: {asunto_original}
        
        # DATOS DEL TRÁMITE
        Estado Dictaminado: {estado_tramite}
        Ramo: {ramo}
        Tipo de Trámite: {tipo_tramite}
        
        # DICTAMEN DE VALIDACIÓN
        Situación: {estado_desc}
        Faltantes: {documentos_faltantes}
        Explicación/Razonamiento Interno: {razonamiento}
        
        # PLANTILLA SUGERIDA (Opcional)
        {plantilla_texto}
        
        # FIRMA DEL ANALISTA (Insertar al final del HTML)
        {firma_html}
        
        Redacta el asunto y el cuerpo del correo. Si falta documentación, solicítala amablemente explicando 
        la razón (basada en el razonamiento interno). Si el estado es 'completo' o similar y no faltan documentos, 
        agradece al agente e indícale que el trámite está siendo procesado con GNP exitosamente.
        """
        
        messages = [
            {"role": "system", "content": prompt_sistema},
            {"role": "user", "content": prompt_usuario}
        ]
        
        try:
            response = litellm.completion(
                model="claude-3-5-sonnet-20241022",
                messages=messages,
                response_format={"type": "json_object"},
                temperature=0.3
            )
            
            import json
            content = response.choices[0].message.content
            
            # Limpieza básica por si el LLM envuelve el JSON
            import re
            json_match = re.search(r'```json\n(.*?)\n```', content, re.DOTALL)
            if json_match:
                content = json_match.group(1)
                
            dict_res = json.loads(content)
            borrador = BorradorCorreo.model_validate(dict_res)
            
            # 6. Guardar Borrador
            asunto_final = borrador.asunto
            if not es_proactivo and not asunto_final.lower().startswith("re:"):
                asunto_final = f"Re: {asunto_final}"
                
            crear_correo_borrador(
                tramite_id=tramite_id,
                analista_id=analista_id or "00000000-0000-0000-0000-000000000000", # Dummy si no hay analista
                destinatario_email=de_email,
                destinatario_nombre=remitente_nombre,
                asunto=asunto_final,
                cuerpo_html=borrador.cuerpo_html,
                cuerpo_texto=borrador.cuerpo_texto,
                correo_origen_id=correo_origen_id,
                gmail_thread_id=gmail_thread_id
            )
            
            log.info("borrador_creado", tramite_id=tramite_id, analista_id=analista_id)
            
            # Aquí concluye el pipeline automático de Inteligencia Artificial de Olimpo.
            
        except Exception as llm_e:
            log.error("error_llm_redaccion", error=str(llm_e))
            raise llm_e
            
    except Exception as exc:
        log.error("error_general_redaccion", error=str(exc))
        self.retry(exc=exc)

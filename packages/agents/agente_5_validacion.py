import sys
import os

import structlog
from celery_app import celery_app
import litellm
from pydantic import BaseModel, Field

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from tools.validacion import (
    buscar_conocimiento_gnp,
    buscar_historial_poliza,
    buscar_rechazos_similares,
    cambiar_estado_tramite
)
from tools.ocr_clasificacion import (
    listar_documentos_tramite,
    actualizar_estado_validacion_documento
)
from core.database import get_admin_db

log = structlog.get_logger(__name__)

class DocumentoEvaluado(BaseModel):
    documento_id: str = Field(description="UUID del documento evaluado.")
    estado: str = Field(description="'valido' o 'invalido' o 'requiere_revision'")
    observaciones: str = Field(description="Razón de la validación o rechazo.")

class ValidacionRAG(BaseModel):
    es_valido: bool = Field(description="Booleano general: true si el trámite tiene todo lo necesario.")
    documentos_evaluados: list[DocumentoEvaluado] = Field(description="Evaluación documento por documento.")
    documentos_faltantes: list[str] = Field(description="Lista de documentos faltantes para solicitar al agente.")
    estado_recomendado: str = Field(description="Debe ser 'turnado_a_gnp' (todo OK, listo para enviar a GNP), 'pendiente_documentos_agente' (faltan documentos) o 'en_revision' (hay dudas, requiere análisis del analista).")
    razonamiento: str = Field(description="Explicación detallada para el analista.")

def _obtener_embedding(texto: str) -> list[float]:
    """Genera un embedding usando text-embedding-3-small."""
    try:
        response = litellm.embedding(
            model="text-embedding-3-small",
            input=[texto[:8000]] # Limite de seguridad
        )
        return response.data[0]["embedding"]
    except Exception as e:
        log.error("error_generar_embedding", error=str(e))
        return []

@celery_app.task(name="agentes.agente_5.validacion", bind=True, max_retries=3)
def validacion(self, tramite_id: str):
    log.info("iniciando_agente_5_validacion", tramite_id=tramite_id)
    db = get_admin_db()
    
    try:
        # 1. Cambiar estado a en_revision (el agente está revisando)
        cambiar_estado_tramite(
            tramite_id=tramite_id,
            estado_nuevo="en_revision",
            descripcion="El Agente 5 ha comenzado la revisión y validación RAG.",
            agente_ia_nombre="agente_5"
        )
        
        # 2. Recuperar Trámite
        res_tramite = db.table("tramite").select("ramo, tipo_tramite, poliza_id, numero_poliza_referencia").eq("id", tramite_id).maybe_single().execute()
        if not res_tramite.data:
            log.error("tramite_no_encontrado_validacion", tramite_id=tramite_id)
            return
            
        tramite_data = res_tramite.data
        ramo = tramite_data.get("ramo")
        tipo_tramite = tramite_data.get("tipo_tramite")
        poliza_id = tramite_data.get("poliza_id")
        agente_cua = None # Podríamos sacar el CUA haciendo JOIN a la tabla agente, pero simplificaremos
        
        # Obtener Agente CUA para el historial
        res_agente_tramite = db.table("tramite").select("agente:agente_id(cua)").eq("id", tramite_id).maybe_single().execute()
        if res_agente_tramite.data and res_agente_tramite.data.get("agente"):
            agente_cua = res_agente_tramite.data["agente"].get("cua")
            
        # 3. Recuperar Documentos
        res_docs = listar_documentos_tramite(tramite_id=tramite_id)
        documentos = res_docs.get("documentos", [])
        
        # 4. Generar embedding de búsqueda (Contexto)
        tipos_docs_recibidos = [d.get("tipo_documento") for d in documentos]
        texto_busqueda = f"Trámite {tipo_tramite} para el ramo {ramo}. Documentos recibidos: {', '.join(str(x) for x in tipos_docs_recibidos)}"
        embedding = _obtener_embedding(texto_busqueda)
        
        contexto_gnp = []
        contexto_rechazos = []
        contexto_historial = []
        
        if embedding:
            # 5. Búsquedas RAG secuenciales
            # 5a. Conocimiento GNP
            res_gnp = buscar_conocimiento_gnp(
                embedding=embedding,
                ramo=ramo,
                tipo_tramite=tipo_tramite,
                limite=5
            )
            contexto_gnp = res_gnp.get("chunks", [])
            
            # 5b. Aprendizajes de Rechazos
            res_rechazos = buscar_rechazos_similares(
                embedding=embedding,
                ramo=ramo,
                tipo_tramite=tipo_tramite,
                limite=3
            )
            contexto_rechazos = res_rechazos.get("aprendizajes", [])
            
            # 5c. Historial de la Póliza (si hay poliza_id o CUA)
            if poliza_id or agente_cua:
                res_historial = buscar_historial_poliza(
                    embedding=embedding,
                    poliza_id=poliza_id,
                    agente_cua=agente_cua,
                    ramo=ramo,
                    limite=3
                )
                contexto_historial = res_historial.get("chunks", [])
                
        # 6. Evaluación con Claude Sonnet
        prompt_sistema = """
        Eres un estricto Validador de Seguros GNP (Agente 5).
        Tu tarea es analizar los documentos de un trámite usando el contexto normativo recuperado vía RAG.
        Dictamina si el trámite está completo para enviarse a GNP, si le faltan documentos, o si tiene errores críticos.
        Debes responder estrictamente en formato JSON válido según el esquema solicitado.
        """
        
        prompt_usuario = f"""
        # DATOS DEL TRÁMITE
        Ramo: {ramo}
        Tipo: {tipo_tramite}
        
        # DOCUMENTOS RECIBIDOS
        {documentos}
        
        # CONTEXTO NORMATIVO GNP (RAG)
        {contexto_gnp}
        
        # APRENDIZAJES DE RECHAZOS ANTERIORES
        {contexto_rechazos}
        
        # HISTORIAL DE PÓLIZA
        {contexto_historial}
        
        Analiza cada documento, cruza con los requisitos GNP y rechazos previos.
        Indica si el trámite completo es válido.
        """
        
        messages = [
            {"role": "system", "content": prompt_sistema},
            {"role": "user", "content": prompt_usuario}
        ]
        
        try:
            # LiteLLM ruteará automáticamente al modelo de Anthropic si configuramos bien.
            # Usaremos el modelo especificado en CLAUDE.md: "Claude Sonnet"
            response = litellm.completion(
                model="claude-3-5-sonnet-20241022",
                messages=messages,
                temperature=0.0
            )
            
            # Extraer JSON de la respuesta de Claude (a veces incluye texto antes del JSON, hay que manejarlo)
            import json
            content = response.choices[0].message.content
            
            # Intento crudo de parsear (por si devuelve solo JSON)
            try:
                # Buscar bloque json si está envuelto en ```json ... ```
                import re
                json_match = re.search(r'```json\n(.*?)\n```', content, re.DOTALL)
                if json_match:
                    content_json = json_match.group(1)
                else:
                    content_json = content
                    
                dict_res = json.loads(content_json)
                validacion_res = ValidacionRAG.model_validate(dict_res)
            except Exception as e_json:
                log.error("error_parseo_json_claude", error=str(e_json), content=content)
                raise ValueError("Respuesta de Claude no es un JSON válido")
                
            # 7. Actualización a Nivel Documento
            for doc in validacion_res.documentos_evaluados:
                actualizar_estado_validacion_documento(
                    documento_id=doc.documento_id,
                    estado_validacion=doc.estado,
                    observaciones=doc.observaciones
                )
                
            # 8. Transición de Estado Global.
            # Solo transicionamos a un estado distinto; si el dictamen es 'en_revision'
            # (dudas) el trámite ya está en revisión y lo dejamos para el analista.
            if validacion_res.estado_recomendado in ("turnado_a_gnp", "pendiente_documentos_agente"):
                cambiar_estado_tramite(
                    tramite_id=tramite_id,
                    estado_nuevo=validacion_res.estado_recomendado,
                    descripcion=validacion_res.razonamiento,
                    agente_ia_nombre="agente_5",
                    datos={"es_valido": validacion_res.es_valido, "documentos_faltantes": validacion_res.documentos_faltantes}
                )
            
            log.info("validacion_completada", tramite_id=tramite_id, estado_recomendado=validacion_res.estado_recomendado)
            
            # 9. Handoff al Agente 6 (Redacción)
            # Solo encolamos redacción si faltan documentos/hay errores, 
            # o si el sistema requiere responder. Según pipeline "Agente 6 - Draft professional emails".
            # Le pasamos los faltantes para que sepa qué pedir.
            celery_app.send_task(
                "agentes.agente_6.redaccion",
                kwargs={
                    "tramite_id": tramite_id, 
                    "documentos_faltantes": validacion_res.documentos_faltantes,
                    "razonamiento": validacion_res.razonamiento
                },
                queue="procesamiento"
            )
            
        except Exception as llm_e:
            # Dejamos que el manejador externo decida el reintento. El trámite ya
            # quedó en 'en_revision' (paso 1), que es la cola de revisión manual.
            log.error("error_llm_validacion", error=str(llm_e))
            raise llm_e

    except Exception as exc:
        log.error("error_general_validacion", error=str(exc))
        try:
            self.retry(exc=exc)
        except self.MaxRetriesExceededError:
            # Agotados los reintentos: el trámite permanece en 'en_revision'
            # para atención manual del analista.
            log.error("validacion_agotada_reintentos_revision_manual", tramite_id=tramite_id)

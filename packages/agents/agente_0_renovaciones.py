import sys
import os
from datetime import datetime, timedelta

import structlog
from celery_app import celery_app

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from core.database import get_admin_db

log = structlog.get_logger(__name__)

@celery_app.task(name="agentes.agente_0_renovaciones.procesar", bind=True)
def procesar(self):
    log.info("iniciando_agente_0_renovaciones")
    db = get_admin_db()
    
    try:
        # 1. Calcular la fecha objetivo (Hoy + 45 días)
        fecha_objetivo = (datetime.now() + timedelta(days=45)).date().isoformat()
        
        # 2. Buscar pólizas activas que vencen exactamente en 45 días
        res_polizas = db.table("poliza").select("id, agente_id, analista_id, ramo, numero_poliza").eq("estado", "activa").eq("fecha_fin", fecha_objetivo).execute()
        
        polizas_a_renovar = res_polizas.data or []
        log.info("polizas_para_renovar_encontradas", total=len(polizas_a_renovar), fecha_objetivo=fecha_objetivo)
        
        for poliza in polizas_a_renovar:
            poliza_id = poliza["id"]
            agente_id = poliza["agente_id"]
            analista_id = poliza.get("analista_id")
            ramo = poliza["ramo"]
            numero_poliza = poliza["numero_poliza"]
            
            # 3. Crear Trámite en el estado inicial válido ('recibido').
            # La máquina de estados (migración 30) solo permite recibido → en_revision,
            # así que un analista lo tomará desde su cola; no forzamos estados intermedios.
            payload_tramite = {
                "estado": "recibido",
                "tipo_tramite": "renovacion",
                "ramo": ramo,
                "agente_id": agente_id,
                "analista_id": analista_id,
                "poliza_id": poliza_id,
                "requiere_atencion": False
            }

            res_tramite = db.table("tramite").insert(payload_tramite).execute()
            if not res_tramite.data:
                log.error("error_crear_tramite_renovacion", poliza_id=poliza_id)
                continue

            tramite_id = res_tramite.data[0]["id"]

            # 4. Registrar Evento de creación proactiva (no es un cambio de estado).
            payload_evento = {
                "tramite_id": tramite_id,
                "tipo_evento": "creacion",
                "descripcion": f"Trámite de renovación creado proactivamente por el sistema (vencimiento en 45 días). Póliza: {numero_poliza}",
                "agente_ia_nombre": "agente_0_renovaciones"
            }
            db.table("tramite_evento").insert(payload_evento).execute()

            log.info("tramite_renovacion_creado", tramite_id=tramite_id, poliza_id=poliza_id)
            
            # 5. Encolar Agente 6 (Redacción)
            # Como es proactivo, le mandamos un razonamiento especial indicándole que redacte un aviso
            razonamiento_proactivo = f"La póliza {numero_poliza} vencerá el {fecha_objetivo}. Redacta un correo avisándole al agente e invitándole a iniciar el proceso de renovación de inmediato."
            
            celery_app.send_task(
                "agentes.agente_6.redaccion",
                kwargs={
                    "tramite_id": tramite_id, 
                    "documentos_faltantes": ["Documentos de renovación actualizados"],
                    "razonamiento": razonamiento_proactivo,
                    "es_proactivo": True
                },
                queue="procesamiento"
            )
            
    except Exception as exc:
        log.error("error_general_renovaciones", error=str(exc))
        raise exc

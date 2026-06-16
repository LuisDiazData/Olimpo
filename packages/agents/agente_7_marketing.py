import sys
import os

import structlog
from celery_app import celery_app

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from core.database import get_admin_db

log = structlog.get_logger(__name__)

@celery_app.task(name="agentes.agente_7_marketing.ejecutar_campana", bind=True)
def ejecutar_campana(self, campana_id: str):
    log.info("iniciando_agente_7_marketing", campana_id=campana_id)
    db = get_admin_db()
    
    try:
        # 1. Obtener Campaña
        res_campana = db.table("campana").select("*").eq("id", campana_id).maybe_single().execute()
        if not res_campana.data:
            log.error("campana_no_encontrada", campana_id=campana_id)
            return
            
        campana = res_campana.data
        ramo_objetivo = campana.get("ramo_objetivo")
        
        # 2. Buscar Destinatarios (Agentes activos)
        query_agentes = db.table("agente").select("id, nombre, emails:agente_email(email)").eq("activo", True)
        # En una arquitectura real se filtraría por ramo_objetivo si el agente lo tiene definido, 
        # asumiendo que el agente no tiene campo ramo directo, buscaremos a todos por ahora o filtraremos si es necesario.
        res_agentes = query_agentes.execute()
        agentes = res_agentes.data or []
        
        if not agentes:
            log.warning("no_hay_agentes_objetivo", campana_id=campana_id)
            db.table("campana").update({"estado": "completada"}).eq("id", campana_id).execute()
            return
            
        # 3. Preparar e Insertar envíos
        API_URL = os.environ.get("API_URL", "http://localhost:8000")  # Para el pixel
        FROM_EMAIL = os.environ.get("MARKETING_FROM_EMAIL", "marketing@olimpo.mx")

        for ag in agentes:
            emails = ag.get("emails", [])
            if not emails:
                continue
            email_principal = emails[0].get("email")

            # Crear destinatario en DB
            res_dest = db.table("campana_destinatario").insert({
                "campana_id": campana_id,
                "agente_id": ag["id"],
                "email_destino": email_principal,
                "estado_envio": "pendiente"
            }).execute()

            destinatario_id = res_dest.data[0]["id"]

            # Personalizar HTML
            html_personalizado = campana["cuerpo_html"].replace("{nombre}", ag["nombre"])
            pixel = f'<img src="{API_URL}/api/v1/campanas/track/{destinatario_id}.png" width="1" height="1" style="display:none;" />'
            html_con_pixel = html_personalizado + pixel

            # NOTA: envío SIMULADO. La integración real con Gmail API/SMTP está
            # pendiente; aquí solo registramos el correo saliente con las columnas
            # reales del esquema (de_email NOT NULL, para_emails[]).
            db.table("correo").insert({
                "tipo": "saliente",
                "estado": "enviado",
                "de_email": FROM_EMAIL,
                "para_emails": [email_principal],
                "asunto": campana["asunto"],
                "cuerpo_html": html_con_pixel
            }).execute()

            db.table("campana_destinatario").update({"estado_envio": "enviado"}).eq("id", destinatario_id).execute()

        # 4. Finalizar campaña
        db.table("campana").update({"estado": "completada"}).eq("id", campana_id).execute()
        log.warning("campana_completada_envio_simulado", campana_id=campana_id,
                    detalle="Envío simulado: falta integrar Gmail API/SMTP real.")
            
    except Exception as exc:
        log.error("error_general_marketing", error=str(exc))
        db.table("campana").update({"estado": "borrador"}).eq("id", campana_id).execute()
        raise exc

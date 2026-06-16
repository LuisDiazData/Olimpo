import sys
import os
import json
import base64
import io
import pyzipper
from email.utils import parsedate_to_datetime
import structlog
from celery_app import celery_app
from google.oauth2 import service_account
from googleapiclient.discovery import build
import litellm

# Asegurar path de mcp-server para importar herramientas
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../mcp-server")))
from tools.ingesta import registrar_correo, registrar_adjunto, actualizar_estado_correo, actualizar_estado_adjunto, limpiar_password_adjunto

from core.config import get_settings
from core.database import get_admin_db

log = structlog.get_logger(__name__)

SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]

def _get_gmail_service(email_address: str):
    settings = get_settings()
    if not settings.GOOGLE_SERVICE_ACCOUNT_JSON:
        raise ValueError("GOOGLE_SERVICE_ACCOUNT_JSON no configurado")
        
    creds_info = json.loads(settings.GOOGLE_SERVICE_ACCOUNT_JSON)
    creds = service_account.Credentials.from_service_account_info(
        creds_info, scopes=SCOPES
    )
    # Domain-Wide Delegation (impersonation)
    delegated_creds = creds.with_subject(email_address)
    return build('gmail', 'v1', credentials=delegated_creds, cache_discovery=False)

def _extraer_password_zip(texto_correo: str) -> list[str]:
    """Usa un LLM ligero para extraer posibles contraseñas del texto del correo."""
    if not texto_correo or len(texto_correo.strip()) < 5:
        return []
    
    prompt = f"""Extrae posibles contraseñas o NIPs del siguiente correo que podrían usarse para abrir un archivo ZIP adjunto. 
Devuelve ÚNICAMENTE las contraseñas encontradas, una por línea. Si no hay ninguna, devuelve 'NINGUNA'.

Correo:
{texto_correo}
"""
    try:
        response = litellm.completion(
            model="gpt-4o-mini",
            messages=[{"role": "user", "content": prompt}],
            temperature=0.0
        )
        content = response.choices[0].message.content.strip()
        if "NINGUNA" in content.upper() or not content:
            return []
        
        return [line.strip() for line in content.split('\n') if line.strip()]
    except Exception as e:
        log.warning("error_extraccion_password", error=str(e))
        return []

@celery_app.task(name="agentes.agente_1.procesar_notificacion_gmail", bind=True, max_retries=3)
def procesar_notificacion_gmail(self, email_address: str, history_id: int, subscription: str, pubsub_message_id: str):
    log.info("iniciando_ingesta_gmail", email_address=email_address, history_id=history_id)
    
    try:
        service = _get_gmail_service(email_address)
        db = get_admin_db()
        
        # Recuperar estado anterior para pedir sólo el delta
        sync_state = db.table("gmail_sync_state").select("*").eq("cuenta_workspace", email_address).maybe_single().execute()
        start_history_id = None
        if sync_state.data and sync_state.data.get("ultimo_history_id"):
            start_history_id = sync_state.data["ultimo_history_id"]
            
        messages_to_process = []
        
        if not start_history_id:
            res = service.users().messages().list(userId='me', maxResults=5).execute()
            messages_to_process = res.get('messages', [])
        else:
            try:
                res = service.users().history().list(userId='me', startHistoryId=start_history_id).execute()
                for history_record in res.get('history', []):
                    for msg_added in history_record.get('messagesAdded', []):
                        messages_to_process.append(msg_added['message'])
            except Exception as e:
                log.warning("history_id_invalido_fallback", error=str(e))
                res = service.users().messages().list(userId='me', maxResults=5).execute()
                messages_to_process = res.get('messages', [])
                
        for msg_ref in messages_to_process:
            msg_id = msg_ref['id']
            full_msg = service.users().messages().get(userId='me', id=msg_id, format='full').execute()
            
            payload = full_msg.get('payload', {})
            headers = payload.get('headers', [])
            
            subject = next((h['value'] for h in headers if h['name'].lower() == 'subject'), 'Sin Asunto')
            sender = next((h['value'] for h in headers if h['name'].lower() == 'from'), 'Desconocido')
            date_str = next((h['value'] for h in headers if h['name'].lower() == 'date'), '')
            
            try:
                dt = parsedate_to_datetime(date_str)
                fecha_recibido = dt.isoformat()
            except Exception:
                fecha_recibido = "2025-01-01T00:00:00Z"
                
            thread_id = full_msg.get('threadId', msg_id)
            snippet = full_msg.get('snippet', '')
            
            # 1. Registrar correo usando la herramienta del MCP
            res_correo = registrar_correo(
                gmail_message_id=msg_id,
                gmail_thread_id=thread_id,
                remitente_email=sender,
                remitente_nombre=sender,
                asunto=subject,
                fecha_recibido=fecha_recibido,
                cuerpo_texto=snippet,
            )
            
            if res_correo.get("ya_existia"):
                log.info("correo_ya_existia", gmail_message_id=msg_id)
                continue
                
            correo_id = res_correo.get("correo_id")
            if not correo_id:
                log.error("error_registro_correo", response=res_correo)
                continue
                
            # Extraer posibles contraseñas del snippet / texto del correo con LLM ligero
            posibles_passwords = _extraer_password_zip(snippet)
            
            # Encontrar partes con adjuntos
            parts = payload.get('parts', [])
            if not parts and payload.get('filename'):
                parts = [payload]
                
            fallo_zip = False
                
            for part in parts:
                if part.get('filename'):
                    mime_type = part.get('mimeType', 'application/octet-stream')
                    size = part.get('body', {}).get('size', 0)
                    att_id = part.get('body', {}).get('attachmentId')
                    nombre_archivo = part.get('filename')
                    es_zip = (mime_type in ['application/zip', 'application/x-zip-compressed'])
                    
                    # 2. Registrar el adjunto inicial
                    res_adjunto = registrar_adjunto(
                        correo_id=correo_id,
                        nombre_archivo=nombre_archivo,
                        mime_type=mime_type,
                        tamano_bytes=size,
                        gmail_attachment_id=att_id,
                        es_zip=es_zip,
                        password=posibles_passwords[0] if posibles_passwords else None
                    )
                    adjunto_id = res_adjunto.get("adjunto_id")
                    
                    if not adjunto_id or not att_id:
                        continue
                        
                    # 3. Descargar el binario del adjunto desde Gmail
                    try:
                        att_obj = service.users().messages().attachments().get(
                            userId='me', messageId=msg_id, id=att_id
                        ).execute()
                        file_data = base64.urlsafe_b64decode(att_obj['data'])
                    except Exception as e:
                        log.error("error_descarga_adjunto", msg_id=msg_id, att_id=att_id, error=str(e))
                        actualizar_estado_adjunto(adjunto_id, "error", error_detalle="Error descargando de Gmail")
                        continue
                        
                    # 4. Subir a Supabase Storage
                    storage_path = f"{correo_id}/{adjunto_id}/{nombre_archivo}"
                    try:
                        db.storage.from_("adjuntos").upload(storage_path, file_data)
                        actualizar_estado_adjunto(adjunto_id, "procesado", storage_path=storage_path)
                    except Exception as e:
                        log.error("error_subida_storage", path=storage_path, error=str(e))
                        actualizar_estado_adjunto(adjunto_id, "error", error_detalle="Error subiendo a Storage")
                        continue
                        
                    # 5. Manejo de ZIPs y extracción en memoria
                    if es_zip:
                        try:
                            with pyzipper.AESZipFile(io.BytesIO(file_data), 'r') as zf:
                                is_encrypted = any(info.flag_bits & 0x1 for info in zf.infolist())
                                password_valido = None
                                
                                if is_encrypted:
                                    if not posibles_passwords:
                                        raise RuntimeError("ZIP cifrado pero no se encontraron contraseñas en el correo.")
                                    
                                    for pwd in posibles_passwords:
                                        zf.pwd = pwd.encode('utf-8')
                                        try:
                                            # Intentar leer un archivo para probar la contraseña
                                            if len(zf.infolist()) > 0:
                                                zf.read(zf.infolist()[0])
                                            password_valido = pwd
                                            break
                                        except (RuntimeError, pyzipper.BadZipFile):
                                            continue
                                            
                                    if not password_valido:
                                        raise RuntimeError("Ninguna de las contraseñas extraídas funcionó para el ZIP.")
                                
                                # Extraer archivos hijos
                                for info in zf.infolist():
                                    if info.is_dir():
                                        continue
                                        
                                    hijo_data = zf.read(info)
                                    hijo_nombre = info.filename.split('/')[-1]
                                    
                                    # Registrar adjunto hijo
                                    res_hijo = registrar_adjunto(
                                        correo_id=correo_id,
                                        nombre_archivo=hijo_nombre,
                                        mime_type="application/octet-stream", # Se puede inferir mejor
                                        tamano_bytes=info.file_size,
                                        adjunto_padre_id=adjunto_id
                                    )
                                    hijo_id = res_hijo.get("adjunto_id")
                                    if hijo_id:
                                        hijo_path = f"{correo_id}/{hijo_id}/{hijo_nombre}"
                                        db.storage.from_("adjuntos").upload(hijo_path, hijo_data)
                                        actualizar_estado_adjunto(hijo_id, "procesado", storage_path=hijo_path)

                        except RuntimeError as re:
                            log.warning("error_zip_requiere_atencion", error=str(re))
                            actualizar_estado_adjunto(adjunto_id, "error", error_detalle=str(re))
                            fallo_zip = True
                        except Exception as e:
                            log.error("error_descompresion_zip", error=str(e))
                            actualizar_estado_adjunto(adjunto_id, "error", error_detalle="Archivo ZIP corrupto o formato no soportado")
                            fallo_zip = True
                        finally:
                            # Regla de seguridad: la contraseña del ZIP es temporal y
                            # debe borrarse SIEMPRE, incluso si la descompresión falla.
                            limpiar_password_adjunto(adjunto_id)
                            
            # Marcar el correo y encolar el Agente 2
            if fallo_zip:
                actualizar_estado_correo(correo_id, "error_procesamiento", error_detalle="ZIP protegido, requiere atención manual")
            else:
                actualizar_estado_correo(correo_id, "procesado")
                # Handoff al Agente 2
                celery_app.send_task(
                    "agentes.agente_2.comprender_correo",
                    kwargs={"correo_id": correo_id},
                    queue="procesamiento"
                )
            
        # Actualizar el gmail_sync_state
        if history_id:
            db.table("gmail_sync_state").upsert({
                "cuenta_workspace": email_address,
                "ultimo_history_id": history_id
            }).execute()
            
        log.info("ingesta_gmail_completada", mensajes_procesados=len(messages_to_process))
        
    except Exception as exc:
        log.error("error_procesamiento_gmail", error=str(exc))
        self.retry(exc=exc)

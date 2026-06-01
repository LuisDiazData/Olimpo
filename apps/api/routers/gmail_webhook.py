"""
Router: Gmail Push Notifications (Pub/Sub webhook)

Este endpoint es el punto de entrada principal de todos los correos al CRM.
Google Workspace llama aquí cada vez que llega un correo nuevo a cualquier
cuenta monitoreada vía Domain-Wide Delegation.

Flujo:
  1. Gmail detecta correo nuevo en cuenta del analista
  2. Gmail publica notificación en el topic de Pub/Sub configurado
  3. Pub/Sub llama POST /webhook/gmail con la notificación
  4. Este endpoint valida la notificación y encola el mensaje en Celery
  5. El worker de Celery (Agente 1) descarga y procesa el correo completo

Seguridad:
  - El token de verificación en la URL previene llamadas externas no autorizadas.
  - El header X-Goog-Resource-State identifica el tipo de notificación.
  - El procesamiento real ocurre en Celery, no en el request (respuesta <5s).
"""

import base64
import hmac
import json
from typing import Any

import structlog
from fastapi import APIRouter, BackgroundTasks, HTTPException, Query, status
from pydantic import BaseModel

from core.config import get_settings
from core.database import get_admin_db

log = structlog.get_logger(__name__)
router = APIRouter(tags=["gmail-webhook"])


# ===========================================================================
# MODELOS
# ===========================================================================


class PubSubMessage(BaseModel):
    """Mensaje de Google Cloud Pub/Sub."""

    data: str  # Base64-encoded JSON con historyId y emailAddress
    messageId: str
    publishTime: str
    attributes: dict[str, str] = {}


class PubSubNotification(BaseModel):
    """Payload completo de una notificación Pub/Sub."""

    message: PubSubMessage
    subscription: str


class GmailHistoryNotification(BaseModel):
    """Datos decodificados del campo data del mensaje Pub/Sub."""

    historyId: int
    emailAddress: str  # La cuenta de Workspace que recibió el correo


# ===========================================================================
# HELPERS
# ===========================================================================


def _decodificar_pubsub_data(data_b64: str) -> dict[str, Any]:
    """Decodifica el campo data de Pub/Sub (base64 → JSON)."""
    try:
        decoded = base64.b64decode(data_b64 + "==").decode("utf-8")
        return json.loads(decoded)
    except Exception as exc:
        log.warning("pubsub_data_invalido", error=str(exc))
        return {}


def _verificar_token_webhook(token: str | None) -> bool:
    """Verifica que el token de la URL coincide con el configurado en settings."""
    s = get_settings()
    expected = getattr(s, "GMAIL_WEBHOOK_TOKEN", None)
    if not expected:
        log.error("gmail_webhook_token_no_configurado")
        return False
    if not token:
        return False
    # Comparación en tiempo constante para prevenir timing attacks
    return hmac.compare_digest(token.strip(), expected.strip())


async def _encolar_procesamiento_correo(
    email_address: str,
    history_id: int,
    subscription: str,
    message_id: str,
) -> None:
    """
    Encola el procesamiento del correo en Celery.

    El worker de Celery (Agente 1) descarga el correo completo de Gmail,
    guarda el registro en correo, descarga y sube adjuntos a Storage,
    y dispara el pipeline de procesamiento.
    """
    try:
        # Importar la tarea de Celery aquí para evitar import circular
        # La tarea vive en packages/agents/agente_1_ingesta.py
        from celery_app import celery_app  # type: ignore[import]

        celery_app.send_task(
            "agentes.agente_1.procesar_notificacion_gmail",
            kwargs={
                "email_address": email_address,
                "history_id": history_id,
                "subscription": subscription,
                "pubsub_message_id": message_id,
            },
            queue="ingesta",
        )
        log.info(
            "correo_encolado_celery",
            email_address=email_address,
            history_id=history_id,
        )
    except Exception as exc:
        # No propagar el error — Gmail reintentará si no recibe 200
        # Pero sí registrar para alertas
        log.error(
            "error_encolar_celery",
            email_address=email_address,
            history_id=history_id,
            error=str(exc),
        )


# ===========================================================================
# ENDPOINTS
# ===========================================================================


@router.post(
    "/webhook/gmail",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Webhook de Gmail Push Notifications",
    description=(
        "Google Pub/Sub llama este endpoint cuando llega un correo nuevo a "
        "cualquier cuenta de Google Workspace monitoreada vía DWD. "
        "Responde en <500ms y delega el procesamiento a Celery (Agente 1). "
        "Requiere el token de verificación en el query param ?token=..."
    ),
    include_in_schema=False,  # No exponer en docs públicas
)
async def recibir_notificacion_gmail(
    notification: PubSubNotification,
    background_tasks: BackgroundTasks,
    token: str | None = Query(default=None, alias="token"),
) -> None:
    """
    Punto de entrada de Gmail Push Notifications.

    Google Pub/Sub entrega notificaciones con garantía at-least-once —
    el mismo mensaje puede llegar más de una vez. La idempotencia se
    garantiza en el Agente 1 por el UNIQUE constraint en correo.message_id.
    """
    # Verificar token de seguridad
    if not _verificar_token_webhook(token):
        log.warning(
            "webhook_token_invalido",
            subscription=notification.subscription,
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Token de webhook inválido.",
        )

    # Decodificar datos del mensaje
    data = _decodificar_pubsub_data(notification.message.data)
    if not data:
        # Pub/Sub requiere 200/204 para confirmar recepción, incluso en datos malformados
        # Si no confirmamos, Pub/Sub reintenta indefinidamente
        log.warning("pubsub_data_vacio", message_id=notification.message.messageId)
        return

    email_address = data.get("emailAddress", "")
    history_id = data.get("historyId", 0)

    if not email_address or not history_id:
        log.warning(
            "pubsub_campos_faltantes",
            data=data,
            message_id=notification.message.messageId,
        )
        return

    log.info(
        "gmail_notificacion_recibida",
        email_address=email_address,
        history_id=history_id,
        subscription=notification.subscription,
        pubsub_message_id=notification.message.messageId,
    )

    # Encolar en background para responder a Pub/Sub en < 500ms
    # Si tardamos más, Pub/Sub asume fallo y reintenta
    background_tasks.add_task(
        _encolar_procesamiento_correo,
        email_address=email_address,
        history_id=history_id,
        subscription=notification.subscription,
        message_id=notification.message.messageId,
    )


@router.get(
    "/webhook/gmail/health",
    summary="Estado del webhook Gmail",
    description="Retorna el estado de sincronización de todas las cuentas DWD monitoreadas.",
    include_in_schema=False,
)
async def estado_gmail_webhook(
    token: str | None = Query(default=None),
) -> dict[str, Any]:
    """
    Endpoint de diagnóstico: estado de sincronización por cuenta de Workspace.

    Muestra el último historyId procesado, si el canal Pub/Sub está activo
    y cuándo expira. Útil para detectar si el webhook está caído.
    """
    if not _verificar_token_webhook(token):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Token inválido.")

    db = get_admin_db()
    result = (
        db.table("gmail_sync_state")
        .select(
            "cuenta_workspace, ultimo_history_id, ultimo_sync_at, "
            "correos_ultimo_sync, canal_activo, canal_expira_at, updated_at"
        )
        .order("cuenta_workspace")
        .execute()
    )

    cuentas = result.data or []
    return {
        "cuentas": cuentas,
        "total_cuentas": len(cuentas),
        "cuentas_sin_canal": sum(1 for c in cuentas if not c.get("canal_activo")),
    }


@router.post(
    "/webhook/gmail/renovar-canal",
    status_code=status.HTTP_202_ACCEPTED,
    summary="Renovar canal Pub/Sub de una cuenta",
    description=(
        "Renueva el canal de Gmail Push Notifications para la cuenta indicada. "
        "Los canales expiran cada 7 días — este endpoint los renueva antes de que expiren."
    ),
    include_in_schema=False,
)
async def renovar_canal_gmail(
    email_address: str = Query(description="Cuenta de Workspace a renovar."),
    token: str | None = Query(default=None),
) -> dict[str, str]:
    """Encola la renovación del canal Pub/Sub para la cuenta indicada."""
    if not _verificar_token_webhook(token):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Token inválido.")

    try:
        from celery_app import celery_app  # type: ignore[import]

        celery_app.send_task(
            "agentes.gmail_worker.renovar_canal_pubsub",
            kwargs={"email_address": email_address},
            queue="ingesta",
        )
    except Exception as exc:
        log.error("error_encolar_renovacion", email_address=email_address, error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="No se pudo encolar la renovación del canal.",
        ) from exc

    log.info("canal_renovacion_encolada", email_address=email_address)
    return {"mensaje": f"Renovación del canal encolada para {email_address}."}

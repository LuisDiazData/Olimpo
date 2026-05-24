"""
Router de notificaciones.

GET    /notificaciones                     â€” notificaciones del usuario actual
PATCH  /notificaciones/{id}/marcar-leida   â€” marcar una notificaciÃ³n como leÃ­da
POST   /notificaciones/marcar-todas-leidas â€” marcar todas las no leÃ­das como leÃ­das
GET    /notificaciones/conteo              â€” conteo de no leÃ­das (para el badge de la UI)
"""

from datetime import datetime
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from core.auth import get_current_user
from core.database import get_user_db
from models.pagination import PaginatedResponse
from models.usuario import UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/notificaciones", tags=["notificaciones"])


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

class NotificacionResponse(BaseModel):
    id: UUID
    usuario_id: UUID
    tipo: str = Field(description="Tipo de evento que originÃ³ la notificaciÃ³n.")
    titulo: str
    cuerpo: str
    tramite_id: UUID | None = Field(default=None, description="TrÃ¡mite relacionado, si aplica.")
    datos: dict = Field(default_factory=dict, description="Datos adicionales estructurados segÃºn el tipo.")
    leida: bool = Field(description="False: pendiente de leer. True: ya vista por el usuario.")
    created_at: datetime

    model_config = {"from_attributes": True}


class ConteoNotificaciones(BaseModel):
    no_leidas: int = Field(description="NÃºmero de notificaciones no leÃ­das del usuario actual.")


# ---------------------------------------------------------------------------
# GET /notificaciones
# ---------------------------------------------------------------------------

@router.get(
    "",
    response_model=PaginatedResponse[NotificacionResponse],
    summary="Listar notificaciones del usuario",
    description=(
        "Devuelve las notificaciones del usuario autenticado, ordenadas por fecha desc. "
        "RLS garantiza que cada usuario solo ve sus propias notificaciones. "
        "Filtrable por estado de lectura. "
        "Para notificaciones en tiempo real, suscribirse al canal de Supabase Realtime."
    ),
)
async def listar_notificaciones(
    solo_no_leidas: bool = Query(default=False, description="True para ver solo notificaciones pendientes de leer."),
    limit: int = Query(default=50, ge=1, le=200, description="MÃ¡ximo de registros por pÃ¡gina."),
    offset: int = Query(default=0, ge=0, description="NÃºmero de registros a saltar."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> PaginatedResponse[NotificacionResponse]:
    db = get_user_db(usuario.access_token)

    def _apply_filters(q_builder):
        q_builder = q_builder.eq("usuario_id", str(usuario.id))
        if solo_no_leidas:
            q_builder = q_builder.eq("leida", False)
        return q_builder

    count_result = _apply_filters(db.table("notificacion").select("id", count="exact")).execute()
    total = count_result.count or 0

    result = (
        _apply_filters(db.table("notificacion").select(
            "id, usuario_id, tipo, titulo, cuerpo, tramite_id, datos, leida, created_at"
        ))
        .order("created_at", desc=True)
        .range(offset, offset + limit - 1)
        .execute()
    )

    items = [NotificacionResponse.model_validate(row) for row in result.data]
    return PaginatedResponse.build(items=items, total=total, offset=offset, limit=limit)


# ---------------------------------------------------------------------------
# GET /notificaciones/conteo
# ---------------------------------------------------------------------------

@router.get(
    "/conteo",
    response_model=ConteoNotificaciones,
    summary="Conteo de notificaciones no leÃ­das",
    description=(
        "Devuelve el nÃºmero de notificaciones no leÃ­das del usuario actual. "
        "Usar para el badge numÃ©rico del Ã­cono de notificaciones en la UI. "
        "MÃ¡s eficiente que listar todas las notificaciones solo para contar."
    ),
)
async def contar_no_leidas(
    usuario: UsuarioToken = Depends(get_current_user),
) -> ConteoNotificaciones:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("notificacion")
        .select("id", count="exact")
        .eq("usuario_id", str(usuario.id))
        .eq("leida", False)
        .execute()
    )
    return ConteoNotificaciones(no_leidas=result.count or 0)


# ---------------------------------------------------------------------------
# PATCH /notificaciones/{id}/marcar-leida
# ---------------------------------------------------------------------------

@router.patch(
    "/{notificacion_id}/marcar-leida",
    response_model=NotificacionResponse,
    summary="Marcar notificaciÃ³n como leÃ­da",
    description=(
        "Marca una notificaciÃ³n especÃ­fica como leÃ­da. "
        "RLS garantiza que el usuario solo puede marcar sus propias notificaciones. "
        "Idempotente: marcar una notificaciÃ³n ya leÃ­da no genera error."
    ),
)
async def marcar_leida(
    notificacion_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> NotificacionResponse:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("notificacion")
        .update({"leida": True})
        .eq("id", str(notificacion_id))
        .eq("usuario_id", str(usuario.id))
        .select("id, usuario_id, tipo, titulo, cuerpo, tramite_id, datos, leida, created_at")
        .execute()
    )
    if result.data:
        result.data = result.data[0]
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "NOTIFICACION_NO_ENCONTRADA", "mensaje": "NotificaciÃ³n no encontrada."},
        )
    return NotificacionResponse.model_validate(result.data)


# ---------------------------------------------------------------------------
# POST /notificaciones/marcar-todas-leidas
# ---------------------------------------------------------------------------

@router.post(
    "/marcar-todas-leidas",
    status_code=status.HTTP_200_OK,
    summary="Marcar todas las notificaciones como leÃ­das",
    description=(
        "Marca todas las notificaciones no leÃ­das del usuario actual como leÃ­das. "
        "Equivalente al botÃ³n 'Marcar todo como leÃ­do'. "
        "Devuelve el nÃºmero de notificaciones marcadas."
    ),
)
async def marcar_todas_leidas(
    usuario: UsuarioToken = Depends(get_current_user),
) -> dict:
    db = get_user_db(usuario.access_token)
    result = (
        db.table("notificacion")
        .update({"leida": True})
        .eq("usuario_id", str(usuario.id))
        .eq("leida", False)
        .execute()
    )
    marcadas = len(result.data) if result.data else 0
    log.info("notificaciones_marcadas_leidas", usuario_id=str(usuario.id), cantidad=marcadas)
    return {"marcadas": marcadas, "mensaje": f"{marcadas} notificaciones marcadas como leÃ­das."}

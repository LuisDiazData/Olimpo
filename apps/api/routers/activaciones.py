"""
Router de activaciones GNP (OT).

GET    /tramites/{id}/activaciones          â€” historial de OTs del trÃ¡mite
POST   /tramites/{id}/activaciones          â€” registrar nueva activaciÃ³n de GNP
PATCH  /tramites/{id}/activaciones/{ot_id}  â€” actualizar resultado de OT (directores/gerentes)
"""

from datetime import date
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from core.auth import get_current_user, require_roles
from core.database import get_user_db
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(tags=["activaciones"])

_GERENTES_Y_DIRECTORES = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))
]


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

class ActivacionCreate(BaseModel):
    numero_ot: str = Field(min_length=1, max_length=50, description="NÃºmero de OT asignado por GNP.")
    motivo: str | None = Field(default=None, max_length=500, description="DescripciÃ³n del motivo de la activaciÃ³n. Ej: 'Alta nueva GMM', 'Endoso ampliaciÃ³n de suma'.")
    fecha_activacion: date = Field(default_factory=date.today, description="Fecha en que GNP registrÃ³ la activaciÃ³n. Por defecto: hoy.")
    notas: str | None = Field(default=None, max_length=1000, description="Notas adicionales del analista sobre esta activaciÃ³n.")
    force_update_folio: bool = Field(default=False, description="Si True, actualiza tramite.folio_ot aunque ya tenga uno. Usar para correcciones.")


class ActivacionUpdate(BaseModel):
    resuelta: bool | None = Field(default=None, description="Marcar como resuelta cuando GNP cierra la OT.")
    resultado: str | None = Field(default=None, description="Resultado final de GNP: aprobado, rechazado o pendiente.")
    fecha_resolucion: date | None = Field(default=None, description="Fecha en que GNP resolviÃ³ la OT.")
    notas: str | None = Field(default=None, max_length=1000, description="Notas adicionales del analista.")


class ActivacionResponse(BaseModel):
    id: UUID
    tramite_id: UUID
    numero_ot: str
    motivo: str | None
    fecha_activacion: date
    fecha_resolucion: date | None
    resuelta: bool
    resultado: str | None
    notas: str | None
    registrado_por: UUID | None
    created_at: str
    updated_at: str

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# GET /tramites/{id}/activaciones
# ---------------------------------------------------------------------------

@router.get(
    "/tramites/{tramite_id}/activaciones",
    response_model=list[ActivacionResponse],
    summary="Historial de OTs GNP del trÃ¡mite",
    description=(
        "Devuelve el historial completo de Ã“rdenes de Trabajo (OT) de GNP para un trÃ¡mite. "
        "Un trÃ¡mite puede tener mÃºltiples activaciones (especialmente endosos). "
        "tramite.folio_ot es el acceso rÃ¡pido a la OT principal; este endpoint tiene el historial completo."
    ),
)
async def listar_activaciones(
    tramite_id: UUID,
    solo_pendientes: bool = Query(default=False, description="True para ver solo OTs que GNP aÃºn no ha resuelto."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[ActivacionResponse]:
    db = get_user_db(usuario.access_token)

    query = db.table("ot_activacion").select("*").eq("tramite_id", str(tramite_id))
    if solo_pendientes:
        query = query.eq("resuelta", False)

    result = query.order("fecha_activacion", desc=True).execute()
    return [ActivacionResponse.model_validate(row) for row in result.data]


# ---------------------------------------------------------------------------
# POST /tramites/{id}/activaciones
# ---------------------------------------------------------------------------

@router.post(
    "/tramites/{tramite_id}/activaciones",
    response_model=ActivacionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Registrar activaciÃ³n de GNP",
    description=(
        "Registra una nueva activaciÃ³n (OT) de GNP para el trÃ¡mite. "
        "Actualiza tramite.folio_ot si es la primera OT o si force_update_folio=True. "
        "EnvÃ­a notificaciÃ³n 'activacion_gnp' al analista asignado. "
        "Llama la funciÃ³n RPC registrar_activacion_gnp() de la base de datos."
    ),
)
async def crear_activacion(
    tramite_id: UUID,
    body: ActivacionCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> ActivacionResponse:
    db = get_user_db(usuario.access_token)

    result = db.rpc("registrar_activacion_gnp", {
        "p_tramite_id": str(tramite_id),
        "p_numero_ot": body.numero_ot,
        "p_motivo": body.motivo,
        "p_fecha_activacion": body.fecha_activacion.isoformat(),
        "p_notas": body.notas,
        "p_force_update_folio": body.force_update_folio,
    }).execute()

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error_code": "ERROR_ACTIVACION", "mensaje": "No se pudo registrar la activaciÃ³n de GNP."},
        )

    ot_id = result.data
    ot_result = db.table("ot_activacion").select("*").eq("id", str(ot_id)).execute()

    log.info("activacion_gnp_registrada", tramite_id=str(tramite_id), ot=body.numero_ot, por=str(usuario.id))
    return ActivacionResponse.model_validate(ot_result.data)


# ---------------------------------------------------------------------------
# PATCH /tramites/{id}/activaciones/{ot_id}
# ---------------------------------------------------------------------------

@router.patch(
    "/tramites/{tramite_id}/activaciones/{ot_id}",
    response_model=ActivacionResponse,
    dependencies=_GERENTES_Y_DIRECTORES,
    summary="Actualizar resultado de OT GNP",
    description=(
        "Actualiza el resultado de una activaciÃ³n de GNP (marcar como resuelta, agregar resultado). "
        "Solo gerentes y directores pueden modificar el resultado â€” analistas pueden registrar pero no corregir. "
        "Las OTs son registros histÃ³ricos y no se eliminan."
    ),
)
async def actualizar_activacion(
    tramite_id: UUID,
    ot_id: UUID,
    body: ActivacionUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> ActivacionResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"error_code": "SIN_CAMBIOS", "mensaje": "No se enviaron campos para actualizar."},
        )

    if "fecha_resolucion" in cambios:
        cambios["fecha_resolucion"] = cambios["fecha_resolucion"].isoformat()

    db = get_user_db(usuario.access_token)
    result = (
        db.table("ot_activacion")
        .update(cambios)
        .eq("id", str(ot_id))
        .eq("tramite_id", str(tramite_id))
        .select("*")
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "ACTIVACION_NO_ENCONTRADA", "mensaje": "ActivaciÃ³n no encontrada en este trÃ¡mite."},
        )

    log.info("activacion_actualizada", ot_id=str(ot_id), cambios=list(cambios.keys()), por=str(usuario.id))
    return ActivacionResponse.model_validate(result.data)

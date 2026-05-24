"""
Router de SLAs.

GET    /slas/definiciones                  â€” catÃ¡logo de definiciones SLA (directores)
POST   /slas/definiciones                  â€” crear definiciÃ³n SLA (directores)
PATCH  /slas/definiciones/{id}             â€” actualizar definiciÃ³n SLA (directores)
GET    /tramites/{id}/sla                  â€” estado semÃ¡foro del SLA de un trÃ¡mite
"""

from datetime import datetime
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from core.auth import get_current_user, require_roles
from core.database import get_user_db
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(tags=["slas"])

_SOLO_DIRECTORES = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))
]


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

class SlaDefinicionResponse(BaseModel):
    id: UUID
    ramo: str | None = Field(description="Ramo al que aplica. NULL = aplica a todos los ramos.")
    tipo_tramite: str = Field(description="Tipo de trÃ¡mite al que aplica esta definiciÃ³n.")
    dias_habiles: int = Field(description="Plazo en dÃ­as hÃ¡biles para completar el trÃ¡mite.")
    estado_inicio: str | None = Field(default=None, description="Estado del trÃ¡mite donde inicia el conteo. NULL = desde recepciÃ³n.")
    estado_fin: str | None = Field(default=None, description="Estado del trÃ¡mite donde termina el conteo. NULL = hasta aprobado/rechazado.")
    alerta_dias: int = Field(description="DÃ­as hÃ¡biles antes del vencimiento para enviar alerta.")
    activo: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class SlaDefinicionCreate(BaseModel):
    ramo: str | None = Field(default=None, description="Ramo al que aplica. NULL = aplica a todos.")
    tipo_tramite: str = Field(description="Tipo de trÃ¡mite: alta, endoso, renovacion, etc.")
    dias_habiles: int = Field(ge=1, le=365, description="Plazo en dÃ­as hÃ¡biles (1-365).")
    estado_inicio: str | None = Field(default=None, description="Estado donde inicia el conteo. NULL = recepciÃ³n.")
    estado_fin: str | None = Field(default=None, description="Estado donde termina el conteo. NULL = terminal.")
    alerta_dias: int = Field(ge=1, default=2, description="DÃ­as hÃ¡biles antes del vencimiento para la primera alerta.")


class SlaDefinicionUpdate(BaseModel):
    dias_habiles: int | None = Field(default=None, ge=1, le=365)
    alerta_dias: int | None = Field(default=None, ge=1)
    activo: bool | None = None


class SlaTramiteStatus(BaseModel):
    tramite_id: UUID
    sla_tramite_id: UUID | None = Field(description="UUID del registro sla_tramite. NULL si no hay SLA activo.")
    estado_semaforo: str = Field(description="verde: a tiempo. amarillo: en alerta. rojo: vencido. sin_sla: no tiene definiciÃ³n.")
    fecha_limite: datetime | None = Field(description="Fecha y hora lÃ­mite del SLA.")
    dias_restantes: float | None = Field(description="DÃ­as hÃ¡biles restantes. Negativo si ya venciÃ³.")
    dias_habiles_plazo: int | None = Field(description="Plazo total en dÃ­as hÃ¡biles de la definiciÃ³n.")
    vencido: bool = Field(description="True si el trÃ¡mite superÃ³ su fecha lÃ­mite de SLA.")

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# GET /slas/definiciones
# ---------------------------------------------------------------------------

@router.get(
    "/slas/definiciones",
    response_model=list[SlaDefinicionResponse],
    dependencies=_SOLO_DIRECTORES,
    summary="Listar definiciones de SLA",
    description=(
        "Devuelve el catÃ¡logo completo de definiciones de SLA configuradas. "
        "Cada definiciÃ³n establece el plazo en dÃ­as hÃ¡biles para un tipo de trÃ¡mite y ramo. "
        "Solo directores pueden ver y gestionar las definiciones. "
        "La fuente canÃ³nica de SLAs es esta tabla â€” no hay valores hardcodeados."
    ),
)
async def listar_sla_definiciones(
    ramo: str | None = Query(default=None, description="Filtrar por ramo especÃ­fico."),
    tipo_tramite: str | None = Query(default=None, description="Filtrar por tipo de trÃ¡mite."),
    solo_activos: bool = Query(default=True, description="False para incluir definiciones desactivadas."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[SlaDefinicionResponse]:
    db = get_user_db(usuario.access_token)
    query = db.table("sla_definicion").select("*")

    if ramo:
        query = query.eq("ramo", ramo)
    if tipo_tramite:
        query = query.eq("tipo_tramite", tipo_tramite)
    if solo_activos:
        query = query.eq("activo", True)

    result = query.order("tipo_tramite").execute()
    return [SlaDefinicionResponse.model_validate(row) for row in result.data]


# ---------------------------------------------------------------------------
# POST /slas/definiciones
# ---------------------------------------------------------------------------

@router.post(
    "/slas/definiciones",
    response_model=SlaDefinicionResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=_SOLO_DIRECTORES,
    summary="Crear definiciÃ³n de SLA",
    description=(
        "Crea una nueva definiciÃ³n de SLA para un tipo de trÃ¡mite y ramo. "
        "Solo directores pueden crear definiciones. "
        "El cambio queda registrado en audit_log automÃ¡ticamente."
    ),
)
async def crear_sla_definicion(
    body: SlaDefinicionCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> SlaDefinicionResponse:
    db = get_user_db(usuario.access_token)
    payload = body.model_dump(exclude_none=True)

    result = db.table("sla_definicion").insert(payload).select("*").execute()
    if result.data:
        result.data = result.data[0]
    log.info("sla_definicion_creada", tipo=body.tipo_tramite, ramo=body.ramo, por=str(usuario.id))
    return SlaDefinicionResponse.model_validate(result.data)


# ---------------------------------------------------------------------------
# PATCH /slas/definiciones/{id}
# ---------------------------------------------------------------------------

@router.patch(
    "/slas/definiciones/{sla_id}",
    response_model=SlaDefinicionResponse,
    dependencies=_SOLO_DIRECTORES,
    summary="Actualizar definiciÃ³n de SLA",
    description=(
        "Actualiza los parÃ¡metros de una definiciÃ³n de SLA existente. "
        "Los trÃ¡mites que ya tienen sla_tramite registrado NO se actualizan retroactivamente. "
        "Solo afecta a los trÃ¡mites nuevos que se creen despuÃ©s del cambio."
    ),
)
async def actualizar_sla_definicion(
    sla_id: UUID,
    body: SlaDefinicionUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> SlaDefinicionResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail={"error_code": "SIN_CAMBIOS", "mensaje": "No se enviaron campos para actualizar."},
        )

    db = get_user_db(usuario.access_token)
    result = (
        db.table("sla_definicion")
        .update(cambios)
        .eq("id", str(sla_id))
        .select("*")
        .execute()
    )
    if result.data:
        result.data = result.data[0]
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "SLA_NO_ENCONTRADO", "mensaje": "DefiniciÃ³n de SLA no encontrada."},
        )
    log.info("sla_definicion_actualizada", sla_id=str(sla_id), cambios=list(cambios.keys()), por=str(usuario.id))
    return SlaDefinicionResponse.model_validate(result.data)


# ---------------------------------------------------------------------------
# GET /tramites/{id}/sla
# ---------------------------------------------------------------------------

@router.get(
    "/tramites/{tramite_id}/sla",
    response_model=SlaTramiteStatus,
    summary="Estado SLA del trÃ¡mite",
    description=(
        "Devuelve el estado semÃ¡foro del SLA del trÃ¡mite: verde (a tiempo), amarillo (en alerta), rojo (vencido). "
        "Incluye fecha lÃ­mite, dÃ­as restantes y si ya venciÃ³. "
        "Endpoint crÃ­tico para agentes MCP: el agente consulta esto antes de decidir si escalar."
    ),
)
async def obtener_sla_tramite(
    tramite_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> SlaTramiteStatus:
    db = get_user_db(usuario.access_token)

    result = (
        db.table("sla_tramite")
        .select("id, tramite_id, fecha_limite, vencido, estado_semaforo, dias_habiles_plazo")
        .eq("tramite_id", str(tramite_id))
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )

    if not result.data:
        # El trÃ¡mite no tiene SLA activo (puede no tener definiciÃ³n configurada)
        return SlaTramiteStatus(
            tramite_id=tramite_id,
            sla_tramite_id=None,
            estado_semaforo="sin_sla",
            fecha_limite=None,
            dias_restantes=None,
            dias_habiles_plazo=None,
            vencido=False,
        )

    row = result.data[0]
    fecha_limite: datetime | None = None
    dias_restantes: float | None = None

    if row.get("fecha_limite"):
        from datetime import timezone
        fecha_limite = datetime.fromisoformat(row["fecha_limite"])
        ahora = datetime.now(timezone.utc)
        delta = (fecha_limite - ahora).total_seconds()
        dias_restantes = round(delta / 86400, 1)

    return SlaTramiteStatus(
        tramite_id=tramite_id,
        sla_tramite_id=UUID(row["id"]),
        estado_semaforo=row.get("estado_semaforo", "sin_sla"),
        fecha_limite=fecha_limite,
        dias_restantes=dias_restantes,
        dias_habiles_plazo=row.get("dias_habiles_plazo"),
        vencido=row.get("vencido", False),
    )

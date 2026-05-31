"""
Router de SLAs.

GET    /slas/definiciones                    — catálogo de definiciones SLA
POST   /slas/definiciones                    — crear definición SLA (directores)
PATCH  /slas/definiciones/{id}              — actualizar definición SLA (directores)
DELETE /slas/definiciones/{id}              — desactivar definición SLA (directores)
GET    /slas/preview                         — qué SLA aplicaría a tipo+ramo+prioridad
GET    /slas/dias-inhabiles                  — calendario de días no laborables
POST   /slas/dias-inhabiles                  — registrar día inhábil (directores)
PATCH  /slas/dias-inhabiles/{id}            — actualizar día inhábil (directores)
DELETE /slas/dias-inhabiles/{id}            — eliminar día inhábil (directores)
GET    /tramites/{id}/sla                    — estado semáforo del SLA de un trámite
"""

from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field

from core.auth import get_current_user, require_permiso, require_roles
from core.database import get_admin_db_dep, get_user_db
from models.tramite import PrioridadTramite, TipoTramite
from models.usuario import RamoUsuario, RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(tags=["slas"])

_SOLO_DIRECTORES = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))
]
_CONFIGURAR_SLAS = _SOLO_DIRECTORES + [Depends(require_permiso("slas.configurar"))]


# ---------------------------------------------------------------------------
# Modelos — sla_definicion
# ---------------------------------------------------------------------------

class SlaDefinicionCreate(BaseModel):
    nombre: str = Field(
        min_length=2, max_length=200,
        description='Nombre descriptivo visible en la UI. Ej: "Alta GMM urgente".',
    )
    descripcion: str | None = Field(default=None, max_length=1000)
    tipo_tramite: TipoTramite | None = Field(
        default=None,
        description="Tipo de trámite al que aplica. NULL = aplica a todos los tipos.",
    )
    ramo: RamoUsuario | None = Field(
        default=None,
        description="Ramo al que aplica. NULL = aplica a todos los ramos.",
    )
    prioridad_aplica: PrioridadTramite | None = Field(
        default=None,
        description="Prioridad a la que aplica. NULL = aplica a todas las prioridades.",
    )
    dias_habiles: int = Field(
        ge=1, le=365,
        description="Plazo en días hábiles (excluye fines de semana y días inhábiles configurados).",
    )
    alerta_porcentaje: Decimal = Field(
        default=Decimal("80"),
        ge=1, lt=100,
        description=(
            "Porcentaje del plazo consumido al que se dispara la alerta preventiva. "
            "Ej: 80 → alerta cuando se ha usado el 80% del tiempo disponible."
        ),
    )


class SlaDefinicionUpdate(BaseModel):
    nombre: str | None = Field(default=None, min_length=2, max_length=200)
    descripcion: str | None = None
    dias_habiles: int | None = Field(default=None, ge=1, le=365)
    alerta_porcentaje: Decimal | None = Field(default=None, ge=1, lt=100)
    activo: bool | None = None


class SlaDefinicionResponse(BaseModel):
    id: UUID
    nombre: str
    descripcion: str | None
    tipo_tramite: str | None
    ramo: str | None
    prioridad_aplica: str | None
    dias_habiles: int
    alerta_porcentaje: Decimal
    activo: bool
    creado_por: UUID | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Modelos — dia_inhabil
# ---------------------------------------------------------------------------

class DiaInhabilCreate(BaseModel):
    fecha: date = Field(description="Fecha del día no laborable (YYYY-MM-DD).")
    descripcion: str = Field(
        min_length=2, max_length=200,
        description='Motivo del día inhábil. Ej: "Día de la Independencia".',
    )
    aplica_ramo: RamoUsuario | None = Field(
        default=None,
        description="Ramo al que aplica. NULL = aplica a toda la promotoría (festivo nacional).",
    )


class DiaInhabilUpdate(BaseModel):
    descripcion: str | None = Field(default=None, min_length=2, max_length=200)
    aplica_ramo: RamoUsuario | None = None


class DiaInhabilResponse(BaseModel):
    id: UUID
    fecha: date
    descripcion: str
    aplica_ramo: str | None
    creado_por: UUID | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Modelos — estado SLA de un trámite
# ---------------------------------------------------------------------------

class SlaTramiteStatus(BaseModel):
    tramite_id: UUID
    sla_tramite_id: UUID | None = Field(
        description="UUID del registro sla_tramite. NULL si el trámite no tiene SLA activo."
    )
    sla_nombre: str | None = Field(
        description="Nombre de la definición de SLA aplicada."
    )
    estado: str | None = Field(
        description="Estado interno: en_curso, cumplido, incumplido, pausado."
    )
    estado_semaforo: str = Field(
        description="verde · amarillo · rojo · pausado · cumplido · sin_sla"
    )
    fecha_inicio: datetime | None
    fecha_limite: datetime | None = Field(
        description="Fecha y hora límite del SLA. NULL si no tiene SLA."
    )
    dias_restantes: float | None = Field(
        description="Días calendario restantes. Negativo si ya venció."
    )
    dias_habiles_plazo: int | None = Field(
        description="Plazo total en días hábiles de la definición aplicada."
    )
    alerta_porcentaje: Decimal | None = Field(
        description="Umbral de alerta en porcentaje (ej: 80 = alerta al 80% del tiempo)."
    )
    porcentaje_consumido: Decimal | None = Field(
        description="Porcentaje del tiempo consumido (0–100). Útil para barras de progreso."
    )
    vencido: bool = Field(description="True si ya superó la fecha_limite y no está cerrado.")
    alerta_enviada: bool = Field(default=False)

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# GET /slas/definiciones
# ---------------------------------------------------------------------------

@router.get(
    "/slas/definiciones",
    response_model=list[SlaDefinicionResponse],
    dependencies=_SOLO_DIRECTORES,
    summary="Listar definiciones de SLA",
)
async def listar_sla_definiciones(
    ramo: RamoUsuario | None = Query(default=None),
    tipo_tramite: TipoTramite | None = Query(default=None),
    solo_activos: bool = Query(default=True, description="False para incluir definiciones desactivadas."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[SlaDefinicionResponse]:
    db = get_user_db(usuario.access_token)
    query = db.table("sla_definicion").select("*")

    if ramo:
        query = query.eq("ramo", ramo.value)
    if tipo_tramite:
        query = query.eq("tipo_tramite", tipo_tramite.value)
    if solo_activos:
        query = query.eq("activo", True)

    result = query.order("tipo_tramite").order("ramo").order("nombre").execute()
    return [SlaDefinicionResponse.model_validate(row) for row in result.data]


# ---------------------------------------------------------------------------
# POST /slas/definiciones
# ---------------------------------------------------------------------------

@router.post(
    "/slas/definiciones",
    response_model=SlaDefinicionResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=_CONFIGURAR_SLAS,
    summary="Crear definición de SLA",
)
async def crear_sla_definicion(
    body: SlaDefinicionCreate,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> SlaDefinicionResponse:
    payload = body.model_dump(exclude_none=True)
    # Serialize enums and Decimal to JSON-compatible types
    for k, v in payload.items():
        if hasattr(v, "value"):
            payload[k] = v.value
        elif isinstance(v, Decimal):
            payload[k] = float(v)

    payload["creado_por"] = str(usuario.id)

    result = admin.table("sla_definicion").insert(payload).select("*").execute()
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error_code": "ERROR_CREAR_SLA", "mensaje": "No se pudo crear la definición de SLA."},
        )
    log.info("sla_definicion_creada", nombre=body.nombre, tipo=getattr(body.tipo_tramite, "value", None), por=str(usuario.id))
    return SlaDefinicionResponse.model_validate(result.data[0])


# ---------------------------------------------------------------------------
# PATCH /slas/definiciones/{id}
# ---------------------------------------------------------------------------

@router.patch(
    "/slas/definiciones/{sla_id}",
    response_model=SlaDefinicionResponse,
    dependencies=_CONFIGURAR_SLAS,
    summary="Actualizar definición de SLA",
    description=(
        "Actualiza los parámetros de una definición de SLA. "
        "Los trámites con sla_tramite ya registrado NO se actualizan retroactivamente — "
        "solo afecta a los trámites nuevos que se creen después del cambio."
    ),
)
async def actualizar_sla_definicion(
    sla_id: UUID,
    body: SlaDefinicionUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> SlaDefinicionResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"error_code": "SIN_CAMBIOS", "mensaje": "No se enviaron campos para actualizar."},
        )

    for k, v in cambios.items():
        if isinstance(v, Decimal):
            cambios[k] = float(v)

    result = (
        admin.table("sla_definicion")
        .update(cambios)
        .eq("id", str(sla_id))
        .select("*")
        .execute()
    )
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "SLA_NO_ENCONTRADO", "mensaje": "Definición de SLA no encontrada."},
        )
    log.info("sla_definicion_actualizada", sla_id=str(sla_id), campos=list(cambios.keys()), por=str(usuario.id))
    return SlaDefinicionResponse.model_validate(result.data[0])


# ---------------------------------------------------------------------------
# DELETE /slas/definiciones/{id}  — soft-delete
# ---------------------------------------------------------------------------

@router.delete(
    "/slas/definiciones/{sla_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_CONFIGURAR_SLAS,
    summary="Desactivar definición de SLA",
    description=(
        "Soft-delete: pone activo=False. No elimina el registro — "
        "sla_tramite existentes siguen referenciando la definición para auditoría."
    ),
)
async def desactivar_sla_definicion(
    sla_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> None:
    result = (
        admin.table("sla_definicion")
        .update({"activo": False})
        .eq("id", str(sla_id))
        .execute()
    )
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "SLA_NO_ENCONTRADO", "mensaje": "Definición de SLA no encontrada."},
        )
    log.info("sla_definicion_desactivada", sla_id=str(sla_id), por=str(usuario.id))


# ---------------------------------------------------------------------------
# GET /slas/preview  — ¿qué SLA aplicaría?
# ---------------------------------------------------------------------------

@router.get(
    "/slas/preview",
    response_model=SlaDefinicionResponse | None,
    dependencies=_SOLO_DIRECTORES,
    summary="Previsualizar resolución de SLA",
    description=(
        "Devuelve la definición de SLA que aplicaría a un trámite con los parámetros dados. "
        "Útil para que el director verifique su configuración antes de guardar. "
        "Devuelve null si no existe ninguna regla que cubra esa combinación."
    ),
)
async def preview_sla(
    tipo_tramite: TipoTramite | None = Query(default=None),
    ramo: RamoUsuario | None = Query(default=None),
    prioridad: PrioridadTramite | None = Query(default=None),
    usuario: UsuarioToken = Depends(get_current_user),
) -> SlaDefinicionResponse | None:
    db = get_user_db(usuario.access_token)
    result = db.rpc(
        "resolver_sla_definicion",
        {
            "p_tipo_tramite": tipo_tramite.value if tipo_tramite else None,
            "p_ramo": ramo.value if ramo else None,
            "p_prioridad": prioridad.value if prioridad else None,
        },
    ).execute()

    if not result.data:
        return None

    sla_id = result.data if isinstance(result.data, str) else str(result.data)
    detail = db.table("sla_definicion").select("*").eq("id", sla_id).maybe_single().execute()
    if not detail.data:
        return None
    return SlaDefinicionResponse.model_validate(detail.data)


# ---------------------------------------------------------------------------
# GET /slas/dias-inhabiles
# ---------------------------------------------------------------------------

@router.get(
    "/slas/dias-inhabiles",
    response_model=list[DiaInhabilResponse],
    dependencies=_SOLO_DIRECTORES,
    summary="Listar días inhábiles",
)
async def listar_dias_inhabiles(
    anio: int | None = Query(default=None, description="Filtrar por año (ej: 2026)."),
    aplica_ramo: RamoUsuario | None = Query(default=None, description="Filtrar por ramo. NULL = ver todos."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[DiaInhabilResponse]:
    db = get_user_db(usuario.access_token)
    query = db.table("dia_inhabil").select("*")

    if anio:
        # Filtrar por año usando rango de fechas
        query = (
            query
            .gte("fecha", f"{anio}-01-01")
            .lte("fecha", f"{anio}-12-31")
        )
    if aplica_ramo:
        query = query.eq("aplica_ramo", aplica_ramo.value)

    result = query.order("fecha").execute()
    return [DiaInhabilResponse.model_validate(row) for row in result.data]


# ---------------------------------------------------------------------------
# POST /slas/dias-inhabiles
# ---------------------------------------------------------------------------

@router.post(
    "/slas/dias-inhabiles",
    response_model=DiaInhabilResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=_CONFIGURAR_SLAS,
    summary="Registrar día inhábil",
)
async def crear_dia_inhabil(
    body: DiaInhabilCreate,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> DiaInhabilResponse:
    payload: dict = {
        "fecha": body.fecha.isoformat(),
        "descripcion": body.descripcion,
        "creado_por": str(usuario.id),
    }
    if body.aplica_ramo:
        payload["aplica_ramo"] = body.aplica_ramo.value

    try:
        result = admin.table("dia_inhabil").insert(payload).select("*").execute()
    except Exception as exc:
        if "uq_dia_inhabil_fecha_ramo" in str(exc) or "unique" in str(exc).lower():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "error_code": "DIA_INHABIL_DUPLICADO",
                    "mensaje": (
                        f"Ya existe un día inhábil para {body.fecha.isoformat()} "
                        f"con el mismo ramo ({body.aplica_ramo or 'global'})."
                    ),
                },
            )
        raise

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error_code": "ERROR_CREAR_DIA_INHABIL", "mensaje": "No se pudo registrar el día inhábil."},
        )
    log.info("dia_inhabil_creado", fecha=body.fecha.isoformat(), ramo=getattr(body.aplica_ramo, "value", None), por=str(usuario.id))
    return DiaInhabilResponse.model_validate(result.data[0])


# ---------------------------------------------------------------------------
# PATCH /slas/dias-inhabiles/{id}
# ---------------------------------------------------------------------------

@router.patch(
    "/slas/dias-inhabiles/{dia_id}",
    response_model=DiaInhabilResponse,
    dependencies=_CONFIGURAR_SLAS,
    summary="Actualizar día inhábil",
)
async def actualizar_dia_inhabil(
    dia_id: UUID,
    body: DiaInhabilUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> DiaInhabilResponse:
    cambios = body.model_dump(exclude_none=True)
    if "aplica_ramo" in cambios and cambios["aplica_ramo"] is not None:
        cambios["aplica_ramo"] = cambios["aplica_ramo"].value

    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"error_code": "SIN_CAMBIOS", "mensaje": "No se enviaron campos para actualizar."},
        )

    result = (
        admin.table("dia_inhabil")
        .update(cambios)
        .eq("id", str(dia_id))
        .select("*")
        .execute()
    )
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "DIA_INHABIL_NO_ENCONTRADO", "mensaje": "Día inhábil no encontrado."},
        )
    return DiaInhabilResponse.model_validate(result.data[0])


# ---------------------------------------------------------------------------
# DELETE /slas/dias-inhabiles/{id}
# ---------------------------------------------------------------------------

@router.delete(
    "/slas/dias-inhabiles/{dia_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_CONFIGURAR_SLAS,
    summary="Eliminar día inhábil",
)
async def eliminar_dia_inhabil(
    dia_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> None:
    result = (
        admin.table("dia_inhabil")
        .delete()
        .eq("id", str(dia_id))
        .execute()
    )
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "DIA_INHABIL_NO_ENCONTRADO", "mensaje": "Día inhábil no encontrado."},
        )
    log.info("dia_inhabil_eliminado", dia_id=str(dia_id), por=str(usuario.id))


# ---------------------------------------------------------------------------
# GET /tramites/{id}/sla
# ---------------------------------------------------------------------------

@router.get(
    "/tramites/{tramite_id}/sla",
    response_model=SlaTramiteStatus,
    summary="Estado SLA del trámite",
    description=(
        "Devuelve el semáforo SLA del trámite consultando sla_tramite_vista, "
        "que calcula estado_semaforo, vencido, dias_restantes y porcentaje_consumido en tiempo real. "
        "Endpoint crítico para agentes MCP: el agente consulta esto antes de decidir si escalar."
    ),
)
async def obtener_sla_tramite(
    tramite_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> SlaTramiteStatus:
    db = get_user_db(usuario.access_token)

    result = (
        db.table("sla_tramite_vista")
        .select(
            "id, tramite_id, sla_nombre, estado, estado_semaforo, "
            "fecha_inicio, fecha_limite, dias_restantes, dias_habiles_plazo, "
            "alerta_porcentaje, porcentaje_consumido, vencido, alerta_enviada"
        )
        .eq("tramite_id", str(tramite_id))
        .maybe_single()
        .execute()
    )

    if not result.data:
        return SlaTramiteStatus(
            tramite_id=tramite_id,
            sla_tramite_id=None,
            sla_nombre=None,
            estado=None,
            estado_semaforo="sin_sla",
            fecha_inicio=None,
            fecha_limite=None,
            dias_restantes=None,
            dias_habiles_plazo=None,
            alerta_porcentaje=None,
            porcentaje_consumido=None,
            vencido=False,
            alerta_enviada=False,
        )

    row = result.data
    return SlaTramiteStatus(
        tramite_id=tramite_id,
        sla_tramite_id=UUID(row["id"]),
        sla_nombre=row.get("sla_nombre"),
        estado=row.get("estado"),
        estado_semaforo=row.get("estado_semaforo", "sin_sla"),
        fecha_inicio=row.get("fecha_inicio"),
        fecha_limite=row.get("fecha_limite"),
        dias_restantes=row.get("dias_restantes"),
        dias_habiles_plazo=row.get("dias_habiles_plazo"),
        alerta_porcentaje=row.get("alerta_porcentaje"),
        porcentaje_consumido=row.get("porcentaje_consumido"),
        vencido=row.get("vencido", False),
        alerta_enviada=row.get("alerta_enviada", False),
    )

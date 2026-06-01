"""
Router de asignaciones (agente + ramo â†’ analista).

GET    /asignaciones                     â€” lista de reglas de asignaciÃ³n
POST   /asignaciones                     â€” crear regla (gerentes/directores)
DELETE /asignaciones/{id}                â€” soft-delete (activo = FALSE)
GET    /asignaciones/resolver            â€” analista efectivo hoy (aplica vacaciones)
"""

from datetime import date
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status

from core.auth import get_current_user, get_current_user_or_agent, require_roles
from core.database import get_user_db
from models.asignacion import (
    AsignacionCreate,
    AsignacionResponse,
    AsignacionUpdate,
    BulkAsignacionCreate,
    BulkAsignacionResult,
    ResolverAsignacionResponse,
)
from models.usuario import RamoUsuario, RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(tags=["asignaciones"])

_ESCRITURA = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))
]


# ---------------------------------------------------------------------------
# GET /asignaciones
# ---------------------------------------------------------------------------


@router.get(
    "/asignaciones",
    response_model=list[AsignacionResponse],
    summary="Listar reglas de asignaciÃ³n",
    description=(
        "Devuelve las reglas que mapean (agente + ramo) â†’ analista. "
        "Directores ven todas; gerentes ven las de su ramo. "
        "Estas reglas son la configuraciÃ³n base del Agente 4 para asignar trÃ¡mites."
    ),
)
async def listar_asignaciones(
    ramo: RamoUsuario | None = Query(default=None, description="Filtrar por ramo."),
    agente_id: UUID | None = Query(default=None, description="UUID del agente de seguros."),
    analista_id: UUID | None = Query(default=None, description="UUID del analista asignado."),
    activo: bool | None = Query(
        default=True, description="False para incluir reglas desactivadas."
    ),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[AsignacionResponse]:
    db = get_user_db(usuario.access_token)
    query = db.table("asignacion").select(
        "id, agente_id, ramo, analista_id, notas, asignado_por, activo, created_at, updated_at"
    )

    if activo is not None:
        query = query.eq("activo", activo)
    if ramo:
        query = query.eq("ramo", ramo.value)
    if agente_id:
        query = query.eq("agente_id", str(agente_id))
    if analista_id:
        query = query.eq("analista_id", str(analista_id))

    result = query.order("created_at", desc=True).range(offset, offset + limit - 1).execute()
    items: list[AsignacionResponse] = []
    for a in result.data:
        items.append(AsignacionResponse.model_validate(a))
    return items


# ---------------------------------------------------------------------------
# GET /asignaciones/resolver  (ANTES que /{id} para que FastAPI no lo confunda)
# ---------------------------------------------------------------------------


@router.get(
    "/asignaciones/resolver",
    response_model=ResolverAsignacionResponse,
    summary="Resolver analista efectivo para agente+ramo",
    description=(
        "Devuelve el analista que debe recibir un trÃ¡mite HOY para el par (agente, ramo), "
        "aplicando la lÃ³gica de cobertura de vacaciones vigente. "
        "Si el analista titular estÃ¡ de vacaciones, devuelve el analista de cobertura. "
        "Si no hay asignaciÃ³n ni cobertura, requiere_atencion=True. "
        "Endpoint crÃ­tico para el Agente 4 vÃ­a MCP â€” operaciÃ³n atÃ³mica que encapsula "
        "las reglas de asignaciÃ³n Y las vacaciones en una sola llamada."
    ),
)
async def resolver_asignacion(
    agente_id: UUID = Query(
        ..., description="UUID del agente de seguros del que proviene el correo."
    ),
    ramo: RamoUsuario = Query(
        ..., description="Ramo del trÃ¡mite a asignar (vida, autos, gmm, etc.)."
    ),
    fecha: date = Query(
        default_factory=date.today, description="Fecha para la que resolver. Por defecto: hoy."
    ),
    actor: UsuarioToken = Depends(get_current_user_or_agent),
) -> ResolverAsignacionResponse:
    from core.database import get_admin_db

    db = get_admin_db()

    result = db.rpc(
        "resolver_analista_asignacion",
        {"p_agente_id": str(agente_id), "p_ramo": ramo.value, "p_fecha": fecha.isoformat()},
    ).execute()

    analista_id: UUID | None = UUID(result.data) if result.data else None

    return ResolverAsignacionResponse(
        agente_id=agente_id,
        ramo=ramo,
        fecha=fecha,
        analista_id=analista_id,
        requiere_atencion=analista_id is None,
    )


# ---------------------------------------------------------------------------
# POST /asignaciones
# ---------------------------------------------------------------------------


@router.post(
    "/asignaciones",
    response_model=AsignacionResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=_ESCRITURA,
    summary="Crear regla de asignaciÃ³n",
    description=(
        "Crea una regla que asigna los trÃ¡mites de un agente+ramo a un analista especÃ­fico. "
        "El trigger de DB valida que el analista sea del ramo correcto. "
        "No puede haber dos reglas activas para el mismo agente+ramo â€” desactivar la anterior primero."
    ),
)
async def crear_asignacion(
    body: AsignacionCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> AsignacionResponse:
    db = get_user_db(usuario.access_token)
    payload = {
        "agente_id": str(body.agente_id),
        "ramo": body.ramo.value,
        "analista_id": str(body.analista_id),
        "asignado_por": str(usuario.id),
    }
    if body.notas:
        payload["notas"] = body.notas

    try:
        result = (
            db.table("asignacion")
            .insert(payload)
            .select(
                "id, agente_id, ramo, analista_id, notas, asignado_por, activo, created_at, updated_at"
            )
            .execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "uq_asignacion_activa" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "error_code": "ASIGNACION_DUPLICADA",
                    "mensaje": "Ya existe una asignaciÃ³n activa para este agente y ramo. Desactiva la anterior primero.",
                },
            ) from exc
        if "Solo se puede asignar un usuario con rol" in msg or "analista es del ramo" in msg:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
                detail={"error_code": "VALIDACION_FALLO", "mensaje": msg},
            ) from exc
        raise

    log.info("asignacion_creada", id=result.data["id"], agente=str(body.agente_id), ramo=body.ramo)
    return AsignacionResponse.model_validate(result.data)


# ---------------------------------------------------------------------------
# DELETE /asignaciones/{id}
# ---------------------------------------------------------------------------


@router.delete(
    "/asignaciones/{asignacion_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_ESCRITURA,
    summary="Desactivar regla de asignaciÃ³n",
    description=(
        "Soft-delete de la regla de asignaciÃ³n (activo=False). "
        "El historial se preserva. Los trÃ¡mites ya asignados no se reasignan. "
        "Usar antes de crear una nueva regla para el mismo agente+ramo."
    ),
)
async def desactivar_asignacion(
    asignacion_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> None:
    db = get_user_db(usuario.access_token)
    result = db.table("asignacion").update({"activo": False}).eq("id", str(asignacion_id)).execute()
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "error_code": "ASIGNACION_NO_ENCONTRADA",
                "mensaje": "AsignaciÃ³n no encontrada.",
            },
        )
    log.info("asignacion_desactivada", id=str(asignacion_id), por=str(usuario.id))


# ---------------------------------------------------------------------------
# PATCH /asignaciones/{id}
# ---------------------------------------------------------------------------


@router.patch(
    "/asignaciones/{asignacion_id}",
    response_model=AsignacionResponse,
    dependencies=_ESCRITURA,
    summary="Actualizar regla de asignación",
    description="Permite cambiar el analista asignado o reactivarla.",
)
async def actualizar_asignacion(
    asignacion_id: UUID,
    body: AsignacionUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> AsignacionResponse:
    from core.database import get_admin_db

    db_admin = get_admin_db()

    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos para actualizar.",
        )

    result = (
        db_admin.table("asignacion")
        .select(
            "id, agente_id, ramo, analista_id, notas, asignado_por, activo, created_at, updated_at"
        )
        .eq("id", str(asignacion_id))
        .maybe_single()
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Asignación no encontrada."
        )

    db_admin.table("asignacion").update(cambios).eq("id", str(asignacion_id)).execute()

    refreshed = (
        db_admin.table("asignacion")
        .select(
            "id, agente_id, ramo, analista_id, notas, asignado_por, activo, created_at, updated_at"
        )
        .eq("id", str(asignacion_id))
        .execute()
    )

    log.info("asignacion_actualizada", id=str(asignacion_id), cambios=cambios, por=str(usuario.id))
    return AsignacionResponse.model_validate(refreshed.data[0])


# ---------------------------------------------------------------------------
# POST /asignaciones/bulk
# ---------------------------------------------------------------------------


@router.post(
    "/asignaciones/bulk",
    response_model=BulkAsignacionResult,
    status_code=status.HTTP_201_CREATED,
    dependencies=_ESCRITURA,
    summary="Asignación masiva de agentes a analista por ramo",
    description=(
        "Recibe una lista de agentes y un ramo+analista. "
        "Crea UNA regla de asignación por cada agente. "
        "Si ya existe una asignación activa para ese agente+ramo, esa fila se salta (no error). "
        "Retorna el resumen de creados, saltados y errores."
    ),
)
async def asignacion_masiva(
    body: BulkAsignacionCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> BulkAsignacionResult:
    from core.database import get_admin_db

    db_admin = get_admin_db()

    agente_ids = [str(aid) for aid in body.agente_ids]

    existing_q = (
        db_admin.table("asignacion")
        .select("agente_id, ramo")
        .in_("agente_id", agente_ids)
        .eq("ramo", body.ramo.value)
        .eq("activo", True)
        .execute()
    )

    existing_keys: set[tuple[str, str]] = {
        (r["agente_id"], r["ramo"]) for r in (existing_q.data or [])
    }

    detalle: list[str] = []
    creados = 0
    saltados = 0
    errores = 0

    for agente_id in agente_ids:
        key = (agente_id, body.ramo.value)
        if key in existing_keys:
            saltados += 1
            detalle.append(
                f"Saltado agente {agente_id}: ya tiene asignación activa para {body.ramo.value}."
            )
            continue

        try:
            db_admin.table("asignacion").insert(
                {
                    "agente_id": agente_id,
                    "ramo": body.ramo.value,
                    "analista_id": str(body.analista_id),
                    "asignado_por": str(usuario.id),
                    "notas": body.notas,
                }
            ).execute()
            creados += 1
        except Exception as exc:
            errores += 1
            detalle.append(f"Error agente {agente_id}: {exc}")

    log.info(
        "asignacion_masiva",
        creados=creados,
        saltados=saltados,
        errores=errores,
        por=str(usuario.id),
    )

    return BulkAsignacionResult(
        total=len(body.agente_ids),
        creados=creados,
        saltados=saltados,
        errores=errores,
        detalle=detalle,
    )

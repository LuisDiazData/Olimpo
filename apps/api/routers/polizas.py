"""
Router de pÃ³lizas y asegurados.

PÃ³lizas:
GET    /polizas               â€” lista con filtros
POST   /polizas               â€” crear pÃ³liza
GET    /polizas/{id}          â€” detalle con asegurados vinculados
PATCH  /polizas/{id}          â€” actualizar pÃ³liza
POST   /polizas/{id}/asegurados      â€” vincular asegurado a pÃ³liza
DELETE /polizas/{id}/asegurados/{id} â€” desvincular (solo directores)

Asegurados:
GET    /asegurados            â€” buscar asegurados
POST   /asegurados            â€” registrar asegurado
GET    /asegurados/{id}       â€” detalle
PATCH  /asegurados/{id}       â€” enriquecer datos
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status

from core.auth import get_current_user, require_roles
from core.busqueda import filtro_busqueda_or
from core.database import get_admin_db_dep, get_user_db
from models.poliza import (
    AseguradoBuscarOCrearBody,
    AseguradoBuscarOCrearResponse,
    AseguradoCreate,
    AseguradoListItem,
    AseguradoResponse,
    AseguradoUpdate,
    CandidatoAsegurado,
    PolizaAseguradoCreate,
    PolizaAseguradoResponse,
    PolizaCreate,
    PolizaListItem,
    PolizaResponse,
    PolizaUpdate,
)
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(tags=["polizas"])

_SOLO_DIRECTORES = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _get_poliza_o_404(db, poliza_id: UUID) -> dict:
    result = (
        db.table("poliza").select("id, activo").eq("id", str(poliza_id)).maybe_single().execute()
    )
    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Póliza no encontrada.")
    return result.data


# ===========================================================================
# ASEGURADOS
# ===========================================================================


@router.get("/asegurados", response_model=list[AseguradoListItem])
async def buscar_asegurados(
    q: str | None = Query(default=None, description="Buscar por nombre o RFC"),
    activo: bool | None = Query(default=True),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[AseguradoListItem]:
    db = get_user_db(usuario.access_token)
    query = db.table("asegurado").select("id, nombre, tipo, rfc, activo")

    if activo is not None:
        query = query.eq("activo", activo)
    if q:
        query = query.or_(filtro_busqueda_or(q, "nombre", "rfc"))

    result = query.order("nombre").range(offset, offset + limit - 1).execute()
    return [AseguradoListItem.model_validate(a) for a in result.data]


@router.post(
    "/asegurados",
    response_model=AseguradoResponse,
    status_code=status.HTTP_201_CREATED,
)
async def crear_asegurado(
    body: AseguradoCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> AseguradoResponse:
    db = get_user_db(usuario.access_token)

    try:
        result = (
            db.table("asegurado").insert(body.model_dump(exclude_none=True)).select("*").execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "uq_asegurado_rfc" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Ya existe un asegurado con RFC '{body.rfc}'.",
            ) from exc
        if "uq_asegurado_curp" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Ya existe un asegurado con CURP '{body.curp}'.",
            ) from exc
        raise

    return AseguradoResponse.model_validate(result.data)


@router.post(
    "/asegurados/buscar-o-crear",
    response_model=AseguradoBuscarOCrearResponse,
    status_code=status.HTTP_200_OK,
    summary="Buscar o crear asegurado con deduplicación",
    description=(
        "Resolución de identidad para asegurados: busca por RFC → CURP → nombre fuzzy → crea nuevo. "
        "Cuando accion='ambiguo', requiere_atencion=True y candidatos[] contiene los registros similares. "
        "El Agente 4 usa este endpoint antes de vincular un asegurado a un trámite. "
        "El analista también puede usarlo desde la UI para evitar duplicados manuales."
    ),
)
async def buscar_o_crear_asegurado(
    body: AseguradoBuscarOCrearBody,
    usuario: UsuarioToken = Depends(get_current_user),
    admin=Depends(get_admin_db_dep),
) -> AseguradoBuscarOCrearResponse:
    result = admin.rpc(
        "buscar_o_crear_asegurado",
        {
            "p_nombre": body.nombre,
            "p_rfc": body.rfc,
            "p_curp": body.curp,
            "p_tipo": body.tipo.value if body.tipo else None,
            "p_fecha_nacimiento": body.fecha_nacimiento.isoformat()
            if body.fecha_nacimiento
            else None,
            "p_datos_adicionales": body.datos_adicionales or {},
            "p_similitud_minima": body.similitud_minima,
        },
    ).execute()

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={
                "error_code": "ERROR_DEDUP",
                "mensaje": "La función de deduplicación no retornó resultado.",
            },
        )

    data: dict = result.data if isinstance(result.data, dict) else result.data[0]

    asegurado_id = data.get("asegurado_id")
    accion = data.get("accion", "")
    requiere_atencion = data.get("requiere_atencion", False)
    candidatos_raw: list[dict] = data.get("candidatos") or []

    candidatos = [CandidatoAsegurado.model_validate(c) for c in candidatos_raw]

    asegurado_detail: AseguradoResponse | None = None
    if asegurado_id:
        db = get_user_db(usuario.access_token)
        aseg = (
            db.table("asegurado").select("*").eq("id", str(asegurado_id)).maybe_single().execute()
        )
        if aseg.data:
            asegurado_detail = AseguradoResponse.model_validate(aseg.data)

    log.info(
        "asegurado_dedup",
        accion=accion,
        asegurado_id=str(asegurado_id) if asegurado_id else None,
        requiere_atencion=requiere_atencion,
        n_candidatos=len(candidatos),
        por=str(usuario.id),
    )

    return AseguradoBuscarOCrearResponse(
        asegurado_id=asegurado_id,
        accion=accion,
        requiere_atencion=requiere_atencion,
        candidatos=candidatos,
        asegurado=asegurado_detail,
    )


@router.get("/asegurados/{asegurado_id}", response_model=AseguradoResponse)
async def obtener_asegurado(
    asegurado_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> AseguradoResponse:
    db = get_user_db(usuario.access_token)
    result = db.table("asegurado").select("*").eq("id", str(asegurado_id)).maybe_single().execute()
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Asegurado no encontrado."
        )
    return AseguradoResponse.model_validate(result.data)


@router.patch("/asegurados/{asegurado_id}", response_model=AseguradoResponse)
async def actualizar_asegurado(
    asegurado_id: UUID,
    body: AseguradoUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> AseguradoResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="No se enviaron campos."
        )

    db = get_user_db(usuario.access_token)

    try:
        result = (
            db.table("asegurado").update(cambios).eq("id", str(asegurado_id)).select("*").execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "uq_asegurado_rfc" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="RFC ya registrado."
            ) from exc
        if "uq_asegurado_curp" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="CURP ya registrado."
            ) from exc
        raise

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Asegurado no encontrado."
        )
    return AseguradoResponse.model_validate(result.data)


# ===========================================================================
# PÃ“LIZAS
# ===========================================================================


@router.get("/polizas", response_model=list[PolizaListItem])
async def listar_polizas(
    ramo: str | None = Query(default=None),
    agente_id: UUID | None = Query(default=None),
    analista_id: UUID | None = Query(default=None),
    estado: str | None = Query(default=None),
    q: str | None = Query(default=None, description="Buscar por nÃºmero de pÃ³liza"),
    activo: bool | None = Query(default=True),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[PolizaListItem]:
    db = get_user_db(usuario.access_token)

    query = db.table("poliza").select(
        "id, numero_poliza, ramo, estado, plan, fecha_inicio, fecha_fin, "
        "agente_id, analista_id, activo, "
        "agente!left(nombre)"
    )

    if activo is not None:
        query = query.eq("activo", activo)
    if ramo:
        query = query.eq("ramo", ramo)
    if agente_id:
        query = query.eq("agente_id", str(agente_id))
    if analista_id:
        query = query.eq("analista_id", str(analista_id))
    if estado:
        query = query.eq("estado", estado)
    if q:
        query = query.ilike("numero_poliza", f"%{q}%")

    result = query.order("created_at", desc=True).range(offset, offset + limit - 1).execute()

    items = []
    for row in result.data:
        agente_data = row.pop("agente", None) or {}
        row["agente_nombre"] = agente_data.get("nombre")
        items.append(PolizaListItem.model_validate(row))

    return items


@router.post("/polizas", response_model=PolizaResponse, status_code=status.HTTP_201_CREATED)
async def crear_poliza(
    body: PolizaCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> PolizaResponse:
    db = get_user_db(usuario.access_token)

    payload = body.model_dump(exclude_none=True)
    payload["agente_id"] = str(payload["agente_id"])
    if "analista_id" in payload:
        payload["analista_id"] = str(payload["analista_id"])

    try:
        result = (
            db.table("poliza")
            .insert(payload)
            .select(
                "*, agente!left(nombre, cua), "
                "usuario!poliza_analista_id_fkey!left(nombre), "
                "poliza_asegurado(id, poliza_id, asegurado_id, rol, parentesco, porcentaje, datos_adicionales, created_at)"
            )
            .execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        if "uq_poliza_numero" in str(exc):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Ya existe una pÃ³liza con nÃºmero '{body.numero_poliza}'.",
            ) from exc
        raise

    return _armar_poliza_response(result.data)


@router.get("/polizas/{poliza_id}", response_model=PolizaResponse)
async def obtener_poliza(
    poliza_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> PolizaResponse:
    db = get_user_db(usuario.access_token)

    result = (
        db.table("poliza")
        .select(
            "*, agente!left(nombre, cua), "
            "usuario!poliza_analista_id_fkey!left(nombre), "
            "poliza_asegurado(id, poliza_id, asegurado_id, rol, parentesco, porcentaje, datos_adicionales, created_at, "
            "asegurado!left(nombre))"
        )
        .eq("id", str(poliza_id))
        .maybe_single()
        .execute()
    )

    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Póliza no encontrada.")

    return _armar_poliza_response(result.data)


@router.patch("/polizas/{poliza_id}", response_model=PolizaResponse)
async def actualizar_poliza(
    poliza_id: UUID,
    body: PolizaUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> PolizaResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="No se enviaron campos."
        )

    db = get_user_db(usuario.access_token)
    _get_poliza_o_404(db, poliza_id)

    if "analista_id" in cambios:
        cambios["analista_id"] = str(cambios["analista_id"])
    if "estado" in cambios:
        cambios["estado"] = cambios["estado"].value

    db.table("poliza").update(cambios).eq("id", str(poliza_id)).execute()
    return await obtener_poliza(poliza_id, usuario)


# ---------------------------------------------------------------------------
# Asegurados vinculados a una pÃ³liza
# ---------------------------------------------------------------------------


@router.post(
    "/polizas/{poliza_id}/asegurados",
    response_model=PolizaAseguradoResponse,
    status_code=status.HTTP_201_CREATED,
)
async def vincular_asegurado(
    poliza_id: UUID,
    body: PolizaAseguradoCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> PolizaAseguradoResponse:
    """
    Vincula un asegurado existente a una pÃ³liza con un rol.
    El Ã­ndice uq_poliza_titular garantiza solo un titular por pÃ³liza.
    """
    db = get_user_db(usuario.access_token)
    _get_poliza_o_404(db, poliza_id)

    payload = body.model_dump(exclude_none=True)
    payload["poliza_id"] = str(poliza_id)
    payload["asegurado_id"] = str(payload["asegurado_id"])
    if "rol" in payload:
        payload["rol"] = payload["rol"].value
    if "porcentaje" in payload:
        payload["porcentaje"] = float(payload["porcentaje"])

    try:
        result = (
            db.table("poliza_asegurado")
            .insert(payload)
            .select(
                "id, poliza_id, asegurado_id, rol, parentesco, porcentaje, datos_adicionales, created_at"
            )
            .execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "uq_poliza_titular" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT, detail="Esta pÃ³liza ya tiene un titular."
            ) from exc
        if "uq_poliza_asegurado" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail="Este asegurado ya estÃ¡ vinculado a esta pÃ³liza.",
            ) from exc
        raise

    data = result.data
    data["asegurado_nombre"] = None
    return PolizaAseguradoResponse.model_validate(data)


@router.delete(
    "/polizas/{poliza_id}/asegurados/{vinculo_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_SOLO_DIRECTORES,
)
async def desvincular_asegurado(
    poliza_id: UUID,
    vinculo_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> None:
    """Solo directores pueden desvincular asegurados (para corregir errores del agente IA)."""
    db = get_user_db(usuario.access_token)
    db.table("poliza_asegurado").delete().eq("id", str(vinculo_id)).eq(
        "poliza_id", str(poliza_id)
    ).execute()
    log.info("asegurado_desvinculado", vinculo_id=str(vinculo_id), por=str(usuario.id))


# ---------------------------------------------------------------------------
# Helper de construcciÃ³n de PolizaResponse
# ---------------------------------------------------------------------------


def _armar_poliza_response(data: dict) -> PolizaResponse:
    agente = data.pop("agente", None) or {}
    data["agente_nombre"] = agente.get("nombre")
    data["agente_cua"] = agente.get("cua")

    analista = data.pop("usuario", None) or {}
    data["analista_nombre"] = analista.get("nombre")

    vinculos_raw = data.pop("poliza_asegurado", []) or []
    vinculos = []
    for v in vinculos_raw:
        asegurado = v.pop("asegurado", None) or {}
        v["asegurado_nombre"] = asegurado.get("nombre")
        vinculos.append(PolizaAseguradoResponse.model_validate(v))

    data["asegurados"] = vinculos
    return PolizaResponse.model_validate(data)

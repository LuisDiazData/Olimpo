"""
Router de coberturas de vacaciones.

GET    /coberturas           â€” coberturas activas (gerentes/directores)
POST   /coberturas           â€” crear cobertura de vacaciones
DELETE /coberturas/{id}      â€” eliminar cobertura
GET    /coberturas/vigentes  â€” coberturas activas hoy (usado por Agente 4 y asignaciones)
"""

from datetime import date, datetime
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import BaseModel, Field, model_validator

from core.auth import get_current_user, require_roles
from core.database import get_user_db
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/coberturas", tags=["coberturas"])

_GERENTES_Y_DIRECTORES = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))
]


# ---------------------------------------------------------------------------
# Modelos
# ---------------------------------------------------------------------------

class CoberturaCreate(BaseModel):
    analista_ausente_id: UUID = Field(description="UUID del analista que estarÃ¡ ausente por vacaciones.")
    analista_cobertura_id: UUID = Field(description="UUID del analista que cubrirÃ¡ durante la ausencia.")
    fecha_inicio: date = Field(description="Primer dÃ­a de ausencia (inclusive).")
    fecha_fin: date = Field(description="Ãšltimo dÃ­a de ausencia (inclusive).")
    notas: str | None = Field(default=None, max_length=500, description="Notas adicionales sobre la cobertura.")

    @model_validator(mode="after")
    def validar_fechas(self) -> "CoberturaCreate":
        if self.fecha_fin < self.fecha_inicio:
            raise ValueError("fecha_fin debe ser igual o posterior a fecha_inicio.")
        if self.analista_ausente_id == self.analista_cobertura_id:
            raise ValueError("El analista ausente y el de cobertura no pueden ser el mismo.")
        return self


class CoberturaResponse(BaseModel):
    id: UUID
    analista_ausente_id: UUID = Field(description="Analista que estÃ¡ ausente.")
    analista_cobertura_id: UUID = Field(description="Analista que cubre durante la ausencia.")
    fecha_inicio: date
    fecha_fin: date
    notas: str | None
    activo: bool
    creado_por: UUID | None
    created_at: datetime

    # Nombres enriquecidos (via JOIN)
    ausente_nombre: str | None = None
    cobertura_nombre: str | None = None

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# GET /coberturas
# ---------------------------------------------------------------------------

@router.get(
    "",
    response_model=list[CoberturaResponse],
    dependencies=_GERENTES_Y_DIRECTORES,
    summary="Listar coberturas de vacaciones",
    description=(
        "Devuelve las coberturas de vacaciones configuradas. "
        "Gerentes ven coberturas de su ramo; directores ven todas. "
        "Una cobertura activa redirige los trÃ¡mites del analista ausente al de cobertura."
    ),
)
async def listar_coberturas(
    solo_activas: bool = Query(default=True, description="True para ver solo coberturas actualmente vigentes."),
    analista_id: UUID | None = Query(default=None, description="UUID del analista (ausente o cobertura) para filtrar."),
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[CoberturaResponse]:
    db = get_user_db(usuario.access_token)

    query = db.table("cobertura_vacaciones").select(
        "*, "
        "ausente:usuario!cobertura_vacaciones_analista_ausente_id_fkey!left(nombre), "
        "cobertura:usuario!cobertura_vacaciones_analista_cobertura_id_fkey!left(nombre)"
    )

    if solo_activas:
        hoy = date.today().isoformat()
        query = query.lte("fecha_inicio", hoy).gte("fecha_fin", hoy).eq("activo", True)
    if analista_id:
        query = query.or_(
            f"analista_ausente_id.eq.{analista_id},analista_cobertura_id.eq.{analista_id}"
        )

    result = query.order("fecha_inicio", desc=True).execute()

    items = []
    for row in result.data:
        ausente = row.pop("ausente", None) or {}
        cobertura = row.pop("cobertura", None) or {}
        row["ausente_nombre"] = ausente.get("nombre")
        row["cobertura_nombre"] = cobertura.get("nombre")
        items.append(CoberturaResponse.model_validate(row))

    return items


# ---------------------------------------------------------------------------
# GET /coberturas/vigentes
# ---------------------------------------------------------------------------

@router.get(
    "/vigentes",
    response_model=list[CoberturaResponse],
    summary="Coberturas vigentes hoy",
    description=(
        "Devuelve las coberturas de vacaciones activas en la fecha actual. "
        "Usado por el Agente 4 y el endpoint GET /asignaciones/resolver para "
        "determinar a quÃ© analista asignar un trÃ¡mite cuando el titular estÃ¡ ausente. "
        "Accesible para todos los roles autenticados."
    ),
)
async def coberturas_vigentes(
    usuario: UsuarioToken = Depends(get_current_user),
) -> list[CoberturaResponse]:
    db = get_user_db(usuario.access_token)
    hoy = date.today().isoformat()

    result = (
        db.table("cobertura_vacaciones")
        .select(
            "*, "
            "ausente:usuario!cobertura_vacaciones_analista_ausente_id_fkey!left(nombre), "
            "cobertura:usuario!cobertura_vacaciones_analista_cobertura_id_fkey!left(nombre)"
        )
        .lte("fecha_inicio", hoy)
        .gte("fecha_fin", hoy)
        .eq("activo", True)
        .execute()
    )

    items = []
    for row in result.data:
        ausente = row.pop("ausente", None) or {}
        cobertura = row.pop("cobertura", None) or {}
        row["ausente_nombre"] = ausente.get("nombre")
        row["cobertura_nombre"] = cobertura.get("nombre")
        items.append(CoberturaResponse.model_validate(row))

    return items


# ---------------------------------------------------------------------------
# POST /coberturas
# ---------------------------------------------------------------------------

@router.post(
    "",
    response_model=CoberturaResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=_GERENTES_Y_DIRECTORES,
    summary="Crear cobertura de vacaciones",
    description=(
        "Configura que el analista_cobertura_id cubra los trÃ¡mites del analista_ausente_id "
        "durante el perÃ­odo indicado. "
        "El Agente 4 consultarÃ¡ esta configuraciÃ³n al asignar trÃ¡mites. "
        "Gerentes solo pueden crear coberturas para analistas de su ramo."
    ),
)
async def crear_cobertura(
    body: CoberturaCreate,
    usuario: UsuarioToken = Depends(get_current_user),
) -> CoberturaResponse:
    db = get_user_db(usuario.access_token)

    payload = {
        "analista_ausente_id": str(body.analista_ausente_id),
        "analista_cobertura_id": str(body.analista_cobertura_id),
        "fecha_inicio": body.fecha_inicio.isoformat(),
        "fecha_fin": body.fecha_fin.isoformat(),
        "notas": body.notas,
        "creado_por": str(usuario.id),
    }

    result = (
        db.table("cobertura_vacaciones")
        .insert(payload)
        .select(
            "*, "
            "ausente:usuario!cobertura_vacaciones_analista_ausente_id_fkey!left(nombre), "
            "cobertura:usuario!cobertura_vacaciones_analista_cobertura_id_fkey!left(nombre)"
        )
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    row = result.data
    ausente = row.pop("ausente", None) or {}
    cobertura_rel = row.pop("cobertura", None) or {}
    row["ausente_nombre"] = ausente.get("nombre")
    row["cobertura_nombre"] = cobertura_rel.get("nombre")

    log.info(
        "cobertura_creada",
        ausente=str(body.analista_ausente_id),
        cobertura=str(body.analista_cobertura_id),
        desde=body.fecha_inicio.isoformat(),
        hasta=body.fecha_fin.isoformat(),
        por=str(usuario.id),
    )
    return CoberturaResponse.model_validate(row)


# ---------------------------------------------------------------------------
# DELETE /coberturas/{id}
# ---------------------------------------------------------------------------

@router.delete(
    "/{cobertura_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_GERENTES_Y_DIRECTORES,
    summary="Eliminar cobertura de vacaciones",
    description=(
        "Elimina una cobertura de vacaciones. "
        "Si la cobertura ya estÃ¡ vigente, los trÃ¡mites en curso no se reasignan automÃ¡ticamente. "
        "Solo eliminar coberturas futuras o errÃ³neas â€” no coberturas en curso."
    ),
)
async def eliminar_cobertura(
    cobertura_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
) -> None:
    db = get_user_db(usuario.access_token)

    result = db.table("cobertura_vacaciones").select("id, fecha_inicio, fecha_fin").eq("id", str(cobertura_id)).maybe_single().execute()
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "COBERTURA_NO_ENCONTRADA", "mensaje": "Cobertura de vacaciones no encontrada."},
        )

    db.table("cobertura_vacaciones").delete().eq("id", str(cobertura_id)).execute()
    log.info("cobertura_eliminada", cobertura_id=str(cobertura_id), por=str(usuario.id))

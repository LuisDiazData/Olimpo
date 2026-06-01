"""
Router: gestión de licencias por tenant.

Endpoints (prefix /tenants/{tenant_id}/licencia):
  GET  /          — datos de licencia del tenant
  PUT  /          — actualizar plan, fechas o estado
  POST /renovar   — extender fecha de vencimiento + poner activa
  POST /suspender — cambiar estado a suspendida
  POST /activar   — cambiar estado a activa
"""

from datetime import date, timedelta
from typing import Literal
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from core.auth import require_superadmin
from core.database import get_admin_db

log = structlog.get_logger(__name__)

router = APIRouter(
    prefix="/tenants/{tenant_id}/licencia",
    tags=["Licencias"],
    dependencies=[Depends(require_superadmin)],
)


# =============================================================================
# MODELOS
# =============================================================================


class LicenciaUpdate(BaseModel):
    tipo_plan: Literal["basico", "profesional", "enterprise"] | None = None
    fecha_inicio_licencia: date | None = None
    fecha_vencimiento_licencia: date | None = None
    estado_licencia: Literal["activa", "prueba", "suspendida", "expirada"] | None = None


class RenovarLicencia(BaseModel):
    dias: int = Field(default=365, ge=30, le=1095, description="Días a extender desde hoy")


class LicenciaResponse(BaseModel):
    tenant_id: UUID
    tipo_plan: str
    fecha_inicio_licencia: date | None
    fecha_vencimiento_licencia: date | None
    estado_licencia: str

    model_config = {"from_attributes": True}


# =============================================================================
# HELPERS
# =============================================================================


def _get_tenant_or_404(tenant_id: UUID):
    db = get_admin_db()
    result = (
        db.table("tenant")
        .select("id, tipo_plan, fecha_inicio_licencia, fecha_vencimiento_licencia, estado_licencia")
        .eq("id", str(tenant_id))
        .single()
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TENANT_NO_ENCONTRADO", "mensaje": "Tenant no encontrado."},
        )
    return result.data


# =============================================================================
# ENDPOINTS
# =============================================================================


@router.get("", response_model=LicenciaResponse)
def obtener_licencia(tenant_id: UUID):
    """Devuelve los campos de licencia del tenant."""
    data = _get_tenant_or_404(tenant_id)
    return {**data, "tenant_id": data["id"]}


@router.put("", response_model=LicenciaResponse)
def actualizar_licencia(tenant_id: UUID, body: LicenciaUpdate):
    """Actualiza parcialmente plan, fechas y/o estado de la licencia."""
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "error_code": "SIN_CAMBIOS",
                "mensaje": "Se requiere al menos un campo para actualizar.",
            },
        )

    db = get_admin_db()
    result = db.table("tenant").update(cambios).eq("id", str(tenant_id)).execute()

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TENANT_NO_ENCONTRADO", "mensaje": "Tenant no encontrado."},
        )

    log.info("licencia_actualizada", tenant_id=str(tenant_id), cambios=list(cambios.keys()))
    data = result.data[0]
    return {**data, "tenant_id": data["id"]}


@router.post("/renovar", response_model=LicenciaResponse)
def renovar_licencia(tenant_id: UUID, body: RenovarLicencia):
    """
    Extiende la fecha de vencimiento en N días desde hoy y establece estado 'activa'.
    Si ya había fecha de vencimiento futura, la reemplaza con hoy + dias.
    """
    nueva_fecha = date.today() + timedelta(days=body.dias)

    db = get_admin_db()
    result = (
        db.table("tenant")
        .update(
            {
                "fecha_vencimiento_licencia": nueva_fecha.isoformat(),
                "estado_licencia": "activa",
            }
        )
        .eq("id", str(tenant_id))
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TENANT_NO_ENCONTRADO", "mensaje": "Tenant no encontrado."},
        )

    log.info(
        "licencia_renovada",
        tenant_id=str(tenant_id),
        nueva_fecha=nueva_fecha.isoformat(),
        dias=body.dias,
    )
    data = result.data[0]
    return {**data, "tenant_id": data["id"]}


@router.post("/suspender", response_model=LicenciaResponse)
def suspender_licencia(tenant_id: UUID):
    """Cambia el estado de la licencia a 'suspendida'."""
    db = get_admin_db()
    result = (
        db.table("tenant")
        .update({"estado_licencia": "suspendida"})
        .eq("id", str(tenant_id))
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TENANT_NO_ENCONTRADO", "mensaje": "Tenant no encontrado."},
        )

    log.info("licencia_suspendida", tenant_id=str(tenant_id))
    data = result.data[0]
    return {**data, "tenant_id": data["id"]}


@router.post("/activar", response_model=LicenciaResponse)
def activar_licencia(tenant_id: UUID):
    """Cambia el estado de la licencia a 'activa'."""
    db = get_admin_db()
    result = (
        db.table("tenant").update({"estado_licencia": "activa"}).eq("id", str(tenant_id)).execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TENANT_NO_ENCONTRADO", "mensaje": "Tenant no encontrado."},
        )

    log.info("licencia_activada", tenant_id=str(tenant_id))
    data = result.data[0]
    return {**data, "tenant_id": data["id"]}

"""
Router: gestión de tenants (instancias de promotoría).

Endpoints:
  GET  /tenants              — listar todos los tenants
  POST /tenants              — registrar nuevo tenant
  GET  /tenants/{id}         — detalle de un tenant
  POST /tenants/{id}/activar — reactivar un tenant bloqueado
  POST /tenants/{id}/bloquear — bloquear acceso superadmin al tenant
"""

from datetime import date, datetime, timedelta
from typing import Literal
from uuid import UUID

import httpx
import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator

from core.auth import require_superadmin
from core.crypto import cifrar_key
from core.database import get_admin_db

log = structlog.get_logger(__name__)

router = APIRouter(
    prefix="/tenants",
    tags=["Tenants"],
    dependencies=[Depends(require_superadmin)],
)


# =============================================================================
# MODELOS
# =============================================================================


class LicenciaCreate(BaseModel):
    tipo_plan: Literal["basico", "profesional", "enterprise"] = "basico"
    fecha_inicio_licencia: date | None = None
    fecha_vencimiento_licencia: date | None = None
    estado_licencia: Literal["activa", "prueba"] = "prueba"

    @field_validator("fecha_inicio_licencia", "fecha_vencimiento_licencia", mode="before")
    @classmethod
    def empty_str_to_none(cls, v: object) -> object:
        if v == "":
            return None
        return v


class TenantCreate(BaseModel):
    nombre: str = Field(min_length=2, max_length=200)
    subdominio: str = Field(
        pattern=r"^[a-z0-9][a-z0-9\-]*\.olimpo\.mx$",
        description="Ej: alvarez.olimpo.mx",
    )
    supabase_url: str = Field(description="Ej: https://abc123.supabase.co")
    service_role_key: str = Field(
        min_length=100, description="service_role_key en texto plano. Se almacena cifrada."
    )
    licencia: LicenciaCreate = Field(default_factory=LicenciaCreate)

    @field_validator("supabase_url")
    @classmethod
    def url_valida(cls, v: str) -> str:
        v = v.rstrip("/")
        if not v.startswith("https://"):
            raise ValueError("supabase_url debe comenzar con https://")
        return v


class TenantResponse(BaseModel):
    id: UUID
    nombre: str
    subdominio: str
    supabase_url: str
    activo: bool
    tipo_plan: str
    fecha_inicio_licencia: date | None
    fecha_vencimiento_licencia: date | None
    estado_licencia: str
    usuario_maestro_id: UUID | None
    usuario_maestro_email: str | None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class TenantListItem(BaseModel):
    id: UUID
    nombre: str
    subdominio: str
    activo: bool
    tipo_plan: str
    estado_licencia: str
    fecha_vencimiento_licencia: date | None
    usuario_maestro_email: str | None
    created_at: datetime

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


async def _validar_conectividad_tenant(supabase_url: str, service_role_key: str) -> None:
    """
    Verifica que el Supabase del tenant sea accesible y que la service_role_key sea válida.
    Lanza HTTP 422 si no responde o rechaza la key.
    """
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get(
                f"{supabase_url}/rest/v1/",
                headers={
                    "apikey": service_role_key,
                    "Authorization": f"Bearer {service_role_key}",
                },
                params={"limit": 1},
            )
            if response.status_code == 401 or response.status_code == 403:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail={
                        "error_code": "CREDENCIALES_INVALIDAS",
                        "mensaje": "La service_role_key proporcionada no es válida para este proyecto Supabase.",
                    },
                )
            if response.status_code >= 500:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail={
                        "error_code": "SUPABASE_TENANT_NO_DISPONIBLE",
                        "mensaje": "El proyecto Supabase del tenant no está respondiendo. "
                        "Verifica que el proyecto exista y esté activo.",
                    },
                )
    except (httpx.TimeoutException, httpx.ConnectError, httpx.RequestError) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "error_code": "SUPABASE_TENANT_NO_DISPONIBLE",
                "mensaje": "No se pudo conectar al proyecto Supabase del tenant. "
                "Verifica que la URL sea correcta y el proyecto esté activo.",
            },
        ) from exc


# =============================================================================
# ENDPOINTS
# =============================================================================


@router.get("", response_model=list[TenantListItem])
def listar_tenants():
    """Lista todos los tenants registrados."""
    db = get_admin_db()
    result = (
        db.table("tenant")
        .select(
            "id, nombre, subdominio, activo, tipo_plan, estado_licencia, "
            "fecha_vencimiento_licencia, usuario_maestro_email, created_at"
        )
        .order("created_at", desc=True)
        .execute()
    )
    return result.data


@router.post("", response_model=TenantResponse, status_code=status.HTTP_201_CREATED)
async def crear_tenant(body: TenantCreate):
    """
    Registra una nueva instancia de promotoría.

    Validaciones antes de persistir:
    1. Conectividad al Supabase del tenant con la service_role_key.
    2. La key se cifra con Fernet antes de guardar — nunca en texto plano.
    """
    await _validar_conectividad_tenant(body.supabase_url, body.service_role_key)

    db = get_admin_db()
    key_enc = cifrar_key(body.service_role_key)

    lic = body.licencia
    fecha_inicio = lic.fecha_inicio_licencia or date.today()
    fecha_venc = lic.fecha_vencimiento_licencia
    if fecha_venc is None and lic.estado_licencia == "prueba":
        fecha_venc = date.today() + timedelta(days=30)

    try:
        result = (
            db.table("tenant")
            .insert(
                {
                    "nombre": body.nombre,
                    "subdominio": body.subdominio,
                    "supabase_url": body.supabase_url,
                    "service_role_key_enc": key_enc,
                    "tipo_plan": lic.tipo_plan,
                    "fecha_inicio_licencia": fecha_inicio.isoformat(),
                    "fecha_vencimiento_licencia": fecha_venc.isoformat() if fecha_venc else None,
                    "estado_licencia": lic.estado_licencia,
                }
            )
            .execute()
        )
    except Exception as exc:
        msg = str(exc)
        if "uq_tenant_subdominio" in msg:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "error_code": "SUBDOMINIO_DUPLICADO",
                    "mensaje": f"Ya existe un tenant con el subdominio '{body.subdominio}'.",
                },
            ) from exc
        log.error("error_crear_tenant", error=msg)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error_code": "ERROR_DB", "mensaje": "Error al registrar el tenant."},
        ) from exc

    log.info("tenant_creado", subdominio=body.subdominio, nombre=body.nombre)
    return result.data[0]


@router.get("/{tenant_id}", response_model=TenantResponse)
def obtener_tenant(tenant_id: UUID):
    """Detalle completo de un tenant (sin exponer la service_role_key)."""
    db = get_admin_db()
    result = (
        db.table("tenant")
        .select(
            "id, nombre, subdominio, supabase_url, activo, "
            "tipo_plan, fecha_inicio_licencia, fecha_vencimiento_licencia, estado_licencia, "
            "usuario_maestro_id, usuario_maestro_email, created_at, updated_at"
        )
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


@router.post("/{tenant_id}/bloquear", status_code=status.HTTP_200_OK)
def bloquear_tenant(tenant_id: UUID):
    """
    Marca el tenant como inactivo en el registro del Superadmin.
    No afecta directamente a los usuarios ya autenticados en el tenant —
    para eso usa el endpoint bloquear del usuario maestro.
    """
    db = get_admin_db()
    result = db.table("tenant").update({"activo": False}).eq("id", str(tenant_id)).execute()
    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Tenant no encontrado.")
    log.info("tenant_bloqueado", tenant_id=str(tenant_id))
    return {"mensaje": "Tenant bloqueado correctamente."}


@router.post("/{tenant_id}/activar", status_code=status.HTTP_200_OK)
def activar_tenant(tenant_id: UUID):
    """Reactiva un tenant previamente bloqueado."""
    db = get_admin_db()
    result = db.table("tenant").update({"activo": True}).eq("id", str(tenant_id)).execute()
    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Tenant no encontrado.")
    log.info("tenant_activado", tenant_id=str(tenant_id))
    return {"mensaje": "Tenant activado correctamente."}

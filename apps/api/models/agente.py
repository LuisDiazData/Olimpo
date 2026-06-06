"""
Modelos Pydantic para el catálogo de agentes de seguros.

Jerarquía:
  agente           — el agente GNP (tiene CUA)
    agente_telefono  — teléfonos del agente (0..n, máx 1 preferente)
    agente_email     — correos del agente  (0..n, máx 1 preferente)
    asistente        — personas que operan a nombre del agente (0..n)
"""

from datetime import date, datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field, field_validator


class TipoTelefono(StrEnum):
    celular = "celular"
    oficina = "oficina"
    casa = "casa"
    whatsapp = "whatsapp"
    otro = "otro"


# ---------------------------------------------------------------------------
# Teléfonos
# ---------------------------------------------------------------------------


class TelefonoCreate(BaseModel):
    tipo: TipoTelefono = TipoTelefono.celular
    numero: str = Field(min_length=7, max_length=20)
    preferente: bool = False

    @field_validator("numero")
    @classmethod
    def numero_no_vacio(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("El número de teléfono no puede estar vacío.")
        return v.strip()


class TelefonoResponse(BaseModel):
    id: UUID
    agente_id: UUID
    tipo: TipoTelefono
    numero: str
    preferente: bool
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Emails del agente
# ---------------------------------------------------------------------------


class AgenteEmailCreate(BaseModel):
    email: EmailStr
    preferente: bool = False


class AgenteEmailResponse(BaseModel):
    id: UUID
    agente_id: UUID
    email: EmailStr
    preferente: bool
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Asistentes
# ---------------------------------------------------------------------------


class AsistenteCreate(BaseModel):
    nombre: str = Field(min_length=2, max_length=100)
    email: EmailStr
    telefono: str | None = Field(default=None, max_length=20)


class AsistenteUpdate(BaseModel):
    nombre: str | None = Field(default=None, min_length=2, max_length=100)
    telefono: str | None = Field(default=None, max_length=20)
    activo: bool | None = None


class AsistenteResponse(BaseModel):
    id: UUID
    agente_id: UUID
    nombre: str
    email: EmailStr
    telefono: str | None
    activo: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Agente principal
# ---------------------------------------------------------------------------


class AgenteCreate(BaseModel):
    cua: str = Field(
        min_length=1, max_length=20, description="Clave Única del Agente asignada por GNP."
    )
    nombre: str = Field(min_length=2, max_length=150)
    nombre_comercial: str | None = Field(default=None, max_length=150)
    rfc: str | None = Field(
        default=None,
        max_length=13,
        pattern=r"^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$",
        description="RFC del agente. Personas físicas 13 chars, morales 12 chars.",
    )
    fecha_afiliacion: date | None = None
    notas: str | None = Field(default=None, max_length=2000)

    @field_validator("cua")
    @classmethod
    def cua_solo_digitos(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("El CUA no puede estar vacío.")
        if not v.isdigit():
            raise ValueError("El CUA debe contener únicamente dígitos numéricos.")
        return v


class AgenteUpdate(BaseModel):
    nombre: str | None = Field(default=None, min_length=2, max_length=150)
    nombre_comercial: str | None = Field(default=None, max_length=150)
    rfc: str | None = Field(
        default=None,
        max_length=13,
        pattern=r"^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$",
    )
    fecha_afiliacion: date | None = None
    notas: str | None = Field(default=None, max_length=2000)
    activo: bool | None = None


class AgenteListItem(BaseModel):
    """Versión compacta para listados — sin teléfonos, emails ni asistentes."""

    id: UUID
    cua: str
    nombre: str
    nombre_comercial: str | None
    rfc: str | None
    fecha_afiliacion: date | None
    activo: bool
    email_preferente: str | None = None  # JOIN en el router para el email principal
    telefono_preferente: str | None = None  # JOIN en el router para el teléfono principal

    model_config = {"from_attributes": True}


class AgenteResponse(BaseModel):
    """Perfil completo del agente con sub-recursos anidados."""

    id: UUID
    cua: str
    nombre: str
    nombre_comercial: str | None
    rfc: str | None
    fecha_afiliacion: date | None
    notas: str | None
    activo: bool
    created_at: datetime
    updated_at: datetime
    telefonos: list[TelefonoResponse] = []
    emails: list[AgenteEmailResponse] = []
    asistentes: list[AsistenteResponse] = []

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Bulk import (Excel)
# ---------------------------------------------------------------------------


class AgenteImportRow(BaseModel):
    cua: str = Field(min_length=1, max_length=20)
    nombre: str = Field(min_length=2, max_length=150)
    nombre_comercial: str | None = Field(default=None, max_length=150)
    rfc: str | None = Field(default=None, max_length=13)
    fecha_afiliacion: str | None = Field(default=None, description="YYYY-MM-DD")
    email: str | None = Field(default=None, max_length=254)
    telefono: str | None = Field(default=None, max_length=20)
    tipo_telefono: TipoTelefono | None = None
    notas: str | None = Field(default=None, max_length=2000)

    @field_validator("cua")
    @classmethod
    def cua_solo_digitos(cls, v: str) -> str:
        v = v.strip()
        if not v.isdigit():
            raise ValueError("El CUA debe contener únicamente dígitos numéricos.")
        return v

    @field_validator("nombre")
    @classmethod
    def nombre_strip(cls, v: str) -> str:
        return v.strip()

    @field_validator("rfc")
    @classmethod
    def rfc_upper(cls, v: str | None) -> str | None:
        return v.strip().upper() if v else None


class ImportPreviewItem(BaseModel):
    row: int
    data: AgenteImportRow
    errors: list[str] = []
    will_create: bool = True
    will_update: bool = False
    existing_id: str | None = None


class ImportResultItem(BaseModel):
    row: int
    cua: str
    success: bool
    agente_id: str | None = None
    error: str | None = None


class ImportResponse(BaseModel):
    total: int
    exitosos: int
    fallidos: int
    errores_duplicados: int
    results: list[ImportResultItem]
    detalle: str

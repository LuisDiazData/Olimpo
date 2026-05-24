"""
Modelos Pydantic para pólizas y asegurados.
"""

from datetime import date, datetime
from enum import StrEnum
from decimal import Decimal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


class TipoPersona(StrEnum):
    persona_fisica = "persona_fisica"
    persona_moral = "persona_moral"


class EstadoPoliza(StrEnum):
    en_tramite = "en_tramite"
    activa = "activa"
    vencida = "vencida"
    cancelada = "cancelada"


class RolAsegurado(StrEnum):
    titular = "titular"
    asegurado_adicional = "asegurado_adicional"
    beneficiario = "beneficiario"


# ---------------------------------------------------------------------------
# Asegurado
# ---------------------------------------------------------------------------

class AseguradoCreate(BaseModel):
    nombre: str = Field(min_length=2, max_length=200)
    tipo: TipoPersona | None = None
    rfc: str | None = Field(
        default=None,
        max_length=13,
        pattern=r"^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$",
    )
    curp: str | None = Field(
        default=None,
        max_length=18,
        pattern=r"^[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}$",
    )
    fecha_nacimiento: date | None = None
    datos_adicionales: dict = Field(default_factory=dict)

    @field_validator("nombre")
    @classmethod
    def nombre_no_vacio(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("El nombre no puede estar vacío.")
        return v.strip()


class AseguradoUpdate(BaseModel):
    nombre: str | None = Field(default=None, min_length=2, max_length=200)
    tipo: TipoPersona | None = None
    rfc: str | None = Field(
        default=None,
        max_length=13,
        pattern=r"^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$",
    )
    curp: str | None = Field(
        default=None,
        max_length=18,
        pattern=r"^[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}$",
    )
    fecha_nacimiento: date | None = None
    datos_adicionales: dict | None = None
    activo: bool | None = None


class AseguradoResponse(BaseModel):
    id: UUID
    nombre: str
    tipo: TipoPersona | None
    rfc: str | None
    curp: str | None
    fecha_nacimiento: date | None
    datos_adicionales: dict
    activo: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class AseguradoListItem(BaseModel):
    id: UUID
    nombre: str
    tipo: TipoPersona | None
    rfc: str | None
    activo: bool

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Poliza_asegurado — vínculo
# ---------------------------------------------------------------------------

class PolizaAseguradoCreate(BaseModel):
    asegurado_id: UUID
    rol: RolAsegurado = RolAsegurado.titular
    parentesco: str | None = Field(default=None, max_length=50)
    porcentaje: Decimal | None = Field(default=None, ge=0, le=100)
    datos_adicionales: dict = Field(default_factory=dict)


class PolizaAseguradoResponse(BaseModel):
    id: UUID
    poliza_id: UUID
    asegurado_id: UUID
    asegurado_nombre: str | None = None
    rol: RolAsegurado
    parentesco: str | None
    porcentaje: Decimal | None
    datos_adicionales: dict
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Poliza
# ---------------------------------------------------------------------------

class PolizaCreate(BaseModel):
    numero_poliza: str = Field(min_length=1, max_length=50)
    ramo: str  # ramo_usuario enum value
    agente_id: UUID
    analista_id: UUID | None = None
    plan: str | None = Field(default=None, max_length=100)
    fecha_inicio: date | None = None
    fecha_fin: date | None = None
    datos_ramo: dict = Field(default_factory=dict)
    notas: str | None = Field(default=None, max_length=2000)

    @field_validator("numero_poliza")
    @classmethod
    def numero_no_vacio(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("El número de póliza no puede estar vacío.")
        return v.strip().upper()


class PolizaUpdate(BaseModel):
    plan: str | None = Field(default=None, max_length=100)
    fecha_inicio: date | None = None
    fecha_fin: date | None = None
    estado: EstadoPoliza | None = None
    datos_ramo: dict | None = None
    notas: str | None = Field(default=None, max_length=2000)
    analista_id: UUID | None = None
    activo: bool | None = None


class PolizaListItem(BaseModel):
    id: UUID
    numero_poliza: str
    ramo: str
    estado: EstadoPoliza
    plan: str | None
    fecha_inicio: date | None
    fecha_fin: date | None
    agente_id: UUID
    agente_nombre: str | None = None
    analista_id: UUID | None
    activo: bool

    model_config = {"from_attributes": True}


class PolizaResponse(BaseModel):
    id: UUID
    numero_poliza: str
    ramo: str
    agente_id: UUID
    agente_nombre: str | None = None
    agente_cua: str | None = None
    analista_id: UUID | None
    analista_nombre: str | None = None
    plan: str | None
    fecha_inicio: date | None
    fecha_fin: date | None
    estado: EstadoPoliza
    datos_ramo: dict
    notas: str | None
    activo: bool
    created_at: datetime
    updated_at: datetime
    asegurados: list[PolizaAseguradoResponse] = []

    model_config = {"from_attributes": True}

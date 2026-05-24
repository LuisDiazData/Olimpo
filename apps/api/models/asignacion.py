"""
Modelos Pydantic para asignaciones de agentes a analistas y coberturas de vacaciones.
"""

from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

from models.usuario import RamoUsuario


# ---------------------------------------------------------------------------
# Asignacion
# ---------------------------------------------------------------------------

class AsignacionCreate(BaseModel):
    agente_id: UUID
    ramo: RamoUsuario
    analista_id: UUID
    notas: str | None = Field(default=None, max_length=500)


class AsignacionResponse(BaseModel):
    id: UUID
    agente_id: UUID
    ramo: RamoUsuario
    analista_id: UUID
    notas: str | None
    asignado_por: UUID | None
    activo: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ResolverAsignacionResponse(BaseModel):
    """Respuesta de GET /asignaciones/resolver — resultado de resolver_analista_asignacion()."""

    agente_id: UUID
    ramo: RamoUsuario
    fecha: date
    analista_id: UUID | None = None
    requiere_atencion: bool

    @model_validator(mode="after")
    def set_requiere_atencion(self) -> "ResolverAsignacionResponse":
        self.requiere_atencion = self.analista_id is None
        return self


# ---------------------------------------------------------------------------
# Cobertura de vacaciones
# ---------------------------------------------------------------------------

class CoberturaVacacionesCreate(BaseModel):
    analista_ausente_id: UUID
    analista_cobertura_id: UUID
    fecha_inicio: date
    fecha_fin: date
    notas: str | None = Field(default=None, max_length=500)

    @model_validator(mode="after")
    def validar_fechas(self) -> "CoberturaVacacionesCreate":
        if self.fecha_fin < self.fecha_inicio:
            raise ValueError("fecha_fin no puede ser anterior a fecha_inicio.")
        if self.analista_ausente_id == self.analista_cobertura_id:
            raise ValueError("Un analista no puede cubrirse a sí mismo.")
        return self


class CoberturaVacacionesResponse(BaseModel):
    id: UUID
    analista_ausente_id: UUID
    analista_cobertura_id: UUID
    ramo: RamoUsuario
    fecha_inicio: date
    fecha_fin: date
    notas: str | None
    creado_por: UUID | None
    activa: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}

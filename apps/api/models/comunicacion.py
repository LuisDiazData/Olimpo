"""
Modelos Pydantic para el módulo de comunicaciones.

Una comunicación es un registro de contacto informal (WhatsApp, teléfono, presencial)
entre un miembro del equipo (analista, gerente, director) y un agente o asistente.
"""

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class MedioComunicacion(StrEnum):
    whatsapp = "whatsapp"
    telefono = "telefono"
    presencial = "presencial"


# ---------------------------------------------------------------------------
# Modelos de entrada (requests)
# ---------------------------------------------------------------------------

class ComunicacionCreate(BaseModel):
    """Payload para crear una comunicación."""

    medio: MedioComunicacion
    nota: str = Field(min_length=1, max_length=2000)
    tramite_id: UUID | None = Field(
        default=None,
        description="UUID del trámite vinculado. Si no hay trámite aún, omitir.",
    )
    agente_id: UUID | None = Field(
        default=None,
        description="UUID del agente. Requerido si no hay tramite_id.",
    )
    comunicacion_origen_id: UUID | None = Field(
        default=None,
        description="UUID de la comunicación a la que esta responde (hilo).",
    )
    tramite_generado_id: UUID | None = Field(
        default=None,
        description="UUID del trámite que se creó a raíz de esta comunicación.",
    )
    comunicacion_entrante: bool = Field(
        default=False,
        description="TRUE = el agente contactó al analista. FALSE = el analista inició.",
    )
    requiere_seguimiento: bool = Field(default=False)


class ComunicacionUpdate(BaseModel):
    """Payload para actualizar una comunicación existente (solo el autor)."""

    nota: str | None = Field(default=None, min_length=1, max_length=2000)
    requiere_seguimiento: bool | None = None
    comunicacion_entrante: bool | None = None


# ---------------------------------------------------------------------------
# Modelos de respuesta
# ---------------------------------------------------------------------------

class ComunicacionResponse(BaseModel):
    """Una comunicación con todos sus datos."""

    id: UUID
    medio: MedioComunicacion
    nota: str
    tramite_id: UUID | None
    agente_id: UUID | None
    comunicacion_origen_id: UUID | None
    tramite_generado_id: UUID | None
    comunicacion_entrante: bool
    requiere_seguimiento: bool
    usuario_id: UUID
    usuario_nombre: str | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ComunicacionListItem(BaseModel):
    """Vista compacta para listados."""

    id: UUID
    medio: MedioComunicacion
    nota: str
    tramite_id: UUID | None
    tramite_folio: str | None = None
    agente_id: UUID | None
    agente_nombre: str | None = None
    comunicacion_entrante: bool
    requiere_seguimiento: bool
    created_at: datetime

    model_config = {"from_attributes": True}


class MarcarSeguimientoMultiple(BaseModel):
    """Payload para marcar/desmarcar seguimiento en múltiples comunicaciones."""

    comunicacion_ids: list[UUID] = Field(
        min_length=1,
        max_length=50,
        description="Lista de IDs de comunicaciones a actualizar.",
    )
    requiere_seguimiento: bool = Field(
        default=True,
        description="TRUE = marcar seguimiento, FALSE = quitarlo.",
    )

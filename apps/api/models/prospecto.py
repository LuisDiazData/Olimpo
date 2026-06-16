from enum import Enum
from pydantic import BaseModel, ConfigDict, EmailStr, Field
from uuid import UUID
from datetime import datetime

class EstadoProspecto(str, Enum):
    entrevista = "entrevista"
    evaluacion_gnp = "evaluacion_gnp"
    examenes_cnsf = "examenes_cnsf"
    certificacion_gnp = "certificacion_gnp"
    aprobado = "aprobado"
    rechazado = "rechazado"

class ProspectoBase(BaseModel):
    nombre: str = Field(..., min_length=1, max_length=255)
    email: EmailStr
    telefono: str | None = None
    origen: str | None = None
    notas: str | None = None

class ProspectoCreate(ProspectoBase):
    pass

class ProspectoUpdateStatus(BaseModel):
    estado: EstadoProspecto

class ProspectoResponse(ProspectoBase):
    id: UUID
    estado: EstadoProspecto
    reclutador_id: UUID | None = None
    agente_creado_id: UUID | None = None
    created_at: datetime
    updated_at: datetime
    
    model_config = ConfigDict(from_attributes=True)

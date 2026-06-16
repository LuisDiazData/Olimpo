from enum import Enum
from pydantic import BaseModel, ConfigDict
from uuid import UUID
from datetime import datetime

class EstadoCampana(str, Enum):
    borrador = "borrador"
    enviando = "enviando"
    completada = "completada"

class EstadoEnvio(str, Enum):
    pendiente = "pendiente"
    enviado = "enviado"
    error = "error"

class CampanaCreate(BaseModel):
    titulo: str
    asunto: str
    cuerpo_html: str
    ramo_objetivo: str | None = None

class CampanaResponse(BaseModel):
    id: UUID
    titulo: str
    asunto: str
    cuerpo_html: str
    ramo_objetivo: str | None
    estado: EstadoCampana
    created_by: UUID
    created_at: datetime
    updated_at: datetime
    
    # Métricas agregadas (opcional)
    total_destinatarios: int = 0
    total_enviados: int = 0
    total_aperturas: int = 0

    model_config = ConfigDict(from_attributes=True)

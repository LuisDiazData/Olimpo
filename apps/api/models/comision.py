from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, Field

class EstadoComision(StrEnum):
    pendiente = "pendiente"
    procesando = "procesando"
    procesado = "procesado"
    error = "error"

# ---------------------------------------------------------------------------
# Estado Cuenta
# ---------------------------------------------------------------------------

class EstadoCuentaCreate(BaseModel):
    aseguradora_id: str
    fecha_corte: date
    archivo_url: str
    monto_total: Decimal = Decimal("0.0")
    moneda: str = "MXN"

class EstadoCuentaResponse(BaseModel):
    id: UUID
    aseguradora_id: str
    fecha_corte: date
    archivo_url: str
    estado: EstadoComision
    monto_total: Decimal
    moneda: str
    procesado_por: UUID | None
    creado_en: datetime
    actualizado_en: datetime

    model_config = {"from_attributes": True}

# ---------------------------------------------------------------------------
# Recibo Comision
# ---------------------------------------------------------------------------

class ReciboComisionResponse(BaseModel):
    id: UUID
    estado_cuenta_id: UUID
    poliza_id: UUID | None
    numero_poliza_texto: str
    numero_recibo: str | None
    fecha_pago: date | None
    prima_pagada: Decimal
    comision_total: Decimal
    comision_agente: Decimal
    comision_promotoria: Decimal
    es_estorno: bool
    moneda: str
    creado_en: datetime

    model_config = {"from_attributes": True}

# ---------------------------------------------------------------------------
# Splits & Bonos
# ---------------------------------------------------------------------------

class SplitReglaCreate(BaseModel):
    agente_id: UUID
    ramo: str
    porcentaje_agente: Decimal = Field(ge=0, le=100)

class SplitReglaResponse(BaseModel):
    id: UUID
    agente_id: UUID
    ramo: str
    porcentaje_agente: Decimal

    model_config = {"from_attributes": True}

class BonoMetaResponse(BaseModel):
    id: UUID
    agente_id: UUID
    ramo: str
    anio: int
    trimestre: int | None
    meta_prima: Decimal
    bono_ofrecido: Decimal

    model_config = {"from_attributes": True}

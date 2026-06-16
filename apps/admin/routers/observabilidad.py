"""
Router: observabilidad de los agentes IA en el panel Superadmin.
"""

from datetime import datetime, timedelta
from typing import List, Optional
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from core.auth import require_superadmin
from core.database import get_admin_db

log = structlog.get_logger(__name__)

router = APIRouter(
    prefix="/observabilidad",
    tags=["Observabilidad"],
    dependencies=[Depends(require_superadmin)],
)

# =============================================================================
# MODELOS
# =============================================================================

class AgentStatus(BaseModel):
    nombre: str = Field(description="Nombre del agente (ej. agente_1)")
    estado: str = Field(description="'idle' o 'procesando'")
    tramites_activos: int = Field(description="Cantidad de trámites en proceso actual por este agente")

class MetricasAgente(BaseModel):
    nombre: str
    eventos_24h: int
    tasa_exito_estimada: float = 100.0

class ObservabilidadEstadoResponse(BaseModel):
    agentes: List[AgentStatus]

class ObservabilidadMetricasResponse(BaseModel):
    metricas: List[MetricasAgente]

class EventoFeed(BaseModel):
    id: UUID
    tramite_id: UUID
    tipo_evento: str
    agente_ia_nombre: str
    descripcion: str
    created_at: datetime
    datos: dict | None = None

class ObservabilidadFeedResponse(BaseModel):
    eventos: List[EventoFeed]


# =============================================================================
# ENDPOINTS
# =============================================================================

@router.get("/estado-actual", response_model=ObservabilidadEstadoResponse)
def obtener_estado_actual():
    """
    Retorna el estado en vivo de los agentes consultando qué paso del pipeline 
    se está ejecutando en los trámites.
    """
    db = get_admin_db()

    # Consultar tramites que están en el pipeline
    tramites_en_proceso = (
        db.table("tramite")
        .select("paso_pipeline_actual")
        .not_.is_("paso_pipeline_actual", "null")
        .execute()
        .data
    )

    # Mapeo simple de pasos a agentes (agente_1..6)
    conteo_agentes = {f"agente_{i}": 0 for i in range(1, 7)}
    
    for t in tramites_en_proceso:
        paso = t.get("paso_pipeline_actual")
        if paso == "ingesta":
            conteo_agentes["agente_1"] += 1
        elif paso == "clasificacion":
            conteo_agentes["agente_2"] += 1
        elif paso == "extraccion":
            conteo_agentes["agente_3"] += 1
        elif paso == "validacion":
            conteo_agentes["agente_4"] += 1
        elif paso == "reglas_negocio":
            conteo_agentes["agente_5"] += 1
        elif paso == "resolucion":
            conteo_agentes["agente_6"] += 1

    agentes = []
    for nombre, activos in conteo_agentes.items():
        estado = "procesando" if activos > 0 else "idle"
        agentes.append(AgentStatus(nombre=nombre, estado=estado, tramites_activos=activos))

    return ObservabilidadEstadoResponse(agentes=agentes)


@router.get("/metricas", response_model=ObservabilidadMetricasResponse)
def obtener_metricas():
    """
    Retorna métricas de volumen para cada agente en las últimas 24 horas.
    """
    db = get_admin_db()
    hace_24h = (datetime.utcnow() - timedelta(hours=24)).isoformat()

    eventos = (
        db.table("tramite_evento")
        .select("agente_ia_nombre")
        .not_.is_("agente_ia_nombre", "null")
        .gte("created_at", hace_24h)
        .execute()
        .data
    )

    conteo = {f"agente_{i}": 0 for i in range(1, 7)}
    for e in eventos:
        agente = e.get("agente_ia_nombre")
        if agente in conteo:
            conteo[agente] += 1

    metricas = []
    for nombre, cantidad in conteo.items():
        metricas.append(MetricasAgente(nombre=nombre, eventos_24h=cantidad))

    return ObservabilidadMetricasResponse(metricas=metricas)


@router.get("/feed", response_model=ObservabilidadFeedResponse)
def obtener_feed():
    """
    Devuelve los últimos 50 eventos generados por agentes IA para el live feed.
    """
    db = get_admin_db()
    
    eventos = (
        db.table("tramite_evento")
        .select("id, tramite_id, tipo_evento, agente_ia_nombre, descripcion, created_at, datos")
        .not_.is_("agente_ia_nombre", "null")
        .order("created_at", desc=True)
        .limit(50)
        .execute()
        .data
    )

    items = []
    for e in eventos:
        try:
            items.append(EventoFeed(
                id=e["id"],
                tramite_id=e["tramite_id"],
                tipo_evento=e["tipo_evento"],
                agente_ia_nombre=e["agente_ia_nombre"],
                descripcion=e["descripcion"] or "Acción completada",
                created_at=datetime.fromisoformat(e["created_at"].replace("Z", "+00:00")),
                datos=e.get("datos")
            ))
        except Exception as exc:
            log.warning("error_parseo_evento", evento_id=e.get("id"), error=str(exc))
            continue

    return ObservabilidadFeedResponse(eventos=items)

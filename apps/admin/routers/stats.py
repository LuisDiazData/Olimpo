"""
Router: estadísticas del panel Superadmin.

Endpoints:
  GET /stats — KPIs del dashboard: totales por estado de licencia y últimas altas
"""

from datetime import date, datetime, timedelta
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from core.auth import require_superadmin
from core.database import get_admin_db

log = structlog.get_logger(__name__)

router = APIRouter(
    prefix="/stats",
    tags=["Stats"],
    dependencies=[Depends(require_superadmin)],
)


# =============================================================================
# MODELOS
# =============================================================================

class UltimaAltaItem(BaseModel):
    id: UUID
    nombre: str
    subdominio: str
    estado_licencia: str
    created_at: datetime


class StatsResponse(BaseModel):
    total_promotorias: int = Field(description="Total de tenants registrados")
    activas: int = Field(description="Tenants con licencia activa")
    suspendidas: int = Field(description="Tenants con licencia suspendida")
    en_prueba: int = Field(description="Tenants en periodo de prueba")
    expiradas: int = Field(description="Tenants con licencia expirada")
    venciendo_30_dias: int = Field(description="Tenants cuya licencia vence en los próximos 30 días")
    ultimas_altas: list[UltimaAltaItem] = Field(description="Los 5 tenants más recientes")


# =============================================================================
# ENDPOINTS
# =============================================================================

@router.get("", response_model=StatsResponse)
def obtener_stats():
    """
    Devuelve KPIs para el dashboard del panel Superadmin:
    conteos por estado de licencia y últimas altas.
    """
    db = get_admin_db()

    todos = db.table("tenant").select(
        "id, nombre, subdominio, estado_licencia, fecha_vencimiento_licencia, created_at"
    ).order("created_at", desc=True).execute().data

    limite_30 = date.today() + timedelta(days=30)

    activas = 0
    suspendidas = 0
    en_prueba = 0
    expiradas = 0
    venciendo_30_dias = 0

    for t in todos:
        estado = t.get("estado_licencia", "prueba")
        if estado == "activa":
            activas += 1
        elif estado == "suspendida":
            suspendidas += 1
        elif estado == "prueba":
            en_prueba += 1
        elif estado == "expirada":
            expiradas += 1

        if estado in ("activa", "prueba") and t.get("fecha_vencimiento_licencia"):
            try:
                fv = date.fromisoformat(t["fecha_vencimiento_licencia"])
                if fv <= limite_30:
                    venciendo_30_dias += 1
            except ValueError:
                pass

    ultimas = [
        UltimaAltaItem(
            id=t["id"],
            nombre=t["nombre"],
            subdominio=t["subdominio"],
            estado_licencia=t["estado_licencia"],
            created_at=t["created_at"],
        )
        for t in todos[:5]
    ]

    return StatsResponse(
        total_promotorias=len(todos),
        activas=activas,
        suspendidas=suspendidas,
        en_prueba=en_prueba,
        expiradas=expiradas,
        venciendo_30_dias=venciendo_30_dias,
        ultimas_altas=ultimas,
    )

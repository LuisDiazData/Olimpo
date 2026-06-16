"""
Router de BI Comercial del CRM Olimpo.
Provee endpoints analíticos y financieros para Dashboards.
"""
from typing import Any
import datetime

import structlog
from fastapi import APIRouter, Depends, Query
from supabase import Client

from core.auth import require_roles
from core.database import get_db
from models.usuario import RolUsuario

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/bi", tags=["bi"])

_ROLES_PERMITIDOS = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))]

@router.get("/resumen", dependencies=_ROLES_PERMITIDOS)
def obtener_resumen_bi(
    mes: int | None = Query(default=None, ge=1, le=12),
    anio: int | None = Query(default=None, ge=2020),
    db: Client = Depends(get_db),
) -> Any:
    """
    Obtiene las métricas principales del dashboard comercial para un mes y año específicos.
    Utiliza una función RPC optimizada en la base de datos PostgreSQL.
    Solo visible para Gerentes y Directores.
    """
    # Default = mes/año actual, calculado por request (no al importar el módulo).
    ahora = datetime.datetime.now()
    mes = mes or ahora.month
    anio = anio or ahora.year
    try:
        # Llamar a la función RPC de Supabase
        result = db.rpc("get_bi_dashboard_stats", {"p_mes": mes, "p_anio": anio}).execute()
        return result.data
    except Exception as exc:
        log.error("error_get_bi_resumen", error=str(exc))
        return {
            "totales_por_moneda": [],
            "top_agentes": [],
            "top_analistas": []
        }

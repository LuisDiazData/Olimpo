"""
Clase base para los agentes de IA de Olimpo.

Todos los agentes del pipeline (1 a 6) deben heredar de esta clase base
para compartir el cliente de IA centralizado, la conexión a la base de datos
y el registro de observabilidad (Langfuse/Logfire).
"""

import sys
import os
from typing import Any

# Asegurar que el path del backend esté disponible para importaciones desde packages/
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../../apps/api")))

import structlog
from core.llm_client import get_ia_client, IAClient
from core.database import get_admin_db

log = structlog.get_logger(__name__)


class BaseAgent:
    def __init__(self, name: str) -> None:
        self.name = name
        self.ia_client: IAClient = get_ia_client()
        self.db = get_admin_db()
        self.log = log.bind(agent_name=name)

    async def registrar_ejecucion(
        self,
        tramite_id: str,
        estado: str,
        duracion_ms: int = 0,
        modelo_llm: str | None = None,
        costo_usd: float = 0.0,
        error: str | None = None,
    ) -> None:
        """Registra la ejecución del agente en la tabla de auditoría `agente_ia_log`."""
        try:
            self.db.table("agente_ia_log").insert({
                "agente_nombre": self.name,
                "tramite_id": tramite_id,
                "estado": estado,
                "duracion_ms": duracion_ms,
                "modelo_llm": modelo_llm,
                "costo_usd": costo_usd,
                "error": error,
            }).execute()
        except Exception as exc:
            self.log.error("error_registrar_ejecucion_log", error=str(exc))

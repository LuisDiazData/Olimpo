"""
Router de Observabilidad de Agentes IA del CRM Olimpo.
Proporciona endpoints para monitorear la salud de Celery y los eventos de la IA.
"""
from typing import Any

import structlog
from fastapi import APIRouter, Depends
from supabase import Client

from core.auth import require_roles
from core.database import get_db
from models.usuario import RolUsuario
from celery_app import celery_app

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/observabilidad", tags=["observabilidad"])

# Visible solo para directores (que asumen el rol de Admin también en este contexto)
_ROLES_PERMITIDOS = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))]

@router.get("/estado", dependencies=_ROLES_PERMITIDOS)
def obtener_estado_motor() -> Any:
    """Verifica el estado de los workers de Celery."""
    try:
        inspector = celery_app.control.inspect()
        ping_res = inspector.ping()
        active_tasks = inspector.active()
        reserved_tasks = inspector.reserved()
        
        is_online = bool(ping_res)
        
        total_active = sum(len(tasks) for tasks in (active_tasks or {}).values())
        total_reserved = sum(len(tasks) for tasks in (reserved_tasks or {}).values())
        
        workers = []
        if ping_res:
            for worker_name, ping in ping_res.items():
                workers.append({
                    "nombre": worker_name,
                    "estado": "ONLINE" if ping.get("ok") == "pong" else "DEGRADED",
                    "tareas_activas": len(active_tasks.get(worker_name, []) if active_tasks else []),
                    "tareas_encoladas": len(reserved_tasks.get(worker_name, []) if reserved_tasks else [])
                })
                
        return {
            "status": "ONLINE" if is_online else "OFFLINE",
            "total_active_tasks": total_active,
            "total_queued_tasks": total_reserved,
            "workers": workers
        }
    except Exception as exc:
        log.error("error_observabilidad_celery", error=str(exc))
        return {
            "status": "OFFLINE",
            "total_active_tasks": 0,
            "total_queued_tasks": 0,
            "workers": [],
            "error": "No se pudo conectar con el motor de IA."
        }

@router.get("/eventos", dependencies=_ROLES_PERMITIDOS)
def obtener_eventos_ia(db: Client = Depends(get_db)) -> Any:
    """Obtiene los últimos eventos generados por los Agentes IA."""
    # En una arquitectura real se recomienda usar Sentry o una tabla fallos_ia dedicada.
    # Por ahora usamos tramite_evento.
    result = (
        db.table("tramite_evento")
        .select("id, tramite_id, estado_anterior, estado_nuevo, descripcion, agente_ia_nombre, created_at")
        .not_.is_("agente_ia_nombre", "null")
        .order("created_at", desc=True)
        .limit(50)
        .execute()
    )
    
    eventos = result.data or []
    
    # Procesamiento simple en memoria para detectar si fue un "error" 
    # (Ej. si la descripción contiene palabras clave de fallo)
    for ev in eventos:
        desc = (ev.get("descripcion") or "").lower()
        ev["es_error"] = "error" in desc or "fallo" in desc or "exception" in desc
        
    return eventos

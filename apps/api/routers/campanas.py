"""
Router de Campañas Masivas (Marketing) del CRM Olimpo.
"""
from typing import Any
from uuid import UUID
from datetime import datetime, timezone
import base64

import structlog
from fastapi import APIRouter, Depends, HTTPException, Response, status
from supabase import Client

from core.auth import require_roles
from core.database import get_db, get_admin_db
from models.usuario import RolUsuario, UsuarioToken
from models.campana import CampanaCreate, CampanaResponse
from celery_app import celery_app

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/campanas", tags=["campanas"])

_ROLES_PERMITIDOS = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))]

@router.get("", response_model=list[CampanaResponse], dependencies=_ROLES_PERMITIDOS)
def listar_campanas(db: Client = Depends(get_db)) -> Any:
    """Lista todas las campañas con sus métricas básicas."""
    result = db.table("campana").select("*").order("created_at", desc=True).execute()
    
    # En un escenario real, las métricas se obtendrían con un JOIN/RPC
    # Por ahora devolvemos la tabla base
    return [CampanaResponse.model_validate(c) for c in result.data]

@router.post("", response_model=CampanaResponse, status_code=status.HTTP_201_CREATED)
def crear_campana(
    body: CampanaCreate,
    caller: UsuarioToken = Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente)),
    db: Client = Depends(get_db),
) -> Any:
    """Crea una campaña nueva en estado borrador."""
    payload = body.model_dump(exclude_none=True)
    payload["created_by"] = str(caller.id)
    
    result = db.table("campana").insert(payload).execute()
    if not result.data:
        raise HTTPException(status_code=500, detail="Error al crear la campaña")
        
    return CampanaResponse.model_validate(result.data[0])

@router.post("/{campana_id}/enviar", status_code=status.HTTP_202_ACCEPTED, dependencies=_ROLES_PERMITIDOS)
def enviar_campana(campana_id: UUID, db: Client = Depends(get_db)) -> dict:
    """Detona el envío masivo en background vía Celery (solo campañas en borrador)."""
    res = db.table("campana").select("id, estado").eq("id", str(campana_id)).maybe_single().execute()
    if not res.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Campaña no encontrada.")
    if res.data["estado"] != "borrador":
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"La campaña no se puede enviar en estado '{res.data['estado']}'.",
        )

    db.table("campana").update({"estado": "enviando"}).eq("id", str(campana_id)).execute()

    celery_app.send_task(
        "agentes.agente_7_marketing.ejecutar_campana",
        kwargs={"campana_id": str(campana_id)},
        queue="procesamiento",
    )

    return {"mensaje": "Campaña encolada para envío masivo."}

# ENDPOINT PÚBLICO - Pixel de Tracking
@router.get("/track/{destinatario_id}.png")
def tracking_pixel(destinatario_id: UUID) -> Response:
    """
    Endpoint público embebido en el HTML del correo.
    Retorna un pixel transparente 1x1 y marca el correo como abierto.
    """
    db = get_admin_db()  # Usamos service_role porque es público
    try:
        ahora = datetime.now(timezone.utc).isoformat()
        db.table("campana_destinatario").update({"fecha_apertura": ahora}).eq("id", str(destinatario_id)).is_("fecha_apertura", "null").execute()
    except Exception as exc:
        log.error("error_tracking_pixel", error=str(exc))
        
    # 1x1 transparent PNG Base64
    pixel_b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
    pixel_data = base64.b64decode(pixel_b64)
    
    return Response(content=pixel_data, media_type="image/png", headers={"Cache-Control": "no-cache, no-store, must-revalidate"})

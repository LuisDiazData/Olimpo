"""
Router de prospectos (Reclutamiento) del CRM Olimpo.
"""
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from core.auth import require_roles
from core.database import get_db
from models.usuario import RolUsuario, UsuarioToken
from models.prospecto import ProspectoCreate, ProspectoResponse, ProspectoUpdateStatus

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/prospectos", tags=["prospectos"])

# Solo Gerentes y Directores pueden gestionar el reclutamiento
_ROLES_PERMITIDOS = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))]

@router.get("", response_model=list[ProspectoResponse], dependencies=_ROLES_PERMITIDOS)
def listar_prospectos(
    db: Client = Depends(get_db),
) -> list[ProspectoResponse]:
    """Lista todos los prospectos en el embudo (tablero Kanban)."""
    result = db.table("prospecto").select("*").order("created_at").execute()
    return [ProspectoResponse.model_validate(p) for p in result.data]

@router.post("", response_model=ProspectoResponse, status_code=status.HTTP_201_CREATED)
def crear_prospecto(
    body: ProspectoCreate,
    caller: UsuarioToken = Depends(
        require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente)
    ),
    db: Client = Depends(get_db),
) -> ProspectoResponse:
    """Crea un nuevo prospecto en la primera etapa (Entrevista)."""
    payload = body.model_dump(exclude_none=True)
    payload["reclutador_id"] = str(caller.id)
    
    result = db.table("prospecto").insert(payload).execute()
    if not result.data:
        raise HTTPException(status_code=500, detail="Error al crear el prospecto")
        
    log.info("prospecto_creado", id=result.data[0]["id"], reclutador_id=str(caller.id))
    return ProspectoResponse.model_validate(result.data[0])

@router.patch("/{prospecto_id}/estado", response_model=ProspectoResponse, dependencies=_ROLES_PERMITIDOS)
def actualizar_estado_prospecto(
    prospecto_id: UUID,
    body: ProspectoUpdateStatus,
    db: Client = Depends(get_db),
) -> ProspectoResponse:
    """Actualiza el estado del prospecto (arrastrar y soltar en Kanban)."""
    result = db.table("prospecto").update({"estado": body.estado.value}).eq("id", str(prospecto_id)).execute()
    
    if not result.data:
        raise HTTPException(status_code=404, detail="Prospecto no encontrado")
        
    log.info("estado_prospecto_actualizado", prospecto_id=str(prospecto_id), nuevo_estado=body.estado.value)
    return ProspectoResponse.model_validate(result.data[0])

"""
Router: comunicaciones informales (WhatsApp, teléfono, presencial).

Las comunicaciones se registran para mantener un historial completo del contacto
entre el equipo y los agentes/asistentes, más allá del correo.

GET    /comunicaciones                          — listar con filtros
POST   /comunicaciones                          — crear comunicación
GET    /comunicaciones/{id}                    — detalle de una comunicación
PATCH  /comunicaciones/{id}                    — actualizar (solo autor)
DELETE /comunicaciones/{id}                    — eliminar (solo autor, soft-delete)
POST   /comunicaciones/marcar-seguimiento       — bulk: marcar seguimiento en varias

Filtros comunes:
  ?tramite_id=...     — comunicaciones de un trámite
  ?agente_id=...      — comunicaciones con un agente
  ?usuario_id=...     — comunicaciones registradas por un analista
  ?medio=...          — whatsapp | telefono | presencial
  ?requiere_seguimiento=true  — solo las que necesitan atención
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from pydantic import ValidationError

from core.auth import get_current_user
from core.database import get_db
from models.comunicacion import (
    ComunicacionCreate,
    ComunicacionListItem,
    ComunicacionResponse,
    ComunicacionUpdate,
    MarcarSeguimientoMultiple,
)
from models.usuario import UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/comunicaciones", tags=["comunicaciones"])


# =============================================================================
# HELPERS
# =============================================================================

def _get_comunicacion_o_404(db, comunicacion_id: UUID) -> dict:
    result = db.table("comunicacion").select("*").eq(
        "id", str(comunicacion_id)
    ).maybe_single().execute()
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "error_code": "COMUNICACION_NO_ENCONTRADA",
                "mensaje": "Comunicación no encontrada.",
            },
        )
    return result.data


def _join_comunicacion(com: dict) -> dict:
    """Agrega nombres de usuario y trámite a una comunicación."""
    return com


# =============================================================================
# GET /comunicaciones
# =============================================================================

@router.get("", response_model=list[ComunicacionListItem])
def listar_comunicaciones(
    tramite_id: UUID | None = Query(default=None, description="Filtrar por trámite"),
    agente_id: UUID | None = Query(default=None, description="Filtrar por agente"),
    usuario_id: UUID | None = Query(default=None, description="Filtrar por autor"),
    medio: str | None = Query(default=None, description="whatsapp | telefono | presencial"),
    requiere_seguimiento: bool | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db=Depends(get_db),
    usuario_actual: UsuarioToken = Depends(get_current_user),
) -> list[ComunicacionListItem]:
    """
    Lista comunicaciones con filtros. Visible para todo el equipo.
    """
    query = db.table("comunicacion").select(
        "id, medio, nota, tramite_id, agente_id, "
        "comunicacion_entrante, requiere_seguimiento, created_at"
    ).eq("eliminado", False)

    if tramite_id:
        query = query.eq("tramite_id", str(tramite_id))
    if agente_id:
        query = query.eq("agente_id", str(agente_id))
    if usuario_id:
        query = query.eq("usuario_id", str(usuario_id))
    if medio:
        query = query.eq("medio", medio)
    if requiere_seguimiento is not None:
        query = query.eq("requiere_seguimiento", requiere_seguimiento)

    result = query.order("created_at", desc=True).range(offset, offset + limit - 1).execute()

    items = []
    for com in (result.data or []):
        item = dict(com)
        item["tramite_folio"] = None
        if item.get("tramite_id"):
            t = db.table("tramite").select("folio").eq("id", item["tramite_id"]).maybe_single().execute()
            if t.data:
                item["tramite_folio"] = t.data["folio"]
        item["agente_nombre"] = None
        if item.get("agente_id"):
            a = db.table("agente").select("nombre").eq("id", item["agente_id"]).maybe_single().execute()
            if a.data:
                item["agente_nombre"] = a.data["nombre"]
        items.append(ComunicacionListItem.model_validate(item))

    return items


# =============================================================================
# POST /comunicaciones
# =============================================================================

@router.post(
    "",
    response_model=ComunicacionResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Registrar comunicación",
    description=(
        "Registra una comunicación informal (WhatsApp, teléfono, presencial) "
        "entre el analista y un agente o asistente. "
        "Si no hay trámite aún, usar solo agente_id. "
        "El campo tramite_generado_id es opcional — indica que de esta "
        "comunicación surgió un trámite que se creó después."
    ),
)
def crear_comunicacion(
    body: ComunicacionCreate,
    db=Depends(get_db),
    usuario: UsuarioToken = Depends(get_current_user),
) -> ComunicacionResponse:
    """Crea una nueva comunicación."""
    payload: dict = {
        "medio": body.medio.value,
        "nota": body.nota,
        "comunicacion_entrante": body.comunicacion_entrante,
        "requiere_seguimiento": body.requiere_seguimiento,
        "usuario_id": str(usuario.id),
    }

    if body.tramite_id:
        payload["tramite_id"] = str(body.tramite_id)
    if body.agente_id:
        payload["agente_id"] = str(body.agente_id)
    if body.comunicacion_origen_id:
        payload["comunicacion_origen_id"] = str(body.comunicacion_origen_id)
    if body.tramite_generado_id:
        payload["tramite_generado_id"] = str(body.tramite_generado_id)

    result = db.table("comunicacion").insert(payload).execute()
    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error_code": "ERROR_DB", "mensaje": "No se pudo crear la comunicación."},
        )

    com = result.data[0]
    log.info(
        "comunicacion_creada",
        comunicacion_id=com["id"],
        medio=body.medio.value,
        tramite_id=str(body.tramite_id) if body.tramite_id else None,
        agente_id=str(body.agente_id) if body.agente_id else None,
        por=str(usuario.id),
    )

    return _enriquecer_comunicacion(com, db)


# =============================================================================
# GET /comunicaciones/{id}
# =============================================================================

@router.get("/{comunicacion_id}", response_model=ComunicacionResponse)
def obtener_comunicacion(
    comunicacion_id: UUID,
    db=Depends(get_db),
    usuario: UsuarioToken = Depends(get_current_user),
) -> ComunicacionResponse:
    """Detalle de una comunicación."""
    com = _get_comunicacion_o_404(db, comunicacion_id)
    if com.get("eliminado"):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "COMUNICACION_NO_ENCONTRADA", "mensaje": "Comunicación no encontrada."},
        )
    return _enriquecer_comunicacion(com, db)


# =============================================================================
# PATCH /comunicaciones/{id}
# =============================================================================

@router.patch("/{comunicacion_id}", response_model=ComunicacionResponse)
def actualizar_comunicacion(
    comunicacion_id: UUID,
    body: ComunicacionUpdate,
    db=Depends(get_db),
    usuario: UsuarioToken = Depends(get_current_user),
) -> ComunicacionResponse:
    """
    Actualiza una comunicación existente. Solo el autor puede actualizarla.
    """
    com = _get_comunicacion_o_404(db, comunicacion_id)

    if com["usuario_id"] != str(usuario.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "error_code": "NO_AUTOR",
                "mensaje": "Solo el autor puede editar esta comunicación.",
            },
        )

    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"error_code": "SIN_CAMBIOS", "mensaje": "No hay campos para actualizar."},
        )

    db.table("comunicacion").update(cambios).eq("id", str(comunicacion_id)).execute()

    com_actualizada = _get_comunicacion_o_404(db, comunicacion_id)
    log.info(
        "comunicacion_actualizada",
        comunicacion_id=str(comunicacion_id),
        cambios=list(cambios.keys()),
        por=str(usuario.id),
    )

    return _enriquecer_comunicacion(com_actualizada, db)


# =============================================================================
# DELETE /comunicaciones/{id}
# =============================================================================

@router.delete("/{comunicacion_id}", status_code=status.HTTP_200_OK)
def eliminar_comunicacion(
    comunicacion_id: UUID,
    db=Depends(get_db),
    usuario: UsuarioToken = Depends(get_current_user),
) -> dict:
    """
    Elimina una comunicación (soft-delete). Solo el autor puede eliminarla.
    """
    com = _get_comunicacion_o_404(db, comunicacion_id)

    if com["usuario_id"] != str(usuario.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "error_code": "NO_AUTOR",
                "mensaje": "Solo el autor puede eliminar esta comunicación.",
            },
        )

    db.table("comunicacion").update({"eliminado": True}).eq("id", str(comunicacion_id)).execute()

    log.info(
        "comunicacion_eliminada",
        comunicacion_id=str(comunicacion_id),
        por=str(usuario.id),
    )

    return {"mensaje": "Comunicación eliminada."}


# =============================================================================
# POST /comunicaciones/marcar-seguimiento
# =============================================================================

@router.post(
    "/marcar-seguimiento",
    status_code=status.HTTP_200_OK,
    summary="Marcar seguimiento en masa",
    description=(
        "Marca o desmarca seguimiento en una lista de comunicaciones. "
        "Útil después de una sesión de llamadas para marcar como atendidas."
    ),
)
def marcar_seguimiento_multiple(
    body: MarcarSeguimientoMultiple,
    db=Depends(get_db),
    usuario: UsuarioToken = Depends(get_current_user),
) -> dict:
    """Marca/desmarca seguimiento en varias comunicaciones."""
    ids_str = [str(id) for id in body.comunicacion_ids]

    db.table("comunicacion").update(
        {"requiere_seguimiento": body.requiere_seguimiento}
    ).in_("id", ids_str).execute()

    log.info(
        "comunicaciones_marcar_seguimiento",
        cantidad=len(ids_str),
        requiere_seguimiento=body.requiere_seguimiento,
        por=str(usuario.id),
    )

    return {
        "mensaje": f"Se actualizaron {len(ids_str)} comunicaciones.",
        "actualizadas": len(ids_str),
    }


# =============================================================================
# HELPERS INTERNOS
# =============================================================================

def _enriquecer_comunicacion(com: dict, db) -> ComunicacionResponse:
    """Agrega nombres relacionados a una comunicación."""
    if com.get("usuario_id"):
        u = db.table("usuario").select("nombre").eq("id", com["usuario_id"]).maybe_single().execute()
        com["usuario_nombre"] = u.data["nombre"] if u.data else None
    return ComunicacionResponse.model_validate(com)

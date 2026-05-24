"""
Router del catÃ¡logo de agentes de seguros.

GET    /agentes                             â€” listado con bÃºsqueda y filtros
POST   /agentes                             â€” crear agente (directores + gerentes)
GET    /agentes/{id}                        â€” perfil completo con telefonos, emails, asistentes
PATCH  /agentes/{id}                        â€” actualizar datos del agente
DELETE /agentes/{id}                        â€” soft-delete

POST   /agentes/{id}/telefonos              â€” agregar telÃ©fono
PATCH  /agentes/{id}/telefonos/{tel_id}/preferente â€” marcar como preferente
DELETE /agentes/{id}/telefonos/{tel_id}     â€” eliminar telÃ©fono

POST   /agentes/{id}/emails                 â€” agregar email
PATCH  /agentes/{id}/emails/{email_id}/preferente â€” marcar como preferente
DELETE /agentes/{id}/emails/{email_id}      â€” eliminar email

POST   /agentes/{id}/asistentes             â€” agregar asistente
PATCH  /agentes/{id}/asistentes/{asist_id}  â€” actualizar asistente
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from supabase import Client

from core.auth import get_current_user, require_roles
from core.database import get_db
from models.agente import (
    AgenteCreate,
    AgenteEmailCreate,
    AgenteEmailResponse,
    AgenteListItem,
    AgenteResponse,
    AgenteUpdate,
    AsistenteCreate,
    AsistenteResponse,
    AsistenteUpdate,
    TelefonoCreate,
    TelefonoResponse,
)
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/agentes", tags=["agentes"])

_ESCRITURA = [
    Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente))
]


def _check_agente_existe(db: Client, agente_id: UUID) -> dict:
    result = db.table("agente").select("id, activo").eq("id", str(agente_id)).maybe_single().execute()
    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Agente no encontrado.")
    return result.data


# ---------------------------------------------------------------------------
# GET /agentes
# ---------------------------------------------------------------------------

@router.get("", response_model=list[AgenteListItem])
def listar_agentes(
    q: str | None = Query(default=None, description="BÃºsqueda por nombre o CUA"),
    activo: bool | None = Query(default=True),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Client = Depends(get_db),
) -> list[AgenteListItem]:
    """Lista de agentes con bÃºsqueda y filtros. Visible para todos los roles."""
    query = db.table("agente").select(
        "id, cua, nombre, nombre_comercial, rfc, fecha_afiliacion, activo, "
        "agente_email!left(email, preferente), "
        "agente_telefono!left(numero, preferente)"
    )

    if activo is not None:
        query = query.eq("activo", activo)

    if q:
        query = query.or_(f"nombre.ilike.%{q}%,cua.ilike.%{q}%")

    result = query.order("nombre").range(offset, offset + limit - 1).execute()

    items = []
    for row in result.data:
        emails = row.pop("agente_email", []) or []
        telefonos = row.pop("agente_telefono", []) or []

        email_pref = next((e["email"] for e in emails if e.get("preferente")), None)
        tel_pref = next((t["numero"] for t in telefonos if t.get("preferente")), None)

        items.append(AgenteListItem(
            **row,
            email_preferente=email_pref,
            telefono_preferente=tel_pref,
        ))

    return items


# ---------------------------------------------------------------------------
# POST /agentes
# ---------------------------------------------------------------------------

@router.post("", response_model=AgenteResponse, status_code=status.HTTP_201_CREATED, dependencies=_ESCRITURA)
def crear_agente(
    body: AgenteCreate,
    db: Client = Depends(get_db),
) -> AgenteResponse:
    try:
        result = (
            db.table("agente")
            .insert(body.model_dump(exclude_none=True))
            .select("id, cua, nombre, nombre_comercial, rfc, fecha_afiliacion, notas, activo, created_at, updated_at")
            .execute()
        )
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        if "uq_agente_cua" in str(exc):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Ya existe un agente con CUA '{body.cua}'.",
            )
        if "uq_agente_rfc" in str(exc):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"Ya existe un agente con RFC '{body.rfc}'.",
            )
        raise exc from None

    data = result.data
    data.update({"telefonos": [], "emails": [], "asistentes": []})
    log.info("agente_creado", id=data["id"], cua=body.cua)
    return AgenteResponse.model_validate(data)


# ---------------------------------------------------------------------------
# GET /agentes/{id}
# ---------------------------------------------------------------------------

@router.get("/{agente_id}", response_model=AgenteResponse)
def obtener_agente(
    agente_id: UUID,
    db: Client = Depends(get_db),
) -> AgenteResponse:
    result = (
        db.table("agente")
        .select(
            "id, cua, nombre, nombre_comercial, rfc, fecha_afiliacion, notas, activo, created_at, updated_at, "
            "agente_telefono(id, agente_id, tipo, numero, preferente, created_at), "
            "agente_email(id, agente_id, email, preferente, created_at), "
            "asistente(id, agente_id, nombre, email, telefono, activo, created_at, updated_at)"
        )
        .eq("id", str(agente_id))
        .maybe_single()
        .execute()
    )

    if not result:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Agente no encontrado.")

    data = result.data
    # Renombrar claves de join anidado a los nombres del modelo
    data["telefonos"] = data.pop("agente_telefono", []) or []
    data["emails"] = data.pop("agente_email", []) or []
    data["asistentes"] = data.pop("asistente", []) or []

    return AgenteResponse.model_validate(data)


# ---------------------------------------------------------------------------
# PATCH /agentes/{id}
# ---------------------------------------------------------------------------

@router.patch("/{agente_id}", response_model=AgenteResponse, dependencies=_ESCRITURA)
def actualizar_agente(
    agente_id: UUID,
    body: AgenteUpdate,
    db: Client = Depends(get_db),
) -> AgenteResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos para actualizar.",
        )

    _check_agente_existe(db, agente_id)

    try:
        db.table("agente").update(cambios).eq("id", str(agente_id)).execute()
    except Exception as exc:
        if "uq_agente_rfc" in str(exc):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="RFC ya registrado en otro agente.")
        raise exc from None

    return obtener_agente(agente_id, db)


# ---------------------------------------------------------------------------
# DELETE /agentes/{id} â€” soft-delete
# ---------------------------------------------------------------------------

@router.delete("/{agente_id}", status_code=status.HTTP_204_NO_CONTENT, dependencies=_ESCRITURA)
def desactivar_agente(
    agente_id: UUID,
    usuario: UsuarioToken = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> None:
    _check_agente_existe(db, agente_id)
    db.table("agente").update({"activo": False}).eq("id", str(agente_id)).execute()
    log.info("agente_desactivado", id=str(agente_id), por=str(usuario.id))


# ---------------------------------------------------------------------------
# TelÃ©fonos
# ---------------------------------------------------------------------------

@router.post("/{agente_id}/telefonos", response_model=TelefonoResponse, status_code=status.HTTP_201_CREATED, dependencies=_ESCRITURA)
def agregar_telefono(
    agente_id: UUID,
    body: TelefonoCreate,
    db: Client = Depends(get_db),
) -> TelefonoResponse:
    _check_agente_existe(db, agente_id)

    payload = body.model_dump()
    payload["agente_id"] = str(agente_id)

    result = db.table("agente_telefono").insert(payload).select("*").execute()
    if result.data:
        result.data = result.data[0]
    return TelefonoResponse.model_validate(result.data)


@router.patch("/{agente_id}/telefonos/{telefono_id}/preferente", response_model=TelefonoResponse, dependencies=_ESCRITURA)
def marcar_telefono_preferente(
    agente_id: UUID,
    telefono_id: UUID,
    db: Client = Depends(get_db),
) -> TelefonoResponse:
    """
    Marca este telÃ©fono como preferente y quita el preferente anterior.
    El Ã­ndice Ãºnico parcial uq_agente_telefono_preferente garantiza solo uno activo.
    Se hace en dos pasos para evitar conflicto de constraint.
    """
    # Quitar preferente actual
    db.table("agente_telefono").update({"preferente": False}).eq("agente_id", str(agente_id)).eq("preferente", True).execute()

    # Marcar el nuevo
    result = (
        db.table("agente_telefono")
        .update({"preferente": True})
        .eq("id", str(telefono_id))
        .eq("agente_id", str(agente_id))
        .select("*")
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="TelÃ©fono no encontrado.")
    return TelefonoResponse.model_validate(result.data)


@router.delete("/{agente_id}/telefonos/{telefono_id}", status_code=status.HTTP_204_NO_CONTENT, dependencies=_ESCRITURA)
def eliminar_telefono(
    agente_id: UUID,
    telefono_id: UUID,
    db: Client = Depends(get_db),
) -> None:
    db.table("agente_telefono").delete().eq("id", str(telefono_id)).eq("agente_id", str(agente_id)).execute()


# ---------------------------------------------------------------------------
# Emails del agente
# ---------------------------------------------------------------------------

@router.post("/{agente_id}/emails", response_model=AgenteEmailResponse, status_code=status.HTTP_201_CREATED, dependencies=_ESCRITURA)
def agregar_email(
    agente_id: UUID,
    body: AgenteEmailCreate,
    db: Client = Depends(get_db),
) -> AgenteEmailResponse:
    _check_agente_existe(db, agente_id)

    payload = body.model_dump()
    payload["agente_id"] = str(agente_id)

    try:
        result = db.table("agente_email").insert(payload).select("*").execute()
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "uq_agente_email_email" in msg or "duplicate" in msg.lower():
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"El correo '{body.email}' ya estÃ¡ registrado.")
        if "ya estÃ¡ registrado como email de un asistente" in msg:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))
        raise exc from None

    return AgenteEmailResponse.model_validate(result.data)


@router.patch("/{agente_id}/emails/{email_id}/preferente", response_model=AgenteEmailResponse, dependencies=_ESCRITURA)
def marcar_email_preferente(
    agente_id: UUID,
    email_id: UUID,
    db: Client = Depends(get_db),
) -> AgenteEmailResponse:
    db.table("agente_email").update({"preferente": False}).eq("agente_id", str(agente_id)).eq("preferente", True).execute()

    result = (
        db.table("agente_email")
        .update({"preferente": True})
        .eq("id", str(email_id))
        .eq("agente_id", str(agente_id))
        .select("*")
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Email no encontrado.")
    return AgenteEmailResponse.model_validate(result.data)


@router.delete("/{agente_id}/emails/{email_id}", status_code=status.HTTP_204_NO_CONTENT, dependencies=_ESCRITURA)
def eliminar_email(
    agente_id: UUID,
    email_id: UUID,
    db: Client = Depends(get_db),
) -> None:
    db.table("agente_email").delete().eq("id", str(email_id)).eq("agente_id", str(agente_id)).execute()


# ---------------------------------------------------------------------------
# Asistentes
# ---------------------------------------------------------------------------

@router.post("/{agente_id}/asistentes", response_model=AsistenteResponse, status_code=status.HTTP_201_CREATED, dependencies=_ESCRITURA)
def agregar_asistente(
    agente_id: UUID,
    body: AsistenteCreate,
    db: Client = Depends(get_db),
) -> AsistenteResponse:
    _check_agente_existe(db, agente_id)

    payload = body.model_dump(exclude_none=True)
    payload["agente_id"] = str(agente_id)

    try:
        result = db.table("asistente").insert(payload).select("*").execute()
        if result.data:
            result.data = result.data[0]
    except Exception as exc:
        msg = str(exc)
        if "uq_asistente_email" in msg or "duplicate" in msg.lower():
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"El correo '{body.email}' ya estÃ¡ registrado como asistente.")
        if "ya estÃ¡ registrado como email de un agente" in msg:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))
        raise exc from None

    return AsistenteResponse.model_validate(result.data)


@router.patch("/{agente_id}/asistentes/{asistente_id}", response_model=AsistenteResponse, dependencies=_ESCRITURA)
def actualizar_asistente(
    agente_id: UUID,
    asistente_id: UUID,
    body: AsistenteUpdate,
    db: Client = Depends(get_db),
) -> AsistenteResponse:
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_CONTENT, detail="No se enviaron campos.")

    result = (
        db.table("asistente")
        .update(cambios)
        .eq("id", str(asistente_id))
        .eq("agente_id", str(agente_id))
        .select("*")
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Asistente no encontrado.")
    return AsistenteResponse.model_validate(result.data)


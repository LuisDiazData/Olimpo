"""
Router de usuarios del CRM Olimpo.

GET    /usuarios              â€" lista (directores: todos; gerentes: su ramo; analistas: su ramo)
POST   /usuarios              â€" crear usuario (solo directores)
GET    /usuarios/{id}         â€" perfil completo
PATCH  /usuarios/{id}         â€" actualizar campos de negocio (solo directores)
DELETE /usuarios/{id}         â€" soft-delete: activo = FALSE (solo directores)

La creaciÃ³n de usuario pasa por Supabase Auth Admin API (service_role).
El trigger sync_auth_usuario en la DB crea el perfil en public.usuario.
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from supabase import AuthApiError, Client

from core.auth import get_current_user, require_roles
from core.database import get_admin_db_dep, get_db
from models.usuario import (
    RolUsuario,
    UsuarioAdminUpdate,
    UsuarioCreate,
    UsuarioListItem,
    UsuarioResponse,
    UsuarioToken,
)

log = structlog.get_logger(__name__)
router = APIRouter(prefix="/usuarios", tags=["usuarios"])

_SOLO_DIRECTORES = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))]


# ---------------------------------------------------------------------------
# GET /usuarios
# ---------------------------------------------------------------------------

@router.get("", response_model=list[UsuarioListItem])
def listar_usuarios(
    activo: bool | None = Query(default=None, description="Filtrar por estado activo/inactivo"),
    ramo: str | None = Query(default=None, description="Filtrar por ramo"),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Client = Depends(get_db),
) -> list[UsuarioListItem]:
    """
    Lista de usuarios. El RLS de la DB aplica el filtro por rol automÃ¡ticamente:
      - directores ven todos
      - gerentes ven su ramo
      - analistas ven analistas de su ramo
    """
    query = db.table("usuario").select(
        "id, nombre, email, rol, ramo, activo"
    )

    if activo is not None:
        query = query.eq("activo", activo)
    if ramo:
        query = query.eq("ramo", ramo)

    result = query.order("nombre").range(offset, offset + limit - 1).execute()

    return [UsuarioListItem.model_validate(u) for u in result.data]


# ---------------------------------------------------------------------------
# POST /usuarios
# ---------------------------------------------------------------------------

@router.post(
    "",
    response_model=UsuarioResponse,
    status_code=status.HTTP_201_CREATED,
    dependencies=_SOLO_DIRECTORES,
)
def crear_usuario(
    body: UsuarioCreate,
    admin: Client = Depends(get_admin_db_dep),
) -> UsuarioResponse:
    """
    Crea un usuario en Supabase Auth y su perfil en public.usuario.
    El trigger sync_auth_usuario en la DB crea el perfil automÃ¡ticamente.
    Solo directores pueden crear usuarios.
    """
    user_metadata = {"nombre": body.nombre}
    if body.telefono:
        user_metadata["telefono"] = body.telefono
    if body.firma_html:
        user_metadata["firma_html"] = body.firma_html

    app_metadata: dict = {"rol": body.rol.value}
    if body.ramo:
        app_metadata["ramo"] = body.ramo.value

    try:
        auth_response = admin.auth.admin.create_user({
            "email": str(body.email),
            "email_confirm": True,
            "user_metadata": user_metadata,
            "app_metadata": app_metadata,
        })
    except AuthApiError as exc:
        if "already registered" in str(exc).lower() or "already been registered" in str(exc).lower():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"El correo '{body.email}' ya estÃ¡ registrado.",
            )
        log.error("error_crear_usuario_auth", email=str(body.email), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Error al crear el usuario en Auth: {exc}",
        )

    # El trigger de la DB ya insertÃ³ el perfil â€" lo leemos con service_role
    result = (
        admin.table("usuario")
        .select("id, nombre, email, rol, ramo, telefono, firma_html, activo, created_at, updated_at")
        .eq("id", auth_response.user.id)
        .maybe_single()
        .execute()
    )

    if not result:
        log.error(
            "perfil_no_creado_post_auth",
            auth_id=str(auth_response.user.id),
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="El usuario se creÃ³ en Auth pero el perfil no se generÃ³ correctamente.",
        )

    log.info("usuario_creado", id=result.data["id"], email=body.email, rol=body.rol)
    return UsuarioResponse.model_validate(result.data)


# ---------------------------------------------------------------------------
# GET /usuarios/{id}
# ---------------------------------------------------------------------------

@router.get("/{usuario_id}", response_model=UsuarioResponse)
def obtener_usuario(
    usuario_id: UUID,
    db: Client = Depends(get_db),
) -> UsuarioResponse:
    """
    Perfil completo de un usuario. RLS aplica: cada rol solo ve lo que le corresponde.
    Cualquier usuario puede ver su propio perfil (pol_usuario_select_propio).
    """
    result = (
        db.table("usuario")
        .select("id, nombre, email, rol, ramo, telefono, firma_html, activo, created_at, updated_at")
        .eq("id", str(usuario_id))
        .maybe_single()
        .execute()
    )

    if not result:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Usuario no encontrado.",
        )

    return UsuarioResponse.model_validate(result.data)


# ---------------------------------------------------------------------------
# PATCH /usuarios/{id}
# ---------------------------------------------------------------------------

@router.patch(
    "/{usuario_id}",
    response_model=UsuarioResponse,
    dependencies=_SOLO_DIRECTORES,
)
def actualizar_usuario(
    usuario_id: UUID,
    body: UsuarioAdminUpdate,
    admin: Client = Depends(get_admin_db_dep),
    db: Client = Depends(get_db),
) -> UsuarioResponse:
    """
    Actualiza campos de negocio del usuario. Solo directores.
    Para cambiar rol/ramo: usar la gestiÃ³n de usuarios desde Supabase Auth Admin
    (es necesario actualizar app_metadata del JWT tambiÃ©n).
    """
    cambios = body.model_dump(exclude_none=True)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos para actualizar.",
        )

    result = (
        admin.table("usuario")
        .update(cambios)
        .eq("id", str(usuario_id))
        .select("id, nombre, email, rol, ramo, telefono, firma_html, activo, created_at, updated_at")
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Usuario no encontrado.",
        )

    log.info("usuario_actualizado", id=str(usuario_id), campos=list(cambios.keys()))
    return obtener_usuario(usuario_id, db)


# ---------------------------------------------------------------------------
# DELETE /usuarios/{id}  â€" soft-delete
# ---------------------------------------------------------------------------

@router.delete(
    "/{usuario_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    dependencies=_SOLO_DIRECTORES,
)
def desactivar_usuario(
    usuario_id: UUID,
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
) -> None:
    """
    Soft-delete: pone activo = FALSE en public.usuario y deshabilita la sesiÃ³n en Supabase Auth.
    No elimina el registro â€" preserva integridad referencial con trÃ¡mites histÃ³ricos.
    """
    if caller.id == usuario_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No puedes desactivarte a ti mismo.",
        )

    # Desactivar en public.usuario
    result = (
        admin.table("usuario")
        .update({"activo": False})
        .eq("id", str(usuario_id))
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Usuario no encontrado.",
        )

    # Deshabilitar sesiones activas en Supabase Auth
    try:
        admin.auth.admin.update_user_by_id(str(usuario_id), {"ban_duration": "876600h"})
    except AuthApiError as exc:
        log.warning("no_se_pudo_banear_en_auth", usuario_id=str(usuario_id), error=str(exc))

    log.info("usuario_desactivado", id=str(usuario_id), por=str(caller.id))

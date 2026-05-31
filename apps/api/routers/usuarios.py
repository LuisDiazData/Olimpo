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

from typing import Any, cast
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from supabase import AuthApiError, Client

from core.auth import require_permiso, require_roles
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

# Roles que cada rol puede asignar al crear un usuario.
# director_general es el único que puede crear director_ops.
# Ningún rol puede crear otro director_general — eso es tarea del Superadmin.
# El gerente solo puede crear analistas de su propio ramo (validado en el endpoint).
_ROLES_ASIGNABLES: dict[RolUsuario, set[RolUsuario]] = {
    RolUsuario.director_general: {RolUsuario.director_ops, RolUsuario.gerente, RolUsuario.analista},
    RolUsuario.director_ops: {RolUsuario.gerente, RolUsuario.analista},
    RolUsuario.gerente: {RolUsuario.analista},
}

_SOLO_DIRECTORES = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))]


# ---------------------------------------------------------------------------
# GET /usuarios
# ---------------------------------------------------------------------------


@router.get("", response_model=list[UsuarioListItem])
def listar_usuarios(
    activo: bool | None = Query(
        default=None, description="Filtrar por estado activo/inactivo. Por defecto devuelve todos."
    ),
    ramo: str | None = Query(
        default=None, description="Filtrar por ramo. Gerentes solo ven su ramo (RLS)."
    ),
    rol: RolUsuario | None = Query(
        default=None, description="Filtrar por rol. Útil para obtener solo analistas disponibles."
    ),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    db: Client = Depends(get_db),
) -> list[UsuarioListItem]:
    """
    Lista de usuarios. El RLS de la DB aplica el filtro por rol automáticamente:
      - directores ven todos
      - gerentes ven su ramo (activos e inactivos)
      - analistas ven analistas de su ramo

    Para que un gerente vea los analistas disponibles de su ramo:
      GET /usuarios?rol=analista&activo=true
    """
    query = db.table("usuario").select("id, nombre, email, rol, ramo, ramos_adicionales, activo")

    if activo is not None:
        query = query.eq("activo", activo)
    if ramo:
        query = query.eq("ramo", ramo)
    if rol:
        query = query.eq("rol", rol.value)

    result = query.order("nombre").range(offset, offset + limit - 1).execute()

    return [UsuarioListItem.model_validate(u) for u in result.data]


# ---------------------------------------------------------------------------
# POST /usuarios
# ---------------------------------------------------------------------------


@router.post(
    "",
    response_model=UsuarioResponse,
    status_code=status.HTTP_201_CREATED,
)
def crear_usuario(
    body: UsuarioCreate,
    caller: UsuarioToken = Depends(
        require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente)
    ),
    admin: Client = Depends(get_admin_db_dep),
) -> UsuarioResponse:
    """
    Crea un usuario en Supabase Auth y su perfil en public.usuario.
    El trigger sync_auth_usuario en la DB crea el perfil automáticamente.

    Jerarquía de roles permitidos:
      director_general → puede crear director_ops, gerente, analista
      director_ops     → puede crear gerente, analista
      gerente          → puede crear analista (solo de su propio ramo)
    Ningún rol puede crear otro director_general — eso es tarea del Superadmin.
    """
    log.info("crear_usuario_request", rol_caller=caller.rol, body=body.model_dump())

    roles_permitidos = _ROLES_ASIGNABLES.get(caller.rol, set())
    if body.rol not in roles_permitidos:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                f"Tu rol '{caller.rol}' no puede crear usuarios con rol '{body.rol}'. "
                f"Roles permitidos: {[r.value for r in sorted(roles_permitidos, key=lambda r: r.value)]}."
            ),
        )

    if caller.rol == RolUsuario.gerente and body.ramo != caller.ramo:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"Solo puedes crear analistas de tu ramo '{caller.ramo}'.",
        )

    user_metadata = {"nombre": body.nombre}
    if body.telefono:
        user_metadata["telefono"] = body.telefono
    if body.firma_html:
        user_metadata["firma_html"] = body.firma_html

    app_metadata: dict = {"rol": body.rol.value}
    if body.ramo:
        app_metadata["ramo"] = body.ramo.value

    try:
        auth_response = admin.auth.admin.create_user(
            {
                "email": str(body.email),
                "password": body.password,
                "email_confirm": True,
                "user_metadata": user_metadata,
                "app_metadata": app_metadata,
            }
        )
    except AuthApiError as exc:
        if (
            "already registered" in str(exc).lower()
            or "already been registered" in str(exc).lower()
        ):
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"El correo '{body.email}' ya está registrado.",
            ) from exc
        log.error("error_crear_usuario_auth", email=str(body.email), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Error al crear el usuario en Auth: {exc}",
        ) from exc

    # El trigger de la DB ya insertÃ³ el perfil â€" lo leemos con service_role
    result = (
        admin.table("usuario")
        .select(
            "id, nombre, email, rol, ramo, ramos_adicionales, telefono, firma_html, activo, created_at, updated_at"
        )
        .eq("id", auth_response.user.id)
        .maybe_single()
        .execute()
    )

    if not result.data:
        log.error(
            "perfil_no_creado_post_auth",
            auth_id=str(auth_response.user.id),
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="El usuario se creÃ³ en Auth pero el perfil no se generÃ³ correctamente.",
        )

    # Actualizar ramos_adicionales si se proporcionaron
    if body.ramos_adicionales:
        admin.table("usuario").update(
            {"ramos_adicionales": [r.value for r in body.ramos_adicionales]}
        ).eq("id", auth_response.user.id).execute()

    perfil = cast(dict[str, Any], result.data)
    log.info("usuario_creado", id=perfil["id"], email=body.email, rol=body.rol)
    return UsuarioResponse.model_validate(perfil)


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
        .select(
            "id, nombre, email, rol, ramo, ramos_adicionales, telefono, firma_html, activo, created_at, updated_at"
        )
        .eq("id", str(usuario_id))
        .maybe_single()
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Usuario no encontrado.",
        )

    return UsuarioResponse.model_validate(cast(dict[str, Any], result.data))


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
    log.info("actualizar_usuario_request", usuario_id=str(usuario_id), body=body.model_dump())
    cambios = body.model_dump(exclude_none=True)
    log.info("actualizar_usuario_cambios", cambios=cambios)
    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos para actualizar.",
        )

    if "ramos_adicionales" in cambios and cambios["ramos_adicionales"] is not None:
        cambios["ramos_adicionales"] = [r.value for r in body.ramos_adicionales]

    result = (
        admin.table("usuario")
        .update(cambios)
        .eq("id", str(usuario_id))
        .select(
            "id, nombre, email, rol, ramo, ramos_adicionales, telefono, firma_html, activo, created_at, updated_at"
        )
        .execute()
    )
    row: dict[str, Any] | None = result.data[0] if result.data else None

    if not row:
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
)
def desactivar_usuario(
    usuario_id: UUID,
    caller: UsuarioToken = Depends(
        require_roles(RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente)
    ),
    admin: Client = Depends(get_admin_db_dep),
) -> None:
    """
    Soft-delete: pone activo = FALSE en public.usuario y deshabilita la sesión en Supabase Auth.
    No elimina el registro — preserva integridad referencial con trámites históricos.

    Permisos:
      directores → pueden desactivar cualquier usuario
      gerente    → solo puede desactivar analistas de su propio ramo
    """
    if caller.id == usuario_id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="No puedes desactivarte a ti mismo.",
        )

    if caller.rol == RolUsuario.gerente:
        objetivo = (
            admin.table("usuario")
            .select("id, rol, ramo")
            .eq("id", str(usuario_id))
            .maybe_single()
            .execute()
        )
        if not objetivo.data:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="Usuario no encontrado."
            )

        objetivo_data = cast(dict[str, Any], objetivo.data)
        if objetivo_data["rol"] != RolUsuario.analista:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail="Solo puedes desactivar analistas.",
            )
        if objetivo_data["ramo"] != caller.ramo:
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Solo puedes desactivar analistas de tu ramo '{caller.ramo}'.",
            )

    result = admin.table("usuario").update({"activo": False}).eq("id", str(usuario_id)).execute()

    if not result.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Usuario no encontrado.")

    try:
        admin.auth.admin.update_user_by_id(str(usuario_id), {"ban_duration": "876600h"})
    except AuthApiError as exc:
        log.warning("no_se_pudo_banear_en_auth", usuario_id=str(usuario_id), error=str(exc))

    log.info("usuario_desactivado", id=str(usuario_id), por=str(caller.id), por_rol=caller.rol)


# ---------------------------------------------------------------------------
# POST /usuarios/{id}/reset-password
# ---------------------------------------------------------------------------


@router.post(
    "/{usuario_id}/reset-password",
    status_code=status.HTTP_200_OK,
    dependencies=[Depends(require_permiso("usuarios.resetear_password"))],
)
def enviar_reset_password(
    usuario_id: UUID,
    admin: Client = Depends(get_admin_db_dep),
) -> dict:
    """
    Envía un enlace de recuperación de contraseña al correo del usuario.
    Solo accesible para roles con el permiso 'usuarios.resetear_password'
    (director_general y director_ops por defecto).
    El enlace es de un solo uso y expira en 1 hora.
    """
    result = (
        admin.table("usuario")
        .select("id, email, activo")
        .eq("id", str(usuario_id))
        .maybe_single()
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Usuario no encontrado.",
        )

    usuario_data = cast(dict[str, Any], result.data)
    if not usuario_data["activo"]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="El usuario está inactivo y no puede recuperar su contraseña.",
        )

    try:
        admin.auth.admin.generate_link(
            {
                "type": "recovery",
                "email": usuario_data["email"],
            }
        )
    except AuthApiError as exc:
        log.error("error_generar_recovery_link", usuario_id=str(usuario_id), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="No se pudo enviar el correo de recuperación. Intenta de nuevo.",
        ) from exc

    log.info("reset_password_enviado", usuario_id=str(usuario_id), email=usuario_data["email"])
    return {"mensaje": "Enlace de recuperación enviado al correo del usuario."}

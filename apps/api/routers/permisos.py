"""
Router de permisos — gestión de permisos granulares por rol y por usuario.

Endpoints disponibles:
  GET    /permisos                              — catálogo de todos los permisos
  GET    /permisos/rol/{rol}                    — permisos por defecto de un rol
  PATCH  /permisos/rol                          — configurar permiso de un rol (solo directores)
  GET    /permisos/usuarios/{usuario_id}        — permisos efectivos de un usuario
  GET    /permisos/usuarios/{usuario_id}/overrides — solo los overrides del usuario
  POST   /permisos/usuarios/{usuario_id}        — otorgar/denegar permiso a usuario
  DELETE /permisos/usuarios/{usuario_id}/{clave} — revocar override (vuelve a default de rol)
  GET    /permisos/audit-log                    — historial de cambios de permisos
"""

from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, Query, status
from supabase import Client

from core.auth import get_current_user, require_roles
from core.database import get_admin_db_dep, get_db
from models.permiso import (
    ConfigurarRolPermisoBody,
    OtorgarPermisoUsuarioBody,
    PermisoAuditLogEntry,
    PermisoEfectivoItem,
    PermisoResponse,
    PermisosUsuarioResponse,
    RolPermisoResponse,
    UsuarioPermisoResponse,
)
from models.usuario import RolUsuario, UsuarioToken

log = structlog.get_logger(__name__)

router = APIRouter(prefix="/permisos", tags=["permisos"])

_SOLO_DIRECTORES = [Depends(require_roles(RolUsuario.director_general, RolUsuario.director_ops))]
_DIRECTORES_Y_GERENTES = [
    Depends(
        require_roles(
            RolUsuario.director_general,
            RolUsuario.director_ops,
            RolUsuario.gerente,
        )
    )
]


# =============================================================================
# Catálogo de permisos
# =============================================================================


@router.get("", response_model=list[PermisoResponse])
def listar_permisos(
    dominio: str | None = Query(default=None, description="Filtrar por dominio (e.g. 'tramites')."),
    solo_activos: bool = Query(default=True),
    db: Client = Depends(get_db),
    _: UsuarioToken = Depends(get_current_user),
):
    """Devuelve el catálogo completo de permisos disponibles en el sistema."""
    query = db.table("permiso").select("*")
    if solo_activos:
        query = query.eq("activo", True)
    if dominio:
        query = query.eq("dominio", dominio)
    result = query.order("dominio").order("clave").execute()
    return result.data


@router.get("/dominios", response_model=list[str])
def listar_dominios(
    db: Client = Depends(get_db),
    _: UsuarioToken = Depends(get_current_user),
):
    """Devuelve la lista de dominios únicos disponibles."""
    result = db.table("permiso").select("dominio").eq("activo", True).execute()
    dominios = sorted({row["dominio"] for row in result.data})
    return dominios


# =============================================================================
# Permisos por rol
# =============================================================================


@router.get("/rol/{rol}", response_model=list[RolPermisoResponse])
def listar_permisos_rol(
    rol: RolUsuario,
    dominio: str | None = Query(default=None),
    db: Client = Depends(get_db),
    _: UsuarioToken = Depends(get_current_user),
):
    """Devuelve todos los permisos por defecto configurados para un rol."""
    query = (
        db.table("rol_permiso")
        .select("*, permiso(clave, nombre, dominio, activo)")
        .eq("rol", rol.value)
    )
    result = query.execute()

    rows = []
    for row in result.data:
        p = row.get("permiso") or {}
        if dominio and p.get("dominio") != dominio:
            continue
        rows.append(
            RolPermisoResponse(
                rol=rol,
                permiso_id=row["permiso_id"],
                permiso_clave=p.get("clave"),
                permiso_nombre=p.get("nombre"),
                concedido=row["concedido"],
                created_at=row["created_at"],
            )
        )
    return rows


@router.patch("/rol", dependencies=_SOLO_DIRECTORES, status_code=status.HTTP_200_OK)
def configurar_permiso_rol(
    body: ConfigurarRolPermisoBody,
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """
    Modifica el permiso por defecto de un rol completo.
    Solo directores pueden invocar este endpoint.
    El cambio queda registrado en permiso_audit_log.
    """
    result = admin.rpc(
        "configurar_permiso_rol",
        {
            "p_rol": body.rol.value,
            "p_permiso_clave": body.permiso_clave,
            "p_concedido": body.concedido,
            "p_configurado_por": str(caller.id),
        },
    ).execute()

    data: dict = result.data or {}
    if not data.get("ok"):
        error_code = data.get("error_code", "ERROR_DESCONOCIDO")
        mensaje = data.get("mensaje", "Error al configurar el permiso de rol.")
        status_map = {
            "PERMISO_NO_ENCONTRADO": status.HTTP_404_NOT_FOUND,
            "PERMISO_INACTIVO": status.HTTP_422_UNPROCESSABLE_ENTITY,
            "SIN_PERMISO": status.HTTP_403_FORBIDDEN,
        }
        raise HTTPException(
            status_code=status_map.get(error_code, status.HTTP_400_BAD_REQUEST),
            detail={"error_code": error_code, "mensaje": mensaje},
        )

    log.info(
        "permiso_rol_configurado",
        rol=body.rol.value,
        permiso=body.permiso_clave,
        concedido=body.concedido,
        configurado_por=str(caller.id),
    )
    return data


# =============================================================================
# Permisos efectivos de un usuario
# =============================================================================


@router.get("/usuarios/{usuario_id}", response_model=PermisosUsuarioResponse)
def listar_permisos_usuario(
    usuario_id: UUID,
    dominio: str | None = Query(default=None),
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """
    Devuelve todos los permisos efectivos del usuario (override o default de rol).
    - El propio usuario puede ver los suyos.
    - Gerentes ven los de sus analistas.
    - Directores ven los de cualquier usuario.
    """
    _validar_acceso_a_usuario(caller, usuario_id, admin)

    result = admin.rpc(
        "listar_permisos_usuario",
        {"p_usuario_id": str(usuario_id)},
    ).execute()

    rows = result.data or []
    if dominio:
        rows = [r for r in rows if r.get("dominio") == dominio]

    usuario_info = (
        admin.table("usuario").select("rol").eq("id", str(usuario_id)).maybe_single().execute()
    )
    if not usuario_info.data:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Usuario no encontrado.")
    rol_usuario = RolUsuario(usuario_info.data["rol"])

    return PermisosUsuarioResponse(
        usuario_id=usuario_id,
        rol=rol_usuario,
        permisos=[
            PermisoEfectivoItem(
                clave=r["clave"],
                dominio=r["dominio"],
                nombre=r["nombre"],
                concedido=r["concedido"],
                fuente=r["fuente"],
            )
            for r in rows
        ],
    )


@router.get("/usuarios/{usuario_id}/overrides", response_model=list[UsuarioPermisoResponse])
def listar_overrides_usuario(
    usuario_id: UUID,
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """Devuelve solo los overrides explícitos configurados para un usuario."""
    _validar_acceso_a_usuario(caller, usuario_id, admin)

    result = (
        admin.table("usuario_permiso")
        .select(
            "*, permiso(clave, nombre), otorgado_por_usuario:usuario!usuario_permiso_otorgado_por_fkey(nombre)"
        )
        .eq("usuario_id", str(usuario_id))
        .order("created_at", desc=True)
        .execute()
    )

    rows = []
    for row in result.data:
        p = row.get("permiso") or {}
        otorgado_por_usuario = row.get("otorgado_por_usuario") or {}
        rows.append(
            UsuarioPermisoResponse(
                usuario_id=usuario_id,
                permiso_id=row["permiso_id"],
                permiso_clave=p.get("clave"),
                permiso_nombre=p.get("nombre"),
                concedido=row["concedido"],
                otorgado_por=row["otorgado_por"],
                otorgado_por_nombre=otorgado_por_usuario.get("nombre"),
                created_at=row["created_at"],
            )
        )
    return rows


@router.post(
    "/usuarios/{usuario_id}",
    dependencies=_DIRECTORES_Y_GERENTES,
    status_code=status.HTTP_200_OK,
)
def otorgar_permiso_usuario(
    usuario_id: UUID,
    body: OtorgarPermisoUsuarioBody,
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """
    Otorga o deniega explícitamente un permiso a un usuario.
    - Directores pueden configurar permisos de cualquier usuario.
    - Gerentes solo pueden configurar permisos de analistas de su mismo ramo.
    La función SQL valida la autorización del caller y registra el cambio en audit log.
    """
    result = admin.rpc(
        "otorgar_permiso_usuario",
        {
            "p_usuario_id": str(usuario_id),
            "p_permiso_clave": body.permiso_clave,
            "p_concedido": body.concedido,
            "p_otorgado_por": str(caller.id),
        },
    ).execute()

    data: dict = result.data or {}
    if not data.get("ok"):
        error_code = data.get("error_code", "ERROR_DESCONOCIDO")
        mensaje = data.get("mensaje", "Error al otorgar el permiso.")
        status_map = {
            "PERMISO_NO_ENCONTRADO": status.HTTP_404_NOT_FOUND,
            "PERMISO_INACTIVO": status.HTTP_422_UNPROCESSABLE_ENTITY,
            "USUARIO_NO_ENCONTRADO": status.HTTP_404_NOT_FOUND,
            "USUARIO_INACTIVO": status.HTTP_422_UNPROCESSABLE_ENTITY,
            "SIN_PERMISO": status.HTTP_403_FORBIDDEN,
            "RAMO_DIFERENTE": status.HTTP_403_FORBIDDEN,
        }
        raise HTTPException(
            status_code=status_map.get(error_code, status.HTTP_400_BAD_REQUEST),
            detail={"error_code": error_code, "mensaje": mensaje},
        )

    log.info(
        "permiso_usuario_otorgado",
        usuario_id=str(usuario_id),
        permiso=body.permiso_clave,
        concedido=body.concedido,
        otorgado_por=str(caller.id),
    )
    return data


@router.delete(
    "/usuarios/{usuario_id}/{permiso_clave}",
    dependencies=_DIRECTORES_Y_GERENTES,
    status_code=status.HTTP_200_OK,
)
def revocar_permiso_usuario(
    usuario_id: UUID,
    permiso_clave: str,
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """
    Revoca el override de un usuario para un permiso.
    El permiso vuelve a regirse por el default de su rol.
    """
    result = admin.rpc(
        "revocar_permiso_usuario",
        {
            "p_usuario_id": str(usuario_id),
            "p_permiso_clave": permiso_clave,
            "p_revocado_por": str(caller.id),
        },
    ).execute()

    data: dict = result.data or {}
    if not data.get("ok"):
        error_code = data.get("error_code", "ERROR_DESCONOCIDO")
        mensaje = data.get("mensaje", "Error al revocar el permiso.")
        status_map = {
            "PERMISO_NO_ENCONTRADO": status.HTTP_404_NOT_FOUND,
            "USUARIO_NO_ENCONTRADO": status.HTTP_404_NOT_FOUND,
            "OVERRIDE_NO_EXISTE": status.HTTP_404_NOT_FOUND,
            "SIN_PERMISO": status.HTTP_403_FORBIDDEN,
            "RAMO_DIFERENTE": status.HTTP_403_FORBIDDEN,
        }
        raise HTTPException(
            status_code=status_map.get(error_code, status.HTTP_400_BAD_REQUEST),
            detail={"error_code": error_code, "mensaje": mensaje},
        )

    log.info(
        "permiso_usuario_revocado",
        usuario_id=str(usuario_id),
        permiso=permiso_clave,
        revocado_por=str(caller.id),
    )
    return data


# =============================================================================
# Audit log
# =============================================================================


@router.get(
    "/audit-log",
    response_model=list[PermisoAuditLogEntry],
    dependencies=_DIRECTORES_Y_GERENTES,
)
def listar_audit_log(
    usuario_id: UUID | None = Query(default=None, description="Filtrar por usuario afectado."),
    rol: RolUsuario | None = Query(default=None, description="Filtrar cambios de rol."),
    permiso_clave: str | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=500),
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """
    Historial inmutable de cambios de permisos.
    Gerentes solo ven cambios de permisos de usuarios de su ramo.
    Directores ven todo.
    """
    query = admin.table("permiso_audit_log").select("*").order("created_at", desc=True).limit(limit)

    if usuario_id:
        query = query.eq("usuario_id", str(usuario_id))
    if rol:
        query = query.eq("rol", rol.value)
    if permiso_clave:
        query = query.eq("permiso_clave", permiso_clave)

    # Gerentes solo ven sus analistas — filtrar por ramo
    if caller.rol == RolUsuario.gerente and caller.ramo:
        analistas_ramo = (
            admin.table("usuario")
            .select("id")
            .eq("ramo", caller.ramo.value)
            .eq("rol", "analista")
            .execute()
        )
        ids_ramo = [str(u["id"]) for u in analistas_ramo.data]
        if not ids_ramo:
            return []
        query = query.in_("usuario_id", ids_ramo)

    result = query.execute()
    return result.data


# =============================================================================
# Verificación puntual
# =============================================================================


@router.get("/verificar/{permiso_clave}", response_model=dict)
def verificar_mi_permiso(
    permiso_clave: str,
    caller: UsuarioToken = Depends(get_current_user),
    admin: Client = Depends(get_admin_db_dep),
):
    """Verifica si el usuario autenticado tiene un permiso específico."""
    result = admin.rpc(
        "tiene_permiso",
        {"p_usuario_id": str(caller.id), "p_clave": permiso_clave},
    ).execute()
    tiene = bool(result.data)
    return {"clave": permiso_clave, "concedido": tiene}


# =============================================================================
# Helper privado
# =============================================================================


def _validar_acceso_a_usuario(
    caller: UsuarioToken,
    usuario_id: UUID,
    admin: Client,
) -> None:
    """Lanza 403 si el caller no tiene acceso a los permisos del usuario_id."""
    if caller.id == usuario_id:
        return
    if caller.rol in (RolUsuario.director_general, RolUsuario.director_ops):
        return
    if caller.rol == RolUsuario.gerente and caller.ramo:
        target = (
            admin.table("usuario").select("ramo").eq("id", str(usuario_id)).maybe_single().execute()
        )
        if target.data and target.data.get("ramo") == caller.ramo.value:
            return
    raise HTTPException(
        status_code=status.HTTP_403_FORBIDDEN,
        detail={
            "error_code": "ACCESO_DENEGADO",
            "mensaje": "No tienes acceso a los permisos de este usuario.",
        },
    )

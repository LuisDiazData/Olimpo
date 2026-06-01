"""
Router: gestión del usuario maestro de cada tenant.

El usuario maestro es el director_general de la instancia CRM de esa promotoría.
Es la credencial que se entrega al director al contratar el servicio.

Endpoints:
  POST /tenants/{id}/usuario-maestro              — crear usuario maestro
  POST /tenants/{id}/usuario-maestro/reset-password — resetear contraseña
  POST /tenants/{id}/usuario-maestro/bloquear       — bloquear acceso
  POST /tenants/{id}/usuario-maestro/desbloquear    — desbloquear acceso

El Superadmin nunca ve la contraseña del usuario maestro. Al crearla o resetearla,
se genera aquí y se devuelve UNA SOLA VEZ en la respuesta — el Superadmin la
anota y la entrega al director. Si se pierde, usar reset-password.
"""

from typing import Any, cast
from uuid import UUID

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, EmailStr, Field
from supabase import AuthApiError

from core.auth import require_superadmin
from core.crypto import descifrar_key
from core.database import get_admin_db, get_tenant_client

log = structlog.get_logger(__name__)

router = APIRouter(
    prefix="/tenants",
    tags=["Usuarios Maestros"],
    dependencies=[Depends(require_superadmin)],
)


# =============================================================================
# MODELOS
# =============================================================================


class UsuarioMaestroCreate(BaseModel):
    nombre: str = Field(min_length=2, max_length=100, description="Nombre completo del director.")
    email: EmailStr
    password: str = Field(
        min_length=12,
        description="Contraseña robusta. Mínimo 12 caracteres. Se devuelve una sola vez.",
    )


class UsuarioMaestroCreado(BaseModel):
    usuario_id: UUID
    email: str
    nombre: str
    password_temporal: str = Field(
        description="Contraseña en texto plano. Guardarla y entregarla al director. "
        "No se puede recuperar después — usar reset-password si se pierde."
    )


class ResetPasswordBody(BaseModel):
    nueva_password: str = Field(min_length=12)


# =============================================================================
# HELPER INTERNO
# =============================================================================


def _get_tenant_activo(tenant_id: UUID) -> dict[str, Any]:
    """Obtiene el registro del tenant y verifica que esté activo. Lanza 404/403 si no."""
    db = get_admin_db()
    result = (
        db.table("tenant")
        .select(
            "id, nombre, subdominio, supabase_url, service_role_key_enc, "
            "activo, usuario_maestro_id, usuario_maestro_email"
        )
        .eq("id", str(tenant_id))
        .single()
        .execute()
    )

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error_code": "TENANT_NO_ENCONTRADO", "mensaje": "Tenant no encontrado."},
        )

    tenant = cast(dict[str, Any], result.data)
    if not tenant["activo"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail={
                "error_code": "TENANT_INACTIVO",
                "mensaje": "El tenant está bloqueado. Activarlo primero.",
            },
        )
    return tenant


# =============================================================================
# ENDPOINTS
# =============================================================================


@router.post(
    "/{tenant_id}/usuario-maestro",
    response_model=UsuarioMaestroCreado,
    status_code=status.HTTP_201_CREATED,
)
def crear_usuario_maestro(tenant_id: UUID, body: UsuarioMaestroCreate):
    """
    Crea el usuario maestro (director_general) en el Supabase del tenant.

    - Dispara el trigger sync_auth_usuario que crea el perfil en public.usuario.
    - Devuelve la contraseña EN TEXTO PLANO una sola vez. Guardarla antes de cerrar.
    - Si el tenant ya tiene usuario maestro, este endpoint lanza 409. Usar reset-password.
    """
    tenant = _get_tenant_activo(tenant_id)

    if tenant["usuario_maestro_id"] is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "error_code": "USUARIO_MAESTRO_EXISTENTE",
                "mensaje": "Este tenant ya tiene un usuario maestro. "
                "Usar /reset-password para cambiar la contraseña o "
                "/bloquear para suspenderlo.",
            },
        )

    service_role_key = descifrar_key(tenant["service_role_key_enc"])
    tenant_client = get_tenant_client(tenant["supabase_url"], service_role_key)

    try:
        response = tenant_client.auth.admin.create_user(
            {
                "email": str(body.email),
                "password": body.password,
                "app_metadata": {"rol": "director_general"},
                "user_metadata": {"nombre": body.nombre},
                "email_confirm": True,
            }
        )
    except AuthApiError as exc:
        if "already registered" in str(exc).lower() or "email_exists" in str(exc).lower():
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "error_code": "EMAIL_DUPLICADO",
                    "mensaje": f"Ya existe un usuario con el email '{body.email}' en este tenant.",
                },
            ) from exc
        log.error("error_crear_usuario_maestro", tenant_id=str(tenant_id), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "error_code": "ERROR_SUPABASE_AUTH",
                "mensaje": f"Error al crear el usuario en Supabase Auth: {exc}",
            },
        ) from exc

    usuario = response.user
    if usuario is None:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "error_code": "RESPUESTA_VACIA",
                "mensaje": "Supabase no devolvió el usuario creado.",
            },
        )

    # Actualizar el registro del tenant con los datos del usuario maestro recién creado
    get_admin_db().table("tenant").update(
        {
            "usuario_maestro_id": str(usuario.id),
            "usuario_maestro_email": str(body.email),
        }
    ).eq("id", str(tenant_id)).execute()

    log.info(
        "usuario_maestro_creado",
        tenant_id=str(tenant_id),
        subdominio=tenant["subdominio"],
        email=str(body.email),
        usuario_id=str(usuario.id),
    )

    return UsuarioMaestroCreado(
        usuario_id=usuario.id,
        email=str(body.email),
        nombre=body.nombre,
        password_temporal=body.password,
    )


@router.post("/{tenant_id}/usuario-maestro/reset-password", status_code=status.HTTP_200_OK)
def resetear_password(tenant_id: UUID, body: ResetPasswordBody):
    """
    Reemplaza la contraseña del usuario maestro del tenant.
    La nueva contraseña se devuelve en la respuesta una sola vez.
    """
    tenant = _get_tenant_activo(tenant_id)

    usuario_maestro_id: str | None = tenant["usuario_maestro_id"]
    if not usuario_maestro_id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "error_code": "SIN_USUARIO_MAESTRO",
                "mensaje": "Este tenant no tiene usuario maestro. Usar POST /usuario-maestro para crearlo.",
            },
        )

    service_role_key = descifrar_key(tenant["service_role_key_enc"])
    tenant_client = get_tenant_client(tenant["supabase_url"], service_role_key)

    try:
        tenant_client.auth.admin.update_user_by_id(
            usuario_maestro_id,
            {"password": body.nueva_password},
        )
    except AuthApiError as exc:
        log.error("error_reset_password", tenant_id=str(tenant_id), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "error_code": "ERROR_SUPABASE_AUTH",
                "mensaje": f"Error al actualizar la contraseña: {exc}",
            },
        ) from exc

    log.info(
        "password_reseteada",
        tenant_id=str(tenant_id),
        subdominio=tenant["subdominio"],
        usuario_id=usuario_maestro_id,
    )

    return {
        "mensaje": "Contraseña actualizada correctamente.",
        "nueva_password": body.nueva_password,
        "advertencia": "Esta es la única vez que se muestra la contraseña. Guardarla antes de cerrar.",
    }


@router.post("/{tenant_id}/usuario-maestro/bloquear", status_code=status.HTTP_200_OK)
def bloquear_usuario_maestro(tenant_id: UUID):
    """
    Bloquea al usuario maestro del tenant con doble mecanismo:
    1. ban_duration en Supabase Auth → impide obtener nuevos JWTs.
    2. activo = false en public.usuario → el CRM lo marca inactivo.

    Los JWTs ya emitidos siguen válidos hasta su expiración (1 hora por defecto).
    Para revocación inmediata, invalidar el JWT secret del tenant (operación mayor).
    """
    tenant = _get_tenant_activo(tenant_id)

    usuario_maestro_id: str | None = tenant["usuario_maestro_id"]
    if not usuario_maestro_id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "error_code": "SIN_USUARIO_MAESTRO",
                "mensaje": "Este tenant no tiene usuario maestro registrado.",
            },
        )

    service_role_key = descifrar_key(tenant["service_role_key_enc"])
    tenant_client = get_tenant_client(tenant["supabase_url"], service_role_key)

    try:
        # Ban en Supabase Auth — impide login y renovación de tokens
        tenant_client.auth.admin.update_user_by_id(
            usuario_maestro_id,
            {"ban_duration": "87600h"},  # 10 años ≈ permanente
        )
    except AuthApiError as exc:
        log.error("error_bloquear_auth", tenant_id=str(tenant_id), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={"error_code": "ERROR_SUPABASE_AUTH", "mensaje": str(exc)},
        ) from exc

    # Soft-block en public.usuario — el CRM también lo ve inactivo
    try:
        tenant_client.table("usuario").update({"activo": False}).eq(
            "id", usuario_maestro_id
        ).execute()
    except Exception as exc:
        # No es crítico si falla — el ban de Auth ya impide el acceso
        log.warning("error_bloquear_usuario_tabla", tenant_id=str(tenant_id), error=str(exc))

    log.info(
        "usuario_maestro_bloqueado",
        tenant_id=str(tenant_id),
        subdominio=tenant["subdominio"],
        usuario_id=usuario_maestro_id,
    )

    return {
        "mensaje": "Usuario maestro bloqueado. No puede iniciar sesión ni renovar tokens.",
        "advertencia": "JWTs ya emitidos son válidos hasta su expiración natural (máx. 1 hora).",
    }


@router.post("/{tenant_id}/usuario-maestro/desbloquear", status_code=status.HTTP_200_OK)
def desbloquear_usuario_maestro(tenant_id: UUID):
    """Levanta el bloqueo del usuario maestro y reactiva su perfil en el CRM."""
    tenant = _get_tenant_activo(tenant_id)

    usuario_maestro_id: str | None = tenant["usuario_maestro_id"]
    if not usuario_maestro_id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={
                "error_code": "SIN_USUARIO_MAESTRO",
                "mensaje": "Este tenant no tiene usuario maestro registrado.",
            },
        )

    service_role_key = descifrar_key(tenant["service_role_key_enc"])
    tenant_client = get_tenant_client(tenant["supabase_url"], service_role_key)

    try:
        tenant_client.auth.admin.update_user_by_id(
            usuario_maestro_id,
            {"ban_duration": "none"},
        )
    except AuthApiError as exc:
        log.error("error_desbloquear_auth", tenant_id=str(tenant_id), error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={"error_code": "ERROR_SUPABASE_AUTH", "mensaje": str(exc)},
        ) from exc

    try:
        tenant_client.table("usuario").update({"activo": True}).eq(
            "id", usuario_maestro_id
        ).execute()
    except Exception as exc:
        log.warning("error_desbloquear_usuario_tabla", tenant_id=str(tenant_id), error=str(exc))

    log.info(
        "usuario_maestro_desbloqueado",
        tenant_id=str(tenant_id),
        subdominio=tenant["subdominio"],
        usuario_id=usuario_maestro_id,
    )

    return {"mensaje": "Usuario maestro desbloqueado. Puede iniciar sesión nuevamente."}

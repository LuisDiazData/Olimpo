"""
Modelos Pydantic para el módulo de permisos.

Jerarquía:
  permiso          — catálogo inmutable de claves de permiso
  rol_permiso      — defaults por rol (editables por directores)
  usuario_permiso  — overrides por usuario (editables por directors y gerentes)
  permiso_audit_log — historial inmutable de cambios
"""

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from models.usuario import RolUsuario

# ---------------------------------------------------------------------------
# Catálogo de permisos
# ---------------------------------------------------------------------------

class PermisoResponse(BaseModel):
    id: UUID
    clave: str
    dominio: str
    nombre: str
    descripcion: str | None
    activo: bool
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Permisos por rol
# ---------------------------------------------------------------------------

class RolPermisoResponse(BaseModel):
    rol: RolUsuario
    permiso_id: UUID
    permiso_clave: str | None = None
    permiso_nombre: str | None = None
    concedido: bool
    created_at: datetime

    model_config = {"from_attributes": True}


class PermisoEfectivoItem(BaseModel):
    """Un permiso con su valor efectivo (override de usuario o default de rol)."""

    clave: str
    dominio: str
    nombre: str
    concedido: bool
    fuente: str = Field(description="'usuario' si es override, 'rol' si es el default del rol.")


class PermisosUsuarioResponse(BaseModel):
    usuario_id: UUID
    rol: RolUsuario
    permisos: list[PermisoEfectivoItem]


# ---------------------------------------------------------------------------
# Overrides de usuario
# ---------------------------------------------------------------------------

class UsuarioPermisoResponse(BaseModel):
    usuario_id: UUID
    permiso_id: UUID
    permiso_clave: str | None = None
    permiso_nombre: str | None = None
    concedido: bool
    otorgado_por: UUID
    otorgado_por_nombre: str | None = None
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------

class PermisoAuditLogEntry(BaseModel):
    id: UUID
    tipo: str
    permiso_id: UUID
    permiso_clave: str
    rol: RolUsuario | None
    usuario_id: UUID | None
    concedido_anterior: bool | None
    concedido_nuevo: bool | None
    realizado_por: UUID
    realizado_por_nombre: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

class OtorgarPermisoUsuarioBody(BaseModel):
    """Concede o deniega explícitamente un permiso a un usuario específico."""

    permiso_clave: str = Field(
        description="Clave del permiso. Ejemplo: 'tramites.reasignar'."
    )
    concedido: bool = Field(
        description="TRUE para conceder, FALSE para denegar explícitamente."
    )


class RevocarPermisoUsuarioBody(BaseModel):
    """Elimina el override de usuario — el permiso vuelve al default del rol."""

    permiso_clave: str = Field(
        description="Clave del permiso cuyo override se eliminará."
    )


class ConfigurarRolPermisoBody(BaseModel):
    """Modifica el permiso por defecto para un rol completo."""

    rol: RolUsuario
    permiso_clave: str = Field(
        description="Clave del permiso. Ejemplo: 'reportes.exportar'."
    )
    concedido: bool = Field(
        description="TRUE para conceder por defecto al rol, FALSE para denegar."
    )


class ConfigurarMultiplesRolPermisosBody(BaseModel):
    """Modifica varios permisos de un rol en una sola llamada."""

    rol: RolUsuario
    cambios: list[dict] = Field(
        description="Lista de {permiso_clave: str, concedido: bool}.",
        min_length=1,
        max_length=100,
    )

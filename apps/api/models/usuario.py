"""
Modelos Pydantic para el módulo de usuarios.

UsuarioToken    — datos extraídos del JWT (sin consulta a DB).
UsuarioResponse — perfil completo desde public.usuario.
UsuarioListItem — versión compacta para listados.
UsuarioCreate   — payload para crear usuario (llama Supabase Auth Admin API).
UsuarioUpdate   — campos que el propio usuario puede modificar.
UsuarioAdminUpdate — campos que el director puede modificar en cualquier usuario.
"""

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field, model_validator


class RolUsuario(StrEnum):
    director_general = "director_general"
    director_ops = "director_ops"
    gerente = "gerente"
    analista = "analista"


class RamoUsuario(StrEnum):
    vida = "vida"
    gmm = "gmm"
    autos = "autos"
    pyme = "pyme"


class UsuarioToken(BaseModel):
    """
    Identidad del usuario actual, extraída del JWT.
    No requiere consulta a la DB — viene de app_metadata del token de Supabase.
    Disponible en todos los endpoints protegidos via Depends(get_current_user).
    """

    id: UUID
    email: str
    rol: RolUsuario
    ramo: RamoUsuario | None
    access_token: str = Field(exclude=True)


class UsuarioResponse(BaseModel):
    """Perfil completo del usuario, cargado desde public.usuario."""

    id: UUID
    nombre: str
    email: EmailStr
    rol: RolUsuario
    ramo: RamoUsuario | None
    telefono: str | None
    firma_html: str | None
    activo: bool
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class UsuarioListItem(BaseModel):
    """Versión compacta para listados de usuarios."""

    id: UUID
    nombre: str
    email: EmailStr
    rol: RolUsuario
    ramo: RamoUsuario | None
    activo: bool

    model_config = {"from_attributes": True}


class UsuarioCreate(BaseModel):
    """
    Payload para crear un nuevo usuario.
    Solo directores pueden invocar este endpoint.
    La creación ocurre en Supabase Auth Admin API; el trigger sync_auth_usuario
    crea automáticamente el perfil en public.usuario.
    """

    nombre: str = Field(min_length=2, max_length=100)
    email: EmailStr
    rol: RolUsuario
    ramo: RamoUsuario | None = None
    telefono: str | None = Field(
        default=None,
        max_length=20,
        pattern=r"^\+?[\d\s\-\(\)]{7,20}$",
    )
    firma_html: str | None = Field(default=None, max_length=5000)

    @model_validator(mode="after")
    def validar_ramo_segun_rol(self) -> "UsuarioCreate":
        if self.rol in (RolUsuario.gerente, RolUsuario.analista) and self.ramo is None:
            raise ValueError(f"El rol '{self.rol}' requiere un ramo.")
        if self.rol in (RolUsuario.director_general, RolUsuario.director_ops) and self.ramo is not None:
            raise ValueError(f"El rol '{self.rol}' no puede tener ramo asignado.")
        return self


class UsuarioUpdate(BaseModel):
    """
    Campos que el propio usuario puede actualizar en su perfil.
    rol, ramo y activo NO se incluyen — exclusivos del director.
    """

    telefono: str | None = Field(
        default=None,
        max_length=20,
        pattern=r"^\+?[\d\s\-\(\)]{7,20}$",
        description="Teléfono de contacto. Aparece en la firma de correos.",
    )
    firma_html: str | None = Field(
        default=None,
        max_length=5000,
        description="HTML completo de la firma corporativa para el Agente 6.",
    )


class UsuarioAdminUpdate(BaseModel):
    """
    Campos que el director puede modificar en cualquier usuario.
    Incluye campos que el propio usuario no puede cambiar.
    """

    nombre: str | None = Field(default=None, min_length=2, max_length=100)
    telefono: str | None = Field(
        default=None,
        max_length=20,
        pattern=r"^\+?[\d\s\-\(\)]{7,20}$",
    )
    firma_html: str | None = Field(default=None, max_length=5000)
    activo: bool | None = None

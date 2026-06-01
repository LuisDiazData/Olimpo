"""
Endpoints de sistema: salud del servicio y perfil del usuario autenticado.

GET /health  â€” sin autenticaciÃ³n. Railway lo usa como health check.
GET /me      â€” requiere JWT vÃ¡lido. Devuelve el perfil completo desde la DB.
PATCH /me    â€” requiere JWT vÃ¡lido. Actualiza telÃ©fono y firma_html del usuario.
"""

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from supabase import Client

from core.auth import get_current_user
from core.database import get_db
from models.usuario import UsuarioResponse, UsuarioToken, UsuarioUpdate

log = structlog.get_logger(__name__)
router = APIRouter(tags=["sistema"])


@router.get("/health", summary="Health check")
def health() -> dict:
    """Sin autenticación. Verifica que el proceso está activo."""
    return {"status": "ok", "servicio": "olimpo-api"}


@router.get("/test-error", summary="Forzar error para verificar Sentry", include_in_schema=False)
def test_error() -> dict:
    raise RuntimeError("Error de prueba — Sentry funcionando correctamente.")


@router.get(
    "/me",
    response_model=UsuarioResponse,
    summary="Perfil del usuario autenticado",
)
def get_me(
    usuario: UsuarioToken = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UsuarioResponse:
    """
    Devuelve el perfil completo del usuario desde public.usuario.
    El cliente Supabase usa el JWT del usuario, por lo que RLS aplica:
    pol_usuario_select_propio garantiza que solo vea su propia fila.
    """
    result = (
        db.table("usuario")
        .select("id, nombre, email, rol, ramo, telefono, firma_html, activo")
        .eq("id", str(usuario.id))
        .maybe_single()
        .execute()
    )

    if not result.data:
        log.warning("perfil_no_encontrado", usuario_id=str(usuario.id))
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Perfil de usuario no encontrado. Contacta al administrador.",
        )

    return UsuarioResponse.model_validate(result.data)


@router.patch(
    "/me",
    response_model=UsuarioResponse,
    summary="Actualizar perfil del usuario autenticado",
)
def update_me(
    body: UsuarioUpdate,
    usuario: UsuarioToken = Depends(get_current_user),
    db: Client = Depends(get_db),
) -> UsuarioResponse:
    """
    Actualiza telÃ©fono y/o firma_html del usuario.
    El usuario no puede cambiar su propio rol, ramo ni estado activo
    (la policy RLS pol_usuario_update_propio lo impide en la DB).
    """
    cambios = body.model_dump(exclude_none=True)

    if not cambios:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="No se enviaron campos para actualizar.",
        )

    result = (
        db.table("usuario")
        .update(cambios)
        .eq("id", str(usuario.id))
        .select("id, nombre, email, rol, ramo, telefono, firma_html, activo")
        .execute()
    )
    if result.data:
        result.data = result.data[0]

    if not result.data:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No se pudo actualizar el perfil.",
        )

    log.info("perfil_actualizado", usuario_id=str(usuario.id), campos=list(cambios.keys()))
    return UsuarioResponse.model_validate(result.data)

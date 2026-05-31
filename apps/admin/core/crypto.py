"""
Cifrado/descifrado de service_role_keys de tenants.

Usa Fernet (AES-128-CBC + HMAC-SHA256) de la librería `cryptography`.
La clave maestra vive en ADMIN_ENCRYPTION_KEY y nunca se persiste en DB.

Si se pierde ADMIN_ENCRYPTION_KEY, las keys cifradas en tenant son irrecuperables.
Hacer backup de la clave maestra en un gestor de secretos (ej: Railway secrets).
"""

from cryptography.fernet import Fernet, InvalidToken
from fastapi import HTTPException, status

from core.config import get_settings


def _fernet() -> Fernet:
    s = get_settings()
    return Fernet(s.ADMIN_ENCRYPTION_KEY.encode())


def cifrar_key(plaintext: str) -> str:
    """Cifra una service_role_key en texto plano. Devuelve token Fernet (base64)."""
    return _fernet().encrypt(plaintext.encode()).decode()


def descifrar_key(ciphertext: str) -> str:
    """
    Descifra una service_role_key cifrada con Fernet.
    Lanza HTTP 500 si el token es inválido (clave maestra incorrecta o datos corruptos).
    """
    try:
        return _fernet().decrypt(ciphertext.encode()).decode()
    except (InvalidToken, Exception) as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={
                "error_code": "DESCIFRADO_FALLIDO",
                "mensaje": "No se pudo descifrar la credencial del tenant. "
                "Verifica que ADMIN_ENCRYPTION_KEY es correcta.",
            },
        ) from exc

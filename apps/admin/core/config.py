from functools import lru_cache
from typing import Literal

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore",
    )

    # -------------------------------------------------------------------------
    # Supabase del Superadmin (donde vive la tabla tenant)
    # -------------------------------------------------------------------------
    ADMIN_SUPABASE_URL: str
    ADMIN_SUPABASE_SERVICE_ROLE_KEY: str

    # -------------------------------------------------------------------------
    # Autenticación del Superadmin
    # -------------------------------------------------------------------------
    ADMIN_API_KEY: str

    # -------------------------------------------------------------------------
    # Cifrado de service_role_keys de los tenants
    # Clave Fernet válida (44 chars base64). Generada con Fernet.generate_key().
    # -------------------------------------------------------------------------
    ADMIN_ENCRYPTION_KEY: str

    # -------------------------------------------------------------------------
    # Control de acceso por IP
    # Coma-separado. Ej: "1.2.3.4,5.6.7.8"
    # -------------------------------------------------------------------------
    ADMIN_ALLOWED_IPS: str = "127.0.0.1,::1"

    # Número de proxies de confianza delante de la app (en Railway: 1).
    # La IP real del cliente es el N-ésimo valor desde el final de X-Forwarded-For.
    # NO usar el primer valor del header: ese lo controla el cliente y es falsificable.
    ADMIN_TRUSTED_PROXY_COUNT: int = 1

    # -------------------------------------------------------------------------
    # App
    # -------------------------------------------------------------------------
    ENVIRONMENT: Literal["development", "staging", "production"] = "development"

    @field_validator("ADMIN_SUPABASE_URL")
    @classmethod
    def supabase_url_no_trailing_slash(cls, v: str) -> str:
        return v.rstrip("/")

    @field_validator("ADMIN_ENCRYPTION_KEY")
    @classmethod
    def validar_fernet_key(cls, v: str) -> str:
        from cryptography.fernet import Fernet

        try:
            # Verificar que la clave es válida intentando crear un Fernet con ella
            Fernet(v.encode())
        except Exception as exc:
            raise ValueError(
                "ADMIN_ENCRYPTION_KEY no es una clave Fernet válida. "
                'Generar con: python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"'
            ) from exc
        return v

    @property
    def allowed_ips(self) -> set[str]:
        return {ip.strip() for ip in self.ADMIN_ALLOWED_IPS.split(",") if ip.strip()}

    @property
    def is_production(self) -> bool:
        return self.ENVIRONMENT == "production"


@lru_cache
def get_settings() -> Settings:
    return Settings()

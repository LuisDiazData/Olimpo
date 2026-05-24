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
    # Supabase
    # -------------------------------------------------------------------------
    SUPABASE_URL: str
    SUPABASE_ANON_KEY: str
    SUPABASE_SERVICE_ROLE_KEY: str
    SUPABASE_JWT_SECRET: str

    # -------------------------------------------------------------------------
    # LLMs
    # -------------------------------------------------------------------------
    OPENAI_API_KEY: str = ""
    ANTHROPIC_API_KEY: str = ""
    RUNPOD_API_KEY: str = ""
    RUNPOD_ENDPOINT_OCR: str = ""

    # -------------------------------------------------------------------------
    # Google Workspace
    # -------------------------------------------------------------------------
    GOOGLE_SERVICE_ACCOUNT_JSON: str = ""
    GOOGLE_WORKSPACE_DOMAIN: str = ""

    # -------------------------------------------------------------------------
    # Observabilidad
    # -------------------------------------------------------------------------
    LOGFIRE_TOKEN: str = ""
    SENTRY_DSN: str = ""

    # -------------------------------------------------------------------------
    # App
    # -------------------------------------------------------------------------
    ENVIRONMENT: Literal["development", "staging", "production"] = "development"
    CORS_ORIGINS: str = "http://localhost:3000"

    # -------------------------------------------------------------------------
    # Umbrales de IA (fallback — la fuente canónica es configuracion_sistema en DB)
    # -------------------------------------------------------------------------
    CONFIDENCE_AGENTE: float = 0.75
    CONFIDENCE_DOCUMENTO: float = 0.70
    CONFIDENCE_VINCULACION: float = 0.85
    FUZZY_MATCH_NOMBRE: float = 0.85
    TIMEOUT_PASSWORD_HORAS: int = 24

    @field_validator("SUPABASE_URL")
    @classmethod
    def supabase_url_no_trailing_slash(cls, v: str) -> str:
        return v.rstrip("/")

    @property
    def cors_origins_list(self) -> list[str]:
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]

    @property
    def is_production(self) -> bool:
        return self.ENVIRONMENT == "production"


@lru_cache
def get_settings() -> Settings:
    return Settings()

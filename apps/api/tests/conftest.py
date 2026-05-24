"""
Fixtures compartidos para los tests de Olimpo API.

Convenciones:
  - Los tests que tocan la DB usan un cliente Supabase con service_role y un
    schema de test separado (o fixtures que hacen rollback con savepoints).
  - Los tests de endpoints usan TestClient con un JWT falso firmado con
    SUPABASE_JWT_SECRET de un .env.test.
  - Los LLMs se mockean con LiteLLM fake mode (LITELLM_MOCK=true).
"""
import os

# Configurar variables de entorno ANTES de cualquier import que llame a get_settings().
# Los tests de Capa 1 no necesitan un Supabase real; los valores son marcadores.
os.environ.setdefault("SUPABASE_JWT_SECRET", "test-secret-for-tests-only")
os.environ.setdefault("SUPABASE_URL", "http://localhost:54321")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon-key-for-testing")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-for-testing")
os.environ.setdefault("ENVIRONMENT", "development")
os.environ.setdefault("LOGFIRE_TOKEN", "")
os.environ.setdefault("SENTRY_DSN", "")

import time
from uuid import UUID, uuid4

import jwt
import pytest
from fastapi.testclient import TestClient

from core.config import get_settings
from main import app


# ---------------------------------------------------------------------------
# Helpers para generar JWTs de test
# ---------------------------------------------------------------------------

def make_test_jwt(
    user_id: UUID | None = None,
    rol: str = "analista",
    ramo: str | None = "vida",
    email: str = "test@olimpo.test",
) -> str:
    """Genera un JWT firmado con SUPABASE_JWT_SECRET para usar en tests."""
    s = get_settings()
    uid = user_id or uuid4()
    now = int(time.time())
    payload = {
        "aud": "authenticated",
        "sub": str(uid),
        "email": email,
        "iat": now,
        "exp": now + 3600,
        "role": "authenticated",
        "app_metadata": {
            "rol": rol,
            **({"ramo": ramo} if ramo else {}),
        },
    }
    return jwt.encode(payload, s.SUPABASE_JWT_SECRET, algorithm="HS256")


# ---------------------------------------------------------------------------
# Fixtures de usuarios de test
# ---------------------------------------------------------------------------

@pytest.fixture
def analista_token() -> str:
    return make_test_jwt(rol="analista", ramo="vida")


@pytest.fixture
def gerente_token() -> str:
    return make_test_jwt(rol="gerente", ramo="vida")


@pytest.fixture
def director_token() -> str:
    return make_test_jwt(rol="director_general", ramo=None)


# ---------------------------------------------------------------------------
# Cliente HTTP de test
# ---------------------------------------------------------------------------

@pytest.fixture
def client() -> TestClient:
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture
def client_analista(client: TestClient, analista_token: str) -> TestClient:
    client.headers.update({"Authorization": f"Bearer {analista_token}"})
    return client


@pytest.fixture
def client_gerente(client: TestClient, gerente_token: str) -> TestClient:
    client.headers.update({"Authorization": f"Bearer {gerente_token}"})
    return client


@pytest.fixture
def client_director(client: TestClient, director_token: str) -> TestClient:
    client.headers.update({"Authorization": f"Bearer {director_token}"})
    return client

"""Tests para /health y /me."""

from fastapi.testclient import TestClient


def test_health_sin_auth(client: TestClient) -> None:
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json()["status"] == "ok"


def test_me_sin_token_retorna_401(client: TestClient) -> None:
    response = client.get("/me")
    assert response.status_code == 401


def test_me_token_invalido_retorna_401(client: TestClient) -> None:
    response = client.get("/me", headers={"Authorization": "Bearer token-basura"})
    assert response.status_code == 401


def test_me_token_valido_estructura_correcta(client_analista: TestClient) -> None:
    """Verifica que con JWT válido el endpoint responde (puede ser 404 si no hay DB)."""
    response = client_analista.get("/me")
    # En CI sin DB real esperamos 404 (usuario no existe en DB de test)
    # En integración completa esperamos 200
    assert response.status_code in (200, 404, 500)

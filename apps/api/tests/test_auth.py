"""
Tests de autenticación JWT — Capa 1 (sin DB).

Cubre:
  - get_current_user: token válido, expirado, sin rol, rol inválido
  - require_roles: rol correcto, rol incorrecto, múltiples roles
  - get_current_user_or_agent: sin credenciales, con JWT Bearer
"""

import time
from uuid import UUID, uuid4

import jwt
import pytest
from fastapi import HTTPException
from fastapi.security import HTTPAuthorizationCredentials

from core.auth import get_current_user, get_current_user_or_agent, require_roles
from core.config import get_settings
from models.usuario import RamoUsuario, RolUsuario, UsuarioToken
from tests.conftest import make_test_jwt

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _creds(token: str) -> HTTPAuthorizationCredentials:
    return HTTPAuthorizationCredentials(scheme="Bearer", credentials=token)


def _make_jwt(extra_metadata: dict, expired: bool = False) -> str:
    s = get_settings()
    now = int(time.time())
    payload = {
        "aud": "authenticated",
        "sub": str(uuid4()),
        "email": "test@olimpo.test",
        "iat": now - 7200 if expired else now,
        "exp": now - 3600 if expired else now + 3600,
        "role": "authenticated",
        "app_metadata": extra_metadata,
    }
    return jwt.encode(payload, s.SUPABASE_JWT_SECRET, algorithm="HS256")


# ---------------------------------------------------------------------------
# get_current_user
# ---------------------------------------------------------------------------


class TestGetCurrentUser:
    def test_jwt_valido_analista_retorna_usuario_correcto(self):
        token = make_test_jwt(rol="analista", ramo="vida")
        user = get_current_user(_creds(token))

        assert isinstance(user.id, UUID)
        assert user.rol == RolUsuario.analista
        assert user.ramo == RamoUsuario.vida
        assert user.email == "test@olimpo.test"
        assert user.access_token == token

    def test_jwt_valido_director_sin_ramo(self):
        token = make_test_jwt(rol="director_general", ramo=None)
        user = get_current_user(_creds(token))

        assert user.rol == RolUsuario.director_general
        assert user.ramo is None

    def test_jwt_valido_gerente_con_ramo_gmm(self):
        token = make_test_jwt(rol="gerente", ramo="gmm")
        user = get_current_user(_creds(token))

        assert user.rol == RolUsuario.gerente
        assert user.ramo == RamoUsuario.gmm

    def test_jwt_expirado_lanza_401(self):
        token = _make_jwt({"rol": "analista", "ramo": "vida"}, expired=True)
        with pytest.raises(HTTPException) as exc:
            get_current_user(_creds(token))

        assert exc.value.status_code == 401
        assert "expirada" in exc.value.detail.lower()

    def test_jwt_sin_rol_lanza_403(self):
        token = _make_jwt({})  # app_metadata vacío
        with pytest.raises(HTTPException) as exc:
            get_current_user(_creds(token))

        assert exc.value.status_code == 403
        assert "rol" in exc.value.detail.lower()

    def test_jwt_rol_invalido_lanza_403(self):
        token = _make_jwt({"rol": "superadmin_no_existe"})
        with pytest.raises(HTTPException) as exc:
            get_current_user(_creds(token))

        assert exc.value.status_code == 403
        assert "Rol desconocido" in exc.value.detail

    def test_jwt_completamente_invalido_lanza_401(self):
        with pytest.raises(HTTPException) as exc:
            get_current_user(_creds("esto.no.es.un.jwt.valido"))

        assert exc.value.status_code == 401

    def test_jwt_firmado_con_clave_distinta_lanza_401(self):
        payload = {
            "aud": "authenticated",
            "sub": str(uuid4()),
            "email": "hacker@olimpo.test",
            "iat": int(time.time()),
            "exp": int(time.time()) + 3600,
            "role": "authenticated",
            "app_metadata": {"rol": "director_general"},
        }
        token_malo = jwt.encode(payload, "clave-incorrecta", algorithm="HS256")
        with pytest.raises(HTTPException) as exc:
            get_current_user(_creds(token_malo))

        assert exc.value.status_code == 401


# ---------------------------------------------------------------------------
# require_roles
# ---------------------------------------------------------------------------


class TestRequireRoles:
    def _usuario(self, rol: RolUsuario, ramo: RamoUsuario | None = None) -> UsuarioToken:
        return UsuarioToken(
            id=uuid4(),
            email="x@olimpo.test",
            rol=rol,
            ramo=ramo,
            access_token="fake-token",
        )

    def test_rol_correcto_pasa_sin_excepcion(self):
        checker = require_roles(RolUsuario.director_general, RolUsuario.gerente)
        user = self._usuario(RolUsuario.gerente, RamoUsuario.vida)
        result = checker(usuario=user)
        assert result.rol == RolUsuario.gerente

    def test_rol_incorrecto_lanza_403(self):
        checker = require_roles(RolUsuario.director_general)
        user = self._usuario(RolUsuario.analista, RamoUsuario.vida)
        with pytest.raises(HTTPException) as exc:
            checker(usuario=user)
        assert exc.value.status_code == 403
        assert "Acceso denegado" in exc.value.detail

    def test_todos_los_roles_validos_pasan(self):
        roles = [RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente]
        checker = require_roles(*roles)
        for rol in roles:
            user = self._usuario(rol)
            result = checker(usuario=user)
            assert result.rol == rol

    def test_analista_no_pasa_restriccion_de_gerentes(self):
        checker = require_roles(
            RolUsuario.director_general, RolUsuario.director_ops, RolUsuario.gerente
        )
        user = self._usuario(RolUsuario.analista, RamoUsuario.autos)
        with pytest.raises(HTTPException) as exc:
            checker(usuario=user)
        assert exc.value.status_code == 403


# ---------------------------------------------------------------------------
# get_current_user_or_agent
# ---------------------------------------------------------------------------


class TestGetCurrentUserOrAgent:
    def test_sin_credenciales_lanza_401_con_error_code(self):
        with pytest.raises(HTTPException) as exc:
            get_current_user_or_agent(credentials=None, api_key=None)

        assert exc.value.status_code == 401
        assert exc.value.detail["error_code"] == "AUTENTICACION_REQUERIDA"

    def test_con_jwt_bearer_valido_retorna_usuario(self):
        token = make_test_jwt(rol="gerente", ramo="gmm")
        creds = _creds(token)
        user = get_current_user_or_agent(credentials=creds, api_key=None)

        assert user.rol == RolUsuario.gerente
        assert user.ramo == RamoUsuario.gmm

    def test_jwt_bearer_tiene_prioridad_sobre_api_key_nula(self):
        token = make_test_jwt(rol="analista", ramo="vida")
        creds = _creds(token)
        user = get_current_user_or_agent(credentials=creds, api_key=None)
        assert user.rol == RolUsuario.analista

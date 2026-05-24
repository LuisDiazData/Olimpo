-- =============================================================================
-- Migración: 20260522000017_agent_api_keys.sql
-- Autenticación de agentes externos vía API key (para MCP)
-- =============================================================================
-- Permite que agentes de IA externos (vía Model Context Protocol) autentiquen
-- contra la API de Olimpo usando una API key de larga duración, sin necesidad
-- de hacer login interactivo con Supabase Auth.
--
-- Problema que resuelve:
--   Los JWT de Supabase expiran en 1 hora y requieren un usuario humano para
--   renovarse. Un agente MCP que corre de forma autónoma (ej: pipeline nocturno,
--   agente de revisión, cliente externo) no puede hacer login interactivo.
--
-- Diseño de seguridad:
--   - Solo se almacena el HASH SHA-256 de la key — nunca la key en texto plano.
--   - La key real se entrega UNA sola vez al crearla (igual que tokens de GitHub).
--   - Cada key tiene un rol y ramo asignados: sigue las mismas reglas RLS.
--   - Las keys pueden tener fecha de expiración o ser indefinidas.
--   - Solo service_role (Superadmin) puede crear/revocar keys.
--   - audit_log registra cada uso (via trigger).
--
-- Uso en el backend FastAPI:
--   Header: X-Agent-API-Key: <key>
--   El middleware valida key_hash = sha256(key) y construye un UsuarioToken sintético.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TABLA agent_api_keys
-- =============================================================================

CREATE TABLE agent_api_keys (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identificación de la key
    -- -------------------------------------------------------------------------
    -- Nombre descriptivo para identificar a qué agente o servicio pertenece
    -- Ej: 'agente_mcp_pipeline', 'cliente_externo_consultora_x', 'n8n_workflow'
    nombre          TEXT            NOT NULL,

    -- Hash SHA-256 de la API key en texto plano.
    -- La key real NUNCA se almacena — solo este hash.
    -- El middleware compara: sha256(key_recibida) == key_hash
    key_hash        TEXT            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Permisos del agente — mismos valores que usuarios humanos
    -- -------------------------------------------------------------------------
    -- El agente opera con este rol (determina las RLS policies que aplican)
    rol             rol_usuario     NOT NULL,

    -- Ramo al que tiene acceso este agente (NULL = acceso a todos los ramos)
    -- Un agente con rol='gerente' y ramo='vida' solo ve datos de vida
    ramo            ramo_usuario    NULL,

    -- -------------------------------------------------------------------------
    -- Estado y vigencia
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- NULL = la key no expira (para integraciones permanentes)
    -- NOT NULL = la key expira en esa fecha (para acceso temporal)
    expira_en       TIMESTAMPTZ     NULL,

    -- Descripción del propósito o contexto de uso de esta key
    descripcion     TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Quién creó esta key (debe ser un superadmin)
    creado_por      UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_agent_api_keys_hash    UNIQUE (key_hash),
    CONSTRAINT ck_agent_api_keys_nombre  CHECK (TRIM(nombre) <> ''),
    CONSTRAINT ck_agent_api_keys_hash    CHECK (LENGTH(key_hash) = 64)  -- SHA-256 hex = 64 chars
);

COMMENT ON TABLE agent_api_keys IS
    'API keys de larga duración para agentes externos (MCP, n8n, integraciones). '
    'Solo almacena el hash SHA-256 — nunca la key en texto plano. '
    'Cada key tiene un rol y ramo asignados que determinan su acceso vía RLS. '
    'Solo service_role (Superadmin) puede crear o revocar keys.';

COMMENT ON COLUMN agent_api_keys.key_hash   IS 'SHA-256 hex del token. 64 caracteres. La key real se entrega una sola vez al crear.';
COMMENT ON COLUMN agent_api_keys.nombre     IS 'Nombre descriptivo del agente o servicio. Ej: agente_mcp_pipeline, n8n_workflow_gnp.';
COMMENT ON COLUMN agent_api_keys.rol        IS 'Rol con el que opera el agente — determina policies RLS aplicables.';
COMMENT ON COLUMN agent_api_keys.ramo       IS 'Ramo al que tiene acceso. NULL = todos los ramos (solo para directores/service).';
COMMENT ON COLUMN agent_api_keys.expira_en  IS 'Fecha de expiración. NULL = sin expiración. El middleware rechaza keys expiradas.';


-- =============================================================================
-- SECCIÓN 2: ÍNDICES
-- =============================================================================

-- Búsqueda por hash en cada request autenticado con API key (hot path)
CREATE INDEX idx_agent_keys_hash
    ON agent_api_keys (key_hash)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_agent_keys_hash IS
    'Hot path: validación de API key en cada request MCP. '
    'Parcial: solo keys activas — las revocadas no se consultan.';

-- Listar keys activas por rol (Superadmin)
CREATE INDEX idx_agent_keys_rol
    ON agent_api_keys (rol, activo);

-- Detectar keys próximas a expirar (job de alertas)
CREATE INDEX idx_agent_keys_expiracion
    ON agent_api_keys (expira_en)
    WHERE expira_en IS NOT NULL AND activo = TRUE;

COMMENT ON INDEX idx_agent_keys_expiracion IS
    'Job de alertas: keys que expiran en los próximos 7 días para notificar al Superadmin.';


-- =============================================================================
-- SECCIÓN 3: TRIGGER updated_at
-- =============================================================================

CREATE TRIGGER trg_agent_api_keys_updated_at
    BEFORE UPDATE ON agent_api_keys
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 4: ROW LEVEL SECURITY
-- =============================================================================
-- Solo service_role puede leer y escribir en esta tabla.
-- authenticated (usuarios del CRM) NO pueden ver ni gestionar API keys —
-- eso es exclusivo del Superadmin en admin.olimpo.mx con service_role.

ALTER TABLE agent_api_keys ENABLE ROW LEVEL SECURITY;

-- Ninguna policy para authenticated → acceso denegado por defecto
-- service_role bypasa RLS por diseño de Supabase

COMMENT ON TABLE agent_api_keys IS
    'API keys de larga duración para agentes externos (MCP, n8n, integraciones). '
    'RLS: sin policies para authenticated → solo service_role (Superadmin) tiene acceso. '
    'Solo almacena key_hash SHA-256 — la key real se entrega una sola vez al crear.';


-- =============================================================================
-- SECCIÓN 5: FUNCIÓN DE VALIDACIÓN (helper para el backend FastAPI)
-- =============================================================================
-- El backend llama esta función con service_role para validar una API key.
-- Retorna NULL si la key es inválida, expirada o revocada.
-- Retorna el registro completo si es válida.
--
-- Uso en Python (core/auth.py):
--   result = admin_db.rpc('validar_agent_api_key', {'p_key_hash': sha256_hex}).execute()
--   if result.data is None:
--       raise HTTPException(401, "API key inválida")
-- =============================================================================

CREATE OR REPLACE FUNCTION validar_agent_api_key(p_key_hash TEXT)
RETURNS agent_api_keys
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_key agent_api_keys;
BEGIN
    SELECT * INTO v_key
    FROM agent_api_keys
    WHERE key_hash = p_key_hash
      AND activo   = TRUE;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Verificar expiración
    IF v_key.expira_en IS NOT NULL AND v_key.expira_en < NOW() THEN
        RETURN NULL;
    END IF;

    RETURN v_key;
END;
$$;

COMMENT ON FUNCTION validar_agent_api_key(TEXT) IS
    'Valida una API key de agente por su hash SHA-256. '
    'Retorna NULL si la key no existe, está revocada o expiró. '
    'Llamada con service_role desde el middleware de FastAPI. '
    'No registra el uso — eso lo hace el middleware con audit_log.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000017_agent_api_keys.sql
-- =============================================================================

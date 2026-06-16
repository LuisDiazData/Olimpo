-- =============================================================================
-- Migración: 20260614000002_modulo_15_campanas.sql
-- Módulo 15 — Campañas de Marketing y Broadcasts
-- =============================================================================

CREATE TYPE estado_campana AS ENUM (
    'borrador',
    'enviando',
    'completada'
);

CREATE TYPE estado_envio AS ENUM (
    'pendiente',
    'enviado',
    'error'
);

CREATE TABLE campana (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo              TEXT            NOT NULL,
    asunto              TEXT            NOT NULL,
    cuerpo_html         TEXT            NOT NULL,
    ramo_objetivo       TEXT            NULL,  -- NULL = Todos
    estado              estado_campana  NOT NULL DEFAULT 'borrador',
    created_by          UUID            NOT NULL REFERENCES usuario(id),
    
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE TABLE campana_destinatario (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    campana_id          UUID            NOT NULL REFERENCES campana(id) ON DELETE CASCADE,
    agente_id           UUID            NOT NULL REFERENCES agente(id),
    email_destino       TEXT            NOT NULL,
    estado_envio        estado_envio    NOT NULL DEFAULT 'pendiente',
    fecha_apertura      TIMESTAMPTZ     NULL,
    error_msg           TEXT            NULL,
    
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- RLS

ALTER TABLE campana ENABLE ROW LEVEL SECURITY;
ALTER TABLE campana_destinatario ENABLE ROW LEVEL SECURITY;

CREATE POLICY pol_campana_select
    ON campana FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_campana_insert
    ON campana FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_campana_update
    ON campana FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_destinatario_select
    ON campana_destinatario FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

GRANT SELECT, INSERT, UPDATE ON TABLE campana TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE campana_destinatario TO authenticated;

-- El tracker endpoint necesitará anon para actualizar apertura. 
-- Pero FastAPI usa la DB mediante service_role en endpoints públicos si es necesario.

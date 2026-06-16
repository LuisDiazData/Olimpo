-- =============================================================================
-- Migración: 20260614000000_modulo_13_reclutamiento_agentes.sql
-- Módulo 13 — Pipeline de Reclutamiento de Agentes (CRM Comercial)
-- =============================================================================

CREATE TYPE estado_prospecto AS ENUM (
    'entrevista',
    'evaluacion_gnp',
    'examenes_cnsf',
    'certificacion_gnp',
    'aprobado',
    'rechazado'
);

COMMENT ON TYPE estado_prospecto IS 'Estados del embudo de reclutamiento de agentes.';

CREATE TABLE prospecto (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre              TEXT            NOT NULL,
    email               TEXT            NOT NULL,
    telefono            TEXT            NULL,
    estado              estado_prospecto NOT NULL DEFAULT 'entrevista',
    origen              TEXT            NULL,
    notas               TEXT            NULL,
    reclutador_id       UUID            NULL REFERENCES usuario(id),
    agente_creado_id    UUID            NULL REFERENCES agente(id),
    
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    
    CONSTRAINT ck_prospecto_nombre CHECK (TRIM(nombre) <> '')
);

COMMENT ON TABLE prospecto IS 'Leads o prospectos para el reclutamiento de nuevos agentes.';

-- Trigger para updated_at
CREATE TRIGGER trg_prospecto_updated_at
    BEFORE UPDATE ON prospecto
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- RLS (Row Level Security)
-- =============================================================================

ALTER TABLE prospecto ENABLE ROW LEVEL SECURITY;

-- Solo Gerentes, Directores y Ops pueden ver o editar el pipeline de reclutamiento
CREATE POLICY pol_prospecto_select
    ON prospecto
    FOR SELECT
    TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_prospecto_insert
    ON prospecto
    FOR INSERT
    TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_prospecto_update
    ON prospecto
    FOR UPDATE
    TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_prospecto_delete
    ON prospecto
    FOR DELETE
    TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE prospecto TO authenticated;

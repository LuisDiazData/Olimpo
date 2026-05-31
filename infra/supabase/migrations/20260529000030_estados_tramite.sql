-- =============================================================================
-- Migración: 20260529000030_estados_tramite.sql
-- Rediseño de la máquina de estados del trámite
-- cat_estado_tramite (10 estados) + estado_tramite_transicion (flujo válido)
-- Ver docs en CLAUDE.md § Trámite State Machine
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tabla catálogo de estados
-- ---------------------------------------------------------------------------

CREATE TABLE cat_estado_tramite (
    id                  TEXT        PRIMARY KEY,
    etiqueta            TEXT        NOT NULL,
    descripcion         TEXT        NOT NULL,
    es_terminal         BOOLEAN     NOT NULL DEFAULT FALSE,
    es_bloqueante       BOOLEAN     NOT NULL DEFAULT FALSE,
    color_hex           TEXT        NOT NULL,
    orden_ui            INTEGER     NOT NULL,
    requiere_accion     BOOLEAN     NOT NULL DEFAULT FALSE,
    creado_en           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE cat_estado_tramite IS
    'Catálogo de estados del trámite. '
    'Incluye metadatos para UI (color, etiqueta), '
    'semántica (terminal vs activo) y reglas de flujo.';

-- ---------------------------------------------------------------------------
-- 2. Poblar los 10 estados
-- ---------------------------------------------------------------------------

INSERT INTO cat_estado_tramite
    (id, etiqueta, descripcion, es_terminal, es_bloqueante, color_hex, orden_ui, requiere_accion)
VALUES
-- ── Activos ──────────────────────────────────────────────────────────────────
('recibido',
 'Recibido',
 'El trámite llegó por correo y aún no ha sido asignado a un analista.',
 FALSE, FALSE, '#94a3b8', 10, FALSE),

('en_revision',
 'En revisión',
 'El analista está trabajando activamente en el trámite.',
 FALSE, FALSE, '#3b82f6', 20, FALSE),

('pendiente_documentos_agente',
 'Docs. pendientes',
 'Faltan documentos. Se le solicitó al agente y se espera respuesta.',
 FALSE, TRUE, '#f59e0b', 30, TRUE),

('turnado_a_gnp',
 'Turnado a GNP',
 'Documentación completa. El trámite fue enviado a GNP para procesamiento.',
 FALSE, FALSE, '#8b5cf6', 40, FALSE),

('activado_gnp',
 'Activado por GNP',
 'GNP devolvió el trámite solicitando complemento/documentación. '
     'El analista debe atender y reenviar.',
 FALSE, TRUE, '#f97316', 50, TRUE),

('complemento_en_revision',
 'Complemento en revisión',
 'El analista está procesando el complemento solicitado por GNP.',
 FALSE, FALSE, '#06b6d4', 60, FALSE),

('escalado',
 'Escalado',
 'El trámite fue escalado al gerente o director para intervención manual.',
 FALSE, FALSE, '#ec4899', 70, TRUE),

-- ── Terminales ────────────────────────────────────────────────────────────────
('completado',
 'Completado',
 'GNP aprobó la solicitud. El trámite culminó con éxito.',
 TRUE, FALSE, '#22c55e', 90, FALSE),

('rechazado_gnp',
 'Rechazado por GNP',
 'GNP rechazó la solicitud. El trámite no prosperó.',
 TRUE, FALSE, '#ef4444', 95, FALSE),

('cancelado',
 'Cancelado',
 'El agente o el equipo cancelaron la solicitud antes de cualquier resolución.',
 TRUE, FALSE, '#6b7280', 99, FALSE);

-- ---------------------------------------------------------------------------
-- 3. Tabla de transiciones válidas
-- ---------------------------------------------------------------------------

CREATE TABLE estado_tramite_transicion (
    estado_origen_id   TEXT    NOT NULL REFERENCES cat_estado_tramite(id) ON DELETE CASCADE,
    estado_destino_id  TEXT    NOT NULL REFERENCES cat_estado_tramite(id) ON DELETE CASCADE,
    CHECK (estado_origen_id <> estado_destino_id),
    PRIMARY KEY (estado_origen_id, estado_destino_id)
);

COMMENT ON TABLE estado_tramite_transicion IS
    'Define las transiciones de estado válidas. '
    'Una fila (origen, destino) significa que se puede pasar de origen a destino.';

-- ---------------------------------------------------------------------------
-- 4. Poblar transiciones válidas
-- ---------------------------------------------------------------------------

-- Flujo normal
INSERT INTO estado_tramite_transicion (estado_origen_id, estado_destino_id) VALUES
-- Entrada al flujo
('recibido',                  'en_revision'),

-- De revisión se puede pedir docs o turnar
('en_revision',               'pendiente_documentos_agente'),
('en_revision',               'turnado_a_gnp'),

-- Docs pendientes: o se reopens o se cancela
('pendiente_documentos_agente', 'en_revision'),
('pendiente_documentos_agente', 'cancelado'),

-- Turnado a GNP: 3 posibles resultados
('turnado_a_gnp',             'activado_gnp'),    -- GNP pide complemento
('turnado_a_gnp',             'completado'),      -- GNP aprueba
('turnado_a_gnp',             'rechazado_gnp'),   -- GNP rechaza

-- Activado por GNP: se atiende complemento o se cancela/rechaza
('activado_gnp',              'complemento_en_revision'),
('activado_gnp',              'rechazado_gnp'),
('activado_gnp',              'cancelado'),

-- Complemento enviado a GNP de vuelta
('complemento_en_revision',    'turnado_a_gnp'),
('complemento_en_revision',    'cancelado'),

-- Escape: cualquier estado activo puede escalar
('en_revision',               'escalado'),
('pendiente_documentos_agente', 'escalado'),
('activado_gnp',              'escalado'),
('complemento_en_revision',   'escalado'),

--Desde escalar se puede desbloquear cualquier estado activo
('escalado',                  'en_revision'),
('escalado',                  'pendiente_documentos_agente'),
('escalado',                  'activado_gnp'),
('escalado',                  'complemento_en_revision'),
('escalado',                  'cancelado'),

-- Terminales: re-entrada permitida solos mismocon el mismo
('completado',                'completado'),      -- permite re-ingreso vía endoso
('rechazado_gnp',             'rechazado_gnp'),   -- permite reintento
('cancelado',                 'cancelado');        -- fin

-- ---------------------------------------------------------------------------
-- 5. Función de validación de transición
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION estado_tramite_puede_transicionar(
    p_origen  TEXT,
    p_destino TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM estado_tramite_transicion
        WHERE estado_origen_id = p_origen AND estado_destino_id = p_destino
    );
END;
$$;

COMMENT ON FUNCTION estado_tramite_puede_transicionar(TEXT, TEXT) IS
    'Retorna TRUE si la transición de p_origen a p_destino es válida.';

GRANT EXECUTE ON FUNCTION estado_tramite_puede_transicionar(TEXT, TEXT)
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Convertir tramite.estado a TEXT con FK
-- ---------------------------------------------------------------------------

ALTER TABLE tramite
    ALTER COLUMN estado TYPE TEXT;

ALTER TABLE tramite
    DROP CONSTRAINT IF EXISTS tramite_estado_fk,
    ADD CONSTRAINT tramite_estado_fk
        FOREIGN KEY (estado)
        REFERENCES cat_estado_tramite(id);

-- ---------------------------------------------------------------------------
-- 7. Trigger: impedir transiciones inválidas
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trg_tramite_validar_transicion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado = NEW.estado THEN
        RETURN NEW;
    END IF;

    IF NOT estado_tramite_puede_transicionar(OLD.estado, NEW.estado) THEN
        RAISE EXCEPTION 'Transición de estado inválida: % → %', OLD.estado, NEW.estado
            USING HINT = 'Consulta estado_tramite_transicion para ver las transiciones válidas.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tramite_validar_transicion ON tramite;
CREATE TRIGGER trg_tramite_validar_transicion
    BEFORE UPDATE OF estado ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION trg_tramite_validar_transicion();

-- ---------------------------------------------------------------------------
-- 8. Migrar datos de estados viejos → nuevos
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    UPDATE tramite SET estado = 'en_revision'
        WHERE estado = 'validando';

    UPDATE tramite SET estado = 'pendiente_documentos_agente'
        WHERE estado = 'pendiente_documentos';

    UPDATE tramite SET estado = 'turnado_a_gnp'
        WHERE estado IN ('completo', 'en_proceso_gnp');

    UPDATE tramite SET estado = 'completado'
        WHERE estado = 'activado';

    UPDATE tramite SET estado = 'rechazado_gnp'
        WHERE estado = 'rechazado';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Migración de estados: %', SQLERRM;
END
$$;

-- ---------------------------------------------------------------------------
-- 9. Reemplazar TYPE estado_tramite (usado en otras columnas/funciones)
-- ---------------------------------------------------------------------------

DROP TYPE IF EXISTS estado_tramite;
CREATE TYPE estado_tramite AS ENUM (
    'recibido',
    'en_revision',
    'pendiente_documentos_agente',
    'turnado_a_gnp',
    'activado_gnp',
    'complemento_en_revision',
    'escalado',
    'completado',
    'rechazado_gnp',
    'cancelado'
);

-- ---------------------------------------------------------------------------
-- 10. Permisos
-- ---------------------------------------------------------------------------

GRANT SELECT ON cat_estado_tramite TO authenticated, service_role;
GRANT SELECT ON estado_tramite_transicion TO authenticated, service_role;

-- =============================================================================
-- FIN DE MIGRACIÓN: 20260529000030_estados_tramite.sql
-- =============================================================================

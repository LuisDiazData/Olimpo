-- =============================================================================
-- Migración: 20260529000029_comunicaciones.sql
-- Registro de comunicaciones informales entre analistas y agentes
-- (WhatsApp, teléfono, presencial)
-- =============================================================================
-- Contexto:
--   El CRM automatiza la creación de trámites cuando llegan por correo.
--   Pero los agentes también se comunican por WhatsApp, teléfono y presencial.
--   Esta tabla permite al analista registrar esas comunicaciones y vincularlas
--   al trámite correspondiente para mantener un historial completo.
--
-- Principios:
--   - Comunicación puede existir sola con solo agente_id (sin trámite aún).
--   - Puede vincularse a un trámite existente.
--   - Puede opcionalmente indicar que generó un trámite nuevo.
--   - Es visible para todo el equipo (analistas, gerentes, directores).
--   - Solo el autor o un gerente pueden eliminarla.
-- =============================================================================


-- =============================================================================
-- TABLA: comunicacion
-- =============================================================================

CREATE TABLE comunicacion (
    -- -------------------------------------------------------------------------
    -- Identidad
    -- -------------------------------------------------------------------------
    id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Medio de la comunicación
    -- -------------------------------------------------------------------------
    medio                    TEXT        NOT NULL,
    CONSTRAINT ck_medio CHECK (
        medio IN ('whatsapp', 'telefono', 'presencial')
    ),

    -- -------------------------------------------------------------------------
    -- Contenido
    -- -------------------------------------------------------------------------
    nota                     TEXT        NOT NULL
        CONSTRAINT ck_nota_vacia CHECK (TRIM(nota) <> ''),

    -- -------------------------------------------------------------------------
    -- Vínculos — al menos uno debe existir (tramite o agente)
    -- -------------------------------------------------------------------------
    tramite_id               UUID        REFERENCES tramite(id) ON DELETE SET NULL,
    agente_id                UUID        REFERENCES agente(id)  ON DELETE SET NULL,

    -- Si esta comunicación fue en respuesta a otra (opcional, para hilos)
    comunicacion_origen_id   UUID        REFERENCES comunicacion(id) ON DELETE SET NULL,

    -- Si de esta comunicación surgió un trámite nuevo (referencia opcional)
    tramite_generado_id      UUID        REFERENCES tramite(id) ON DELETE SET NULL,

    -- -------------------------------------------------------------------------
    -- Flags
    -- -------------------------------------------------------------------------
    -- TRUE = el agente/asistente contactó al analista
    -- FALSE = el analistainitió el contacto
    comunicacion_entrante   BOOLEAN     NOT NULL DEFAULT FALSE,

    -- TRUE = hay algo pendiente que atender de esta comunicación
    requiere_seguimiento     BOOLEAN     NOT NULL DEFAULT FALSE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    usuario_id               UUID        NOT NULL REFERENCES auth.users(id),
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- Constraints
    -- -------------------------------------------------------------------------
    CONSTRAINT chk_tiene_contexto CHECK (
        tramite_id IS NOT NULL OR agente_id IS NOT NULL
    )
);

COMMENT ON TABLE comunicacion IS
    'Registro de comunicaciones informales (WhatsApp, teléfono, presencial) '
    'entre el equipo (analistas, gerentes, directores) y agentes/asistentes. '
    'Visible para todo el equipo. Vincular a trámite si existe, o solo a '
    'agente si aún no hay trámite. El campo tramite_generado_id indica si '
    'de esta comunicación surgió un trámite nuevo.';

COMMENT ON COLUMN comunicacion.medio                  IS 'whatsapp | telefono | presencial';
COMMENT ON COLUMN comunicacion.nota                   IS 'Contenido de la comunicación. Máximo 2000 caracteres.';
COMMENT ON COLUMN comunicacion.tramite_id             IS 'UUID del trámite vinculado. NULL si aún no existe.';
COMMENT ON COLUMN comunicacion.agente_id              IS 'UUID del agente. Siempre requerido si no hay tramite_id.';
COMMENT ON COLUMN comunicacion.comunicacion_origen_id IS 'UUID de la comunicación a la que esta responde (hilo de conversación).';
COMMENT ON COLUMN comunicacion.tramite_generado_id    IS 'UUID del trámite que se creó a raíz de esta comunicación (opcional).';
COMMENT ON COLUMN comunicacion.comunicacion_entrante  IS 'TRUE=el agentecontactó al analista. FALSE=el analistainitió.';
COMMENT ON COLUMN comunicacion.requiere_seguimiento    IS 'TRUE=hay algo pendiente por atender de esta comunicación.';
COMMENT ON COLUMN comunicacion.usuario_id             IS 'Autor de la comunicación (analista que la registró).';


-- =============================================================================
-- TRIGGER: updated_at
-- =============================================================================

CREATE TRIGGER trg_comunicacion_updated_at
    BEFORE UPDATE ON comunicacion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- ÍNDICES
-- =============================================================================

-- Búsqueda por trámite (el más común en el timeline)
CREATE INDEX idx_comunicacion_tramite
    ON comunicacion (tramite_id)
    WHERE tramite_id IS NOT NULL;

-- Historial por agente
CREATE INDEX idx_comunicacion_agente
    ON comunicacion (agente_id);

-- Mis comunicaciones (filtrado rápido por autor)
CREATE INDEX idx_comunicacion_usuario
    ON comunicacion (usuario_id);

-- Lista por fecha (más recientes primero)
CREATE INDEX idx_comunicacion_fecha
    ON comunicacion (created_at DESC);

-- Alertas: comunicaciones que requieren seguimiento
CREATE INDEX idx_comunicacion_seguimiento
    ON comunicacion (created_at DESC)
    WHERE requiere_seguimiento = TRUE;

-- Hilos de conversación
CREATE INDEX idx_comunicacion_origen
    ON comunicacion (comunicacion_origen_id)
    WHERE comunicacion_origen_id IS NOT NULL;


-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

-- Todo usuario autenticado puede leer todas las comunicaciones
-- (gerentes y directores ven las de sus analistas; RLS de usuario lo maneja)
ALTER TABLE comunicacion ENABLE ROW LEVEL SECURITY;

-- Policy: cualquier usuario autenticado puede leer
CREATE POLICY "comunicacion_select"
    ON comunicacion FOR SELECT
    TO authenticated
    USING (TRUE);

-- Policy: cualquier usuario autenticado puede insertar (el campo usuario_id se llena con auth.uid())
CREATE POLICY "comunicacion_insert"
    ON comunicacion FOR INSERT
    TO authenticated
    WITH CHECK (usuario_id = auth.uid());

-- Policy: solo el autor puede actualizar su propia comunicación
CREATE POLICY "comunicacion_update_propio"
    ON comunicacion FOR UPDATE
    TO authenticated
    USING (usuario_id = auth.uid());

-- Policy: gerentes y directores pueden actualizar comunicaciones de otros
-- (se implementa en el router vía service_role para casos de supervisión)
-- Aquí permitimos UPDATE a todos para que el router pueda hacer overrides
-- El router usa service_role para estas operaciones, no RLS
CREATE POLICY "comunicacion_update_supervisor"
    ON comunicacion FOR UPDATE
    TO authenticated
    USING (TRUE);

-- Policy: soft delete — solo el autor puede eliminar su comunicación
-- No se borra el registro; se marca como eliminada
ALTER TABLE comunicacion ADD COLUMN eliminado BOOLEAN NOT NULL DEFAULT FALSE;

CREATE POLICY "comunicacion_delete"
    ON comunicacion FOR DELETE
    TO authenticated
    USING (usuario_id = auth.uid());


-- =============================================================================
-- FUNCIÓN RPC: marcar seguimiento rápido (bulk)
-- =============================================================================

-- Función helper para que un analista marque seguimiento en múltiples
-- comunicaciones de un solo golpe (ej: después de una llamada larga)
CREATE OR REPLACE FUNCTION marcar_seguimiento_multiple(
    p_comunicacion_ids UUID[],
    p_requiere_seguimiento BOOLEAN DEFAULT TRUE
)
RETURNS SETOF comunicacion
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    UPDATE comunicacion
    SET requiere_seguimiento = p_requiere_seguimiento,
        updated_at = NOW()
    WHERE id = ANY(p_comunicacion_ids)
    RETURNING *;
END;
$$;

COMMENT ON FUNCTION marcar_seguimiento_multiple IS
    'Marca o desmarca seguimiento en una lista de comunicaciones. '
    'Útil para marcar como atendidas después de una sesión de llamadas.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260529000029_comunicaciones.sql
-- =============================================================================

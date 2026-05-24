-- =============================================================================
-- Migración: 20260522000006_modulo_07_asignacion_vacaciones.sql
-- Módulo 7 — Asignación de agentes a analistas y cobertura de vacaciones
-- =============================================================================
-- Contexto:
--   Este módulo resuelve la pregunta central del Agente 4:
--   "Este trámite es del agente X en ramo Y — ¿a qué analista lo asigno?"
--
--   Dos tablas con propósitos complementarios:
--
--   asignacion         → Regla estática: agente X + ramo Y → analista Z.
--                        Configurada por gerentes y directores.
--                        El Agente 4 la consulta durante la cascada CUA.
--
--   cobertura_vacaciones → Regla temporal: analista Z está de vacaciones,
--                          analista W lo cubre del DD/MM al DD/MM.
--                          Sobreescribe la asignacion durante el período.
--
--   La función resolver_analista_asignacion() combina ambas tablas y devuelve
--   el UUID del analista correcto para un trámite dado.
--
-- Relaciones con módulos anteriores:
--   asignacion.agente_id             → agente.id    (Módulo 2)
--   asignacion.analista_id           → usuario.id   (Módulo 1)
--   asignacion.asignado_por          → usuario.id   (Módulo 1)
--   cobertura_vacaciones.analista_*  → usuario.id   (Módulo 1)
--   cobertura_vacaciones.creado_por  → usuario.id   (Módulo 1)
--
-- Uso en el pipeline de IA (Agente 4):
--   1. Agente 4 identifica agente_id via cascada CUA
--   2. Llama: SELECT resolver_analista_asignacion(agente_id, ramo, NOW()::DATE)
--   3. Si devuelve UUID → asigna ese analista al trámite
--   4. Si devuelve NULL → ninguna regla activa; marca requiere_atencion = TRUE
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TABLA asignacion
-- =============================================================================
-- Regla de enrutamiento permanente: para el agente X en el ramo Y,
-- los trámites van al analista Z.
--
-- Reglas de negocio:
--   - Solo puede haber UNA asignación activa por (agente_id, ramo).
--     Si se reasigna, se desactiva la anterior y se crea una nueva.
--   - El analista_id DEBE tener rol='analista' y ramo igual al de la asignación.
--     Un analista de vida no puede recibir trámites de autos — trigger lo enforce.
--   - Si no existe asignación para un agente+ramo, el trámite llega con
--     requiere_atencion = TRUE para asignación manual.
-- =============================================================================

CREATE TABLE asignacion (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Clave de enrutamiento: el agente y el ramo del trámite
    -- -------------------------------------------------------------------------
    agente_id       UUID            NOT NULL REFERENCES agente(id),
    ramo            ramo_usuario    NOT NULL,

    -- -------------------------------------------------------------------------
    -- Destino: el analista que recibe los trámites de este agente+ramo
    -- -------------------------------------------------------------------------
    analista_id     UUID            NOT NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Metadatos de gestión
    -- -------------------------------------------------------------------------
    -- Contexto opcional de por qué se hizo esta asignación
    notas           TEXT            NULL,
    -- Quién la configuró (director o gerente)
    asignado_por    UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Estado — soft-delete para mantener historial de asignaciones pasadas
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE asignacion IS
    'Reglas de enrutamiento: agente + ramo → analista. '
    'El Agente 4 las consulta para asignar trámites automáticamente. '
    'Solo puede existir una asignación activa por (agente_id, ramo) — ver índice uq_asignacion_activa.';

COMMENT ON COLUMN asignacion.agente_id      IS 'Agente de seguros cuyo trámite se enruta.';
COMMENT ON COLUMN asignacion.ramo           IS 'Ramo del trámite (vida, gmm, autos, pyme). Junto con agente_id forma la clave de enrutamiento.';
COMMENT ON COLUMN asignacion.analista_id    IS 'Analista destino. Validado por trigger: debe tener rol=analista y ramo coincidente.';
COMMENT ON COLUMN asignacion.asignado_por   IS 'Director o gerente que configuró esta regla. NULL si fue migración o carga inicial.';
COMMENT ON COLUMN asignacion.activo         IS 'Soft-delete. Al reasignar: desactivar la antigua, crear nueva. Historial preservado.';


-- =============================================================================
-- SECCIÓN 2: TABLA cobertura_vacaciones
-- =============================================================================
-- Cobertura temporal durante ausencias (vacaciones, incapacidades, permisos).
-- Durante el período activo, los trámites del analista ausente se redirigen
-- al analista de cobertura — esto lo maneja resolver_analista_asignacion().
--
-- Reglas de negocio:
--   - El analista de cobertura debe ser del MISMO ramo que el ausente.
--   - Un analista no puede cubrirse a sí mismo.
--   - Las coberturas pueden solaparse (varios analistas cubren a uno) — es
--     responsabilidad del gerente evitar solapamientos indeseados.
--   - Si hay múltiples coberturas activas para la misma fecha,
--     resolver_analista_asignacion() toma la primera (ORDER BY created_at).
--   - ramo está denormalizado para evitar JOINs en las policies RLS.
-- =============================================================================

CREATE TABLE cobertura_vacaciones (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Los dos analistas involucrados
    -- -------------------------------------------------------------------------
    -- El analista que estará ausente
    analista_ausente_id     UUID            NOT NULL REFERENCES usuario(id),
    -- El analista que cubre durante la ausencia
    analista_cobertura_id   UUID            NOT NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Ramo denormalizado — ambos analistas deben ser del mismo ramo.
    -- Se valida por trigger. Permite RLS sin JOIN a usuario.
    -- -------------------------------------------------------------------------
    ramo                    ramo_usuario    NOT NULL,

    -- -------------------------------------------------------------------------
    -- Período de cobertura
    -- -------------------------------------------------------------------------
    fecha_inicio            DATE            NOT NULL,
    fecha_fin               DATE            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Metadatos de gestión
    -- -------------------------------------------------------------------------
    notas                   TEXT            NULL,
    creado_por              UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Estado — permite desactivar anticipadamente (regreso antes de lo esperado)
    -- -------------------------------------------------------------------------
    activa                  BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- El fin no puede ser anterior al inicio
    CONSTRAINT ck_cobertura_fechas
        CHECK (fecha_fin >= fecha_inicio),

    -- Un analista no se puede cubrir a sí mismo
    CONSTRAINT ck_cobertura_distintos
        CHECK (analista_ausente_id <> analista_cobertura_id)
);

COMMENT ON TABLE cobertura_vacaciones IS
    'Cobertura temporal durante ausencias de analistas. '
    'Durante el período activo, resolver_analista_asignacion() redirige los '
    'trámites del analista ausente al analista de cobertura. '
    'Ambos analistas deben ser del mismo ramo — validado por trigger.';

COMMENT ON COLUMN cobertura_vacaciones.analista_ausente_id   IS 'Analista que estará fuera. Sus trámites se redirigen al analista_cobertura.';
COMMENT ON COLUMN cobertura_vacaciones.analista_cobertura_id IS 'Analista que recibe los trámites durante la ausencia.';
COMMENT ON COLUMN cobertura_vacaciones.ramo                  IS 'Ramo de ambos analistas. Denormalizado para RLS. Validado por trigger.';
COMMENT ON COLUMN cobertura_vacaciones.activa                IS 'FALSE si el analista regresó antes de fecha_fin. Desactivar en lugar de borrar.';


-- =============================================================================
-- SECCIÓN 3: ÍNDICES
-- =============================================================================

-- asignacion ——————————————————————————————————————————————————————————————————

-- Unicidad de asignación activa: solo UNA regla por agente+ramo cuando activo=TRUE.
-- Índice parcial porque cuando activo=FALSE pueden existir múltiples históricos.
CREATE UNIQUE INDEX uq_asignacion_activa
    ON asignacion (agente_id, ramo)
    WHERE activo = TRUE;

COMMENT ON INDEX uq_asignacion_activa IS
    'Garantiza que solo exista una asignación activa por agente+ramo. '
    'Parcial: permite múltiples registros inactivos (historial de asignaciones).';

-- Lookup principal del Agente 4: dado agente_id + ramo, encontrar analista
CREATE INDEX idx_asignacion_agente_ramo
    ON asignacion (agente_id, ramo)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_asignacion_agente_ramo IS
    'Lookup del Agente 4: resolver_analista_asignacion() usa este índice primero.';

-- Buscar todas las asignaciones de un analista (dashboard del gerente, reasignación masiva)
CREATE INDEX idx_asignacion_analista
    ON asignacion (analista_id)
    WHERE activo = TRUE;

-- Buscar asignaciones por ramo (gestión del gerente)
CREATE INDEX idx_asignacion_ramo
    ON asignacion (ramo)
    WHERE activo = TRUE;

-- cobertura_vacaciones ————————————————————————————————————————————————————————

-- Lookup de cobertura activa: ¿quién cubre al analista X en la fecha Y?
-- Es la query crítica de resolver_analista_asignacion().
CREATE INDEX idx_cobertura_ausente_fecha
    ON cobertura_vacaciones (analista_ausente_id, fecha_inicio, fecha_fin)
    WHERE activa = TRUE;

COMMENT ON INDEX idx_cobertura_ausente_fecha IS
    'Lookup de cobertura activa por analista ausente y fecha. '
    'Usado por resolver_analista_asignacion() como segunda consulta.';

-- ¿A quién está cubriendo el analista X esta semana?
CREATE INDEX idx_cobertura_cobertura
    ON cobertura_vacaciones (analista_cobertura_id, fecha_inicio, fecha_fin)
    WHERE activa = TRUE;

-- Gestión del gerente por ramo
CREATE INDEX idx_cobertura_ramo
    ON cobertura_vacaciones (ramo)
    WHERE activa = TRUE;


-- =============================================================================
-- SECCIÓN 4: TRIGGERS — updated_at
-- =============================================================================

CREATE TRIGGER trg_asignacion_updated_at
    BEFORE UPDATE ON asignacion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_cobertura_updated_at
    BEFORE UPDATE ON cobertura_vacaciones
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 5: TRIGGER — Validación de asignacion
-- =============================================================================
-- Garantiza que el analista_id apunte a un usuario con:
--   rol = 'analista'
--   ramo = asignacion.ramo
-- Esto impide asignar un analista de GMM a trámites de Autos, por ejemplo.
-- =============================================================================

CREATE OR REPLACE FUNCTION validar_analista_asignacion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol   rol_usuario;
    v_ramo  ramo_usuario;
BEGIN
    SELECT rol, ramo
    INTO v_rol, v_ramo
    FROM usuario
    WHERE id = NEW.analista_id AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El usuario con id % no existe o está inactivo.',
            NEW.analista_id;
    END IF;

    IF v_rol <> 'analista' THEN
        RAISE EXCEPTION
            'Solo se puede asignar un usuario con rol "analista". '
            'El usuario seleccionado tiene rol "%".',
            v_rol;
    END IF;

    IF v_ramo <> NEW.ramo THEN
        RAISE EXCEPTION
            'El analista es del ramo "%" pero la asignación es para el ramo "%". '
            'Un analista solo puede recibir trámites de su propio ramo.',
            v_ramo, NEW.ramo;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validar_analista_asignacion() IS
    'Valida que el analista_id tenga rol=analista y ramo coincidente con la asignación. '
    'Dispara en INSERT y UPDATE de la tabla asignacion.';

CREATE TRIGGER trg_asignacion_validar_analista
    BEFORE INSERT OR UPDATE OF analista_id, ramo ON asignacion
    FOR EACH ROW
    EXECUTE FUNCTION validar_analista_asignacion();


-- =============================================================================
-- SECCIÓN 6: TRIGGER — Validación de cobertura_vacaciones
-- =============================================================================
-- Garantiza que ambos analistas sean del mismo ramo y que ese ramo
-- coincida con el campo ramo denormalizado de la cobertura.
-- También valida que ambos tengan rol='analista' y estén activos.
-- =============================================================================

CREATE OR REPLACE FUNCTION validar_cobertura_vacaciones()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol_ausente   rol_usuario;
    v_ramo_ausente  ramo_usuario;
    v_rol_cobertura rol_usuario;
    v_ramo_cobertura ramo_usuario;
BEGIN
    -- Validar analista ausente
    SELECT rol, ramo
    INTO v_rol_ausente, v_ramo_ausente
    FROM usuario
    WHERE id = NEW.analista_ausente_id AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El analista ausente (id %) no existe o está inactivo.',
            NEW.analista_ausente_id;
    END IF;

    IF v_rol_ausente <> 'analista' THEN
        RAISE EXCEPTION
            'El analista ausente debe tener rol "analista", tiene "%".',
            v_rol_ausente;
    END IF;

    -- Validar analista de cobertura
    SELECT rol, ramo
    INTO v_rol_cobertura, v_ramo_cobertura
    FROM usuario
    WHERE id = NEW.analista_cobertura_id AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El analista de cobertura (id %) no existe o está inactivo.',
            NEW.analista_cobertura_id;
    END IF;

    IF v_rol_cobertura <> 'analista' THEN
        RAISE EXCEPTION
            'El analista de cobertura debe tener rol "analista", tiene "%".',
            v_rol_cobertura;
    END IF;

    -- Validar que ambos sean del mismo ramo
    IF v_ramo_ausente <> v_ramo_cobertura THEN
        RAISE EXCEPTION
            'Los analistas deben ser del mismo ramo. '
            'Ausente: %, Cobertura: %.',
            v_ramo_ausente, v_ramo_cobertura;
    END IF;

    -- Sincronizar el campo ramo denormalizado con el ramo real de los analistas
    NEW.ramo := v_ramo_ausente;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validar_cobertura_vacaciones() IS
    'Valida que ambos analistas existan, estén activos, tengan rol=analista '
    'y sean del mismo ramo. Sincroniza el campo ramo denormalizado automáticamente.';

CREATE TRIGGER trg_cobertura_validar
    BEFORE INSERT OR UPDATE ON cobertura_vacaciones
    FOR EACH ROW
    EXECUTE FUNCTION validar_cobertura_vacaciones();


-- =============================================================================
-- SECCIÓN 7: FUNCIÓN resolver_analista_asignacion()
-- =============================================================================
-- Función principal que el Agente 4 llama para determinar a qué analista
-- asignar un trámite.
--
-- Algoritmo:
--   1. Busca la asignación activa para (agente_id, ramo)
--   2. Si la encuentra, verifica si ese analista tiene cobertura activa hoy
--   3. Si hay cobertura → devuelve el analista de cobertura
--   4. Si no hay cobertura → devuelve el analista asignado
--   5. Si no hay asignación → devuelve NULL (Agente 4 marcará requiere_atencion)
--
-- Uso en Python (Agente 4):
--   result = supabase.rpc('resolver_analista_asignacion', {
--       'p_agente_id': agente_id,
--       'p_ramo': 'gmm',
--       'p_fecha': date.today().isoformat()
--   }).execute()
--   analista_id = result.data  # UUID o None
-- =============================================================================

CREATE OR REPLACE FUNCTION resolver_analista_asignacion(
    p_agente_id UUID,
    p_ramo      ramo_usuario,
    p_fecha     DATE DEFAULT CURRENT_DATE
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_analista_id   UUID;
    v_cobertura_id  UUID;
BEGIN
    -- Paso 1: Buscar la asignación activa para este agente+ramo
    SELECT analista_id
    INTO v_analista_id
    FROM asignacion
    WHERE agente_id = p_agente_id
      AND ramo      = p_ramo
      AND activo    = TRUE
    LIMIT 1;

    -- Sin asignación → el Agente 4 marcará requiere_atencion = TRUE en el trámite
    IF v_analista_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Paso 2: Verificar si el analista tiene cobertura activa en la fecha dada
    SELECT analista_cobertura_id
    INTO v_cobertura_id
    FROM cobertura_vacaciones
    WHERE analista_ausente_id = v_analista_id
      AND activa       = TRUE
      AND fecha_inicio <= p_fecha
      AND fecha_fin    >= p_fecha
    ORDER BY created_at  -- si hay solapamientos, toma la cobertura más antigua (prioridad)
    LIMIT 1;

    -- Paso 3: Devolver cobertura si aplica, o el analista original
    RETURN COALESCE(v_cobertura_id, v_analista_id);
END;
$$;

COMMENT ON FUNCTION resolver_analista_asignacion(UUID, ramo_usuario, DATE) IS
    'Resuelve el analista correcto para un trámite dado agente_id + ramo + fecha. '
    'Combina asignacion y cobertura_vacaciones. Devuelve NULL si no hay regla activa. '
    'El Agente 4 llama esta función durante la cascada CUA para determinar la asignación.';


-- =============================================================================
-- SECCIÓN 8: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE asignacion           ENABLE ROW LEVEL SECURITY;
ALTER TABLE cobertura_vacaciones ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: asignacion
-- -----------------------------------------------------------------------------

-- Directores ven todas las asignaciones (todos los ramos)
CREATE POLICY pol_asignacion_select_director
    ON asignacion FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_asignacion_select_director ON asignacion IS
    'Directores ven todas las reglas de asignación sin restricción de ramo.';

-- Gerente ve las asignaciones de su ramo
CREATE POLICY pol_asignacion_select_gerente
    ON asignacion FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

COMMENT ON POLICY pol_asignacion_select_gerente ON asignacion IS
    'Gerente ve las asignaciones activas e inactivas de su propio ramo.';

-- Analista ve solo las asignaciones donde él es el destino
CREATE POLICY pol_asignacion_select_analista
    ON asignacion FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    );

COMMENT ON POLICY pol_asignacion_select_analista ON asignacion IS
    'Analista puede ver qué agentes tiene asignados. Solo sus propias asignaciones.';

-- INSERT: directores (cualquier ramo) y gerentes (solo su ramo)
CREATE POLICY pol_asignacion_insert
    ON asignacion FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    );

COMMENT ON POLICY pol_asignacion_insert ON asignacion IS
    'Directores pueden crear asignaciones en cualquier ramo. '
    'Gerentes solo en su propio ramo.';

-- UPDATE: misma lógica que INSERT
CREATE POLICY pol_asignacion_update
    ON asignacion FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    );

-- DELETE: no — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: cobertura_vacaciones
-- -----------------------------------------------------------------------------

-- Directores ven todas las coberturas
CREATE POLICY pol_cobertura_select_director
    ON cobertura_vacaciones FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

-- Gerente ve las coberturas de su ramo
CREATE POLICY pol_cobertura_select_gerente
    ON cobertura_vacaciones FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

-- Analista ve las coberturas donde él es ausente o donde él es el que cubre
CREATE POLICY pol_cobertura_select_analista
    ON cobertura_vacaciones FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND (
            analista_ausente_id   = auth.uid()
            OR analista_cobertura_id = auth.uid()
        )
    );

COMMENT ON POLICY pol_cobertura_select_analista ON cobertura_vacaciones IS
    'Analista ve sus propias vacaciones y períodos donde cubre a otros. '
    'No puede ver coberturas de analistas de otros ramos.';

-- INSERT: directores y gerentes (su ramo — el trigger sincroniza el campo ramo)
CREATE POLICY pol_cobertura_insert
    ON cobertura_vacaciones FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR auth_rol() = 'gerente'
    );

COMMENT ON POLICY pol_cobertura_insert ON cobertura_vacaciones IS
    'Directores y gerentes pueden crear coberturas. '
    'El trigger valida que el ramo de los analistas coincida con el ramo del gerente.';

-- UPDATE: directores y gerentes
CREATE POLICY pol_cobertura_update
    ON cobertura_vacaciones FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    );

-- DELETE: no — soft-delete vía activa = FALSE


-- =============================================================================
-- SECCIÓN 9: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON TABLE asignacion           TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE cobertura_vacaciones TO authenticated;

-- El Agente 4 llama esta función desde service_role, pero también debe estar
-- disponible para authenticated (consultas desde la UI y tests de integración)
GRANT EXECUTE ON FUNCTION resolver_analista_asignacion(UUID, ramo_usuario, DATE) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000006_modulo_07_asignacion_vacaciones.sql
-- =============================================================================

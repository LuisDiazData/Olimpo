-- =============================================================================
-- Migración: 20260524000021_reasignacion_tramite.sql
-- Reasignación completa de trámites: motivo + restricción de estado
-- =============================================================================
-- Problema que resuelve:
--
--   El mecanismo base ya existía (trigger auto-gerente + trigger auto-evento),
--   pero tenía tres huecos:
--
--   1. Sin motivo: el evento de reasignación no registraba el motivo.
--      Saber que el analista cambió no es suficiente — también hay que saber
--      por qué (vacaciones, carga de trabajo, error del Agente 4, etc.).
--
--   2. Sin restricción de estado: era posible reasignar un trámite en estado
--      aprobado o rechazado, rompiendo la consistencia del historial.
--
--   3. Sin solución al problema de conexión: el motivo venía en el body de
--      la API pero se perdía porque el UPDATE al tramite y la lectura del
--      trigger ocurren en llamadas separadas que pueden usar conexiones
--      distintas del pool. Las variables de sesión no cruzaban conexiones.
--
-- Solución:
--   Una función SQL reasignar_tramite() que hace todo en una sola llamada RPC.
--   Dentro de la función: set_config() local → UPDATE tramite → trigger dispara
--   → trigger lee current_setting(). Todo en la misma transacción/conexión.
--   El trigger existente se actualiza para leer el motivo de la sesión.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: Actualizar trigger registrar_asignacion_tramite
-- Agrega lectura del motivo desde la variable de sesión app.motivo_reasignacion.
-- El motivo es opcional — si no se pasa, el evento queda sin él (comportamiento anterior).
-- =============================================================================

CREATE OR REPLACE FUNCTION registrar_asignacion_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_nombre_analista   TEXT;
    v_tipo              tipo_evento_tramite;
    v_descripcion       TEXT;
    v_motivo            TEXT;
BEGIN
    IF NEW.analista_id IS DISTINCT FROM OLD.analista_id
       AND NEW.analista_id IS NOT NULL
    THEN
        SELECT nombre INTO v_nombre_analista
        FROM usuario WHERE id = NEW.analista_id;

        -- Leer motivo de la variable de sesión (vacío o NULL si no se pasó)
        v_motivo := NULLIF(TRIM(current_setting('app.motivo_reasignacion', TRUE)), '');

        v_tipo := CASE
            WHEN OLD.analista_id IS NULL THEN 'asignacion'
            ELSE 'reasignacion'
        END;

        v_descripcion := CASE
            WHEN OLD.analista_id IS NULL THEN
                'Trámite asignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
            ELSE
                'Trámite reasignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
                || CASE WHEN v_motivo IS NOT NULL
                        THEN ' Motivo: ' || v_motivo
                        ELSE '' END
        END;

        INSERT INTO tramite_evento (
            tramite_id, tipo_evento, usuario_id, agente_ia_nombre,
            descripcion, datos, visible_en_timeline, created_at
        ) VALUES (
            NEW.id,
            v_tipo,
            -- Actor: humano si no hay agente IA activo, IA si lo hay
            CASE WHEN NULLIF(current_setting('app.agente_ia_actual', TRUE), '') IS NULL
                 THEN auth.uid() ELSE NULL END,
            NULLIF(current_setting('app.agente_ia_actual', TRUE), ''),
            v_descripcion,
            jsonb_strip_nulls(jsonb_build_object(
                'analista_anterior_id', OLD.analista_id,
                'analista_nuevo_id',    NEW.analista_id,
                'motivo',               v_motivo    -- NULL si no se proporcionó
            )),
            TRUE,
            NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_asignacion_tramite() IS
    'Registra en tramite_evento cuando cambia el analista_id del trámite. '
    'Lee app.motivo_reasignacion de la sesión para incluirlo en el evento. '
    'Detecta asignación inicial (OLD.analista_id IS NULL) vs reasignación.';


-- =============================================================================
-- SECCIÓN 2: Función reasignar_tramite()
-- Punto de entrada único para reasignar un trámite desde la API.
-- Garantiza atomicidad: todo en una sola llamada RPC = misma sesión Postgres.
--
-- Ventaja clave sobre el UPDATE directo:
--   - set_config() y el UPDATE están en la misma transacción
--   - El trigger registrar_asignacion_tramite lee current_setting() correctamente
--   - El motivo del body de la API llega al evento en tramite_evento
--
-- Validaciones incluidas:
--   1. El trámite existe
--   2. El trámite no está en estado terminal (aprobado/rechazado)
--   3. El nuevo analista existe, está activo y tiene rol 'analista'
--   4. No es el mismo analista (no-op)
-- =============================================================================

CREATE OR REPLACE FUNCTION reasignar_tramite(
    p_tramite_id        uuid,
    p_analista_nuevo_id uuid,
    p_motivo            text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_tramite               tramite%ROWTYPE;
    v_analista_nuevo        usuario%ROWTYPE;
    v_nombre_anterior       TEXT;
    v_analista_anterior_id  uuid;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Leer y bloquear el trámite
    -- -------------------------------------------------------------------------
    SELECT * INTO v_tramite
    FROM tramite
    WHERE id = p_tramite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'TRAMITE_NO_ENCONTRADO',
            'mensaje', 'El trámite ' || p_tramite_id || ' no existe.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Validar estado — no reasignar trámites terminales
    -- -------------------------------------------------------------------------
    IF v_tramite.estado IN ('aprobado', 'rechazado') THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ESTADO_TERMINAL',
            'mensaje', 'No se puede reasignar un trámite en estado ' || v_tramite.estado || '.',
            'estado_actual', v_tramite.estado::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Validar que el nuevo analista existe, está activo y tiene rol correcto
    -- -------------------------------------------------------------------------
    SELECT * INTO v_analista_nuevo
    FROM usuario
    WHERE id = p_analista_nuevo_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ANALISTA_NO_ENCONTRADO',
            'mensaje', 'El usuario ' || p_analista_nuevo_id || ' no existe.'
        );
    END IF;

    IF v_analista_nuevo.rol != 'analista' THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ROL_INCORRECTO',
            'mensaje', 'Solo se puede asignar a usuarios con rol analista.',
            'rol_actual', v_analista_nuevo.rol::text
        );
    END IF;

    IF v_analista_nuevo.activo = FALSE THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ANALISTA_INACTIVO',
            'mensaje', 'El analista ' || v_analista_nuevo.nombre || ' está inactivo.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Evitar no-op: mismo analista
    -- -------------------------------------------------------------------------
    IF v_tramite.analista_id = p_analista_nuevo_id THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'MISMO_ANALISTA',
            'mensaje', 'El trámite ya está asignado a ' || v_analista_nuevo.nombre || '.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Guardar analista anterior para la respuesta
    -- -------------------------------------------------------------------------
    v_analista_anterior_id := v_tramite.analista_id;

    IF v_analista_anterior_id IS NOT NULL THEN
        SELECT nombre INTO v_nombre_anterior
        FROM usuario WHERE id = v_analista_anterior_id;
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Pasar el motivo al trigger vía variable de sesión LOCAL (esta transacción)
    --    TRUE = is_local: la variable vuelve a su valor anterior al salir de la transacción.
    --    El trigger registrar_asignacion_tramite la lee con current_setting().
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- -------------------------------------------------------------------------
    -- 7. Actualizar analista_id
    --    Dispara dos triggers en el mismo ciclo de la transacción:
    --      - trg_tramite_auto_asignar_gerente (BEFORE) → actualiza gerente_id
    --      - trg_tramite_registrar_asignacion (AFTER)  → crea evento con motivo
    -- -------------------------------------------------------------------------
    UPDATE tramite
    SET analista_id = p_analista_nuevo_id
    WHERE id = p_tramite_id;

    -- -------------------------------------------------------------------------
    -- 8. Limpiar variable de sesión (por higiene, aunque is_local ya lo hace)
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', '', TRUE);

    -- -------------------------------------------------------------------------
    -- 9. Retornar resultado completo
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok', true,
        'tramite_id', p_tramite_id,
        'analista_anterior_id', v_analista_anterior_id,
        'analista_anterior_nombre', v_nombre_anterior,
        'analista_nuevo_id', p_analista_nuevo_id,
        'analista_nuevo_nombre', v_analista_nuevo.nombre,
        'motivo', p_motivo,
        'estado_tramite', v_tramite.estado::text
    );
END;
$$;

COMMENT ON FUNCTION reasignar_tramite(uuid, uuid, text) IS
    'Reasigna un trámite a un nuevo analista de forma atómica. '
    'Valida: trámite existe, no está en estado terminal, analista activo y con rol correcto, no es el mismo. '
    'Pasa el motivo al trigger registrar_asignacion_tramite vía set_config() local. '
    'Todo ocurre en una sola transacción — la variable de sesión con el motivo es visible al trigger. '
    'Retorna jsonb con ok=true/false y detalle del resultado.';

-- Solo roles con capacidad de reasignar pueden ejecutar esta función
GRANT EXECUTE ON FUNCTION reasignar_tramite(uuid, uuid, text)
    TO authenticated, service_role;


-- =============================================================================
-- SECCIÓN 3: Enum para motivos de reasignación (catálogo controlado)
-- Evita texto libre inconsistente. Los valores se muestran en la UI como opciones.
-- El usuario puede elegir uno del catálogo o escribir uno libre.
-- =============================================================================

-- La tabla configuracion_sistema ya existe. Insertamos los motivos predefinidos
-- como un valor JSON que la UI leerá para mostrar el selector.
INSERT INTO configuracion_sistema (
    clave, valor, tipo_valor, descripcion, grupo, editable_por
) VALUES (
    'MOTIVOS_REASIGNACION',
    '["Vacaciones del analista",
      "Licencia médica",
      "Exceso de carga de trabajo",
      "Error de asignación inicial del Agente 4",
      "Solicitud del agente de seguros",
      "Cambio de ramo",
      "Baja del analista",
      "Otro"]',
    'json',
    'Lista de motivos predefinidos para reasignación de trámites. La UI los muestra como opciones en el selector.',
    'operaciones',
    'director'
)
ON CONFLICT (clave, aplica_ramo) DO NOTHING;

COMMENT ON TABLE configuracion_sistema IS
    'Parámetros operativos del CRM, incluyendo MOTIVOS_REASIGNACION para el selector de la UI.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000021_reasignacion_tramite.sql
-- =============================================================================

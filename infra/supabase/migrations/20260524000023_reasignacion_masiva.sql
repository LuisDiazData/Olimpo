-- =============================================================================
-- Migración: 20260524000023_reasignacion_masiva.sql
-- Reasignación masiva + validación de autorización en reasignar_tramite
-- =============================================================================
--
-- Qué resuelve:
--
--   1. reasignar_tramite() tenía una brecha de seguridad: cualquier analista
--      autenticado podía llamarla directamente vía RPC, saltándose las
--      validaciones de rol/ramo del endpoint FastAPI.
--      → Validación de rol del llamante (auth.uid()) dentro de la función.
--      → Si el llamante es gerente, se valida que sea del mismo ramo que el
--        analista que se asigna (defensa en profundidad).
--
--   2. No existía forma de reasignar en masa los trámites de un analista
--      de vacaciones. El gerente tendría que hacer clic N veces.
--      → Nueva función reasignar_tramites_masivo(): reasigna todos los
--        trámites activos no terminales en una sola transacción atómica.
--
-- Caso de uso principal:
--   Gerente abre la UI → busca los trámites del analista de vacaciones →
--   selecciona al analista de cobertura → un clic →
--   todos los trámites abiertos pasan al nuevo analista con motivo registrado.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: reasignar_tramite — agrega validación del llamante
-- =============================================================================
--
-- Cambios respecto a la versión anterior (migración 20260524000021):
--   • Nuevas variables: v_caller_uid, v_caller_rol, v_caller_ramo
--   • Bloque 0: si el llamante es usuario autenticado (auth.uid() no NULL):
--       - Debe tener rol gerente o director
--       - Si es gerente, su ramo debe coincidir con el del analista asignado
--   • El resto del flujo no cambia
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
    -- Información del llamante (NULL si llama service_role / agente IA)
    v_caller_uid            uuid;
    v_caller_rol            rol_usuario;
    v_caller_ramo           ramo_usuario;
BEGIN
    -- -------------------------------------------------------------------------
    -- 0a. Identificar al llamante
    --     auth.uid() es NULL cuando llama service_role (agentes IA, admin).
    --     Cuando llama un JWT de usuario, auth.uid() devuelve su UUID.
    -- -------------------------------------------------------------------------
    v_caller_uid := auth.uid();

    IF v_caller_uid IS NOT NULL THEN
        SELECT rol, ramo
        INTO   v_caller_rol, v_caller_ramo
        FROM   usuario
        WHERE  id = v_caller_uid AND activo = TRUE;

        -- 0b. Validar que el llamante puede reasignar
        IF v_caller_rol NOT IN ('director_general', 'director_ops', 'gerente') THEN
            RETURN jsonb_build_object(
                'ok',         false,
                'error_code', 'SIN_AUTORIZACION',
                'mensaje',    'Solo gerentes y directores pueden reasignar trámites.'
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 1. Leer y bloquear el trámite
    -- -------------------------------------------------------------------------
    SELECT * INTO v_tramite
    FROM   tramite
    WHERE  id = p_tramite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'TRAMITE_NO_ENCONTRADO',
            'mensaje',    'El trámite ' || p_tramite_id || ' no existe.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Validar estado — no reasignar trámites terminales
    -- -------------------------------------------------------------------------
    IF v_tramite.estado IN ('aprobado', 'rechazado') THEN
        RETURN jsonb_build_object(
            'ok',          false,
            'error_code',  'ESTADO_TERMINAL',
            'mensaje',     'No se puede reasignar un trámite en estado ' || v_tramite.estado || '.',
            'estado_actual', v_tramite.estado::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Validar analista destino: existe, activo, rol correcto
    -- -------------------------------------------------------------------------
    SELECT * INTO v_analista_nuevo
    FROM   usuario
    WHERE  id = p_analista_nuevo_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_NO_ENCONTRADO',
            'mensaje',    'El usuario ' || p_analista_nuevo_id || ' no existe.'
        );
    END IF;

    IF v_analista_nuevo.rol != 'analista' THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ROL_INCORRECTO',
            'mensaje',    'Solo se puede asignar a usuarios con rol analista.',
            'rol_actual', v_analista_nuevo.rol::text
        );
    END IF;

    IF v_analista_nuevo.activo = FALSE THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_INACTIVO',
            'mensaje',    'El analista ' || v_analista_nuevo.nombre || ' está inactivo.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 0c. Si el llamante es gerente, su ramo debe coincidir con el del analista
    --     (defensa en profundidad — Python ya lo validó, pero por si llaman
    --     la función directamente vía RPC sin pasar por el endpoint)
    -- -------------------------------------------------------------------------
    IF v_caller_uid IS NOT NULL AND v_caller_rol = 'gerente' THEN
        IF v_caller_ramo IS DISTINCT FROM v_analista_nuevo.ramo THEN
            RETURN jsonb_build_object(
                'ok',           false,
                'error_code',   'RAMO_DIFERENTE',
                'mensaje',      'Un gerente solo puede asignar analistas de su propio ramo.',
                'tu_ramo',      v_caller_ramo::text,
                'ramo_analista', v_analista_nuevo.ramo::text
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Evitar no-op: mismo analista
    -- -------------------------------------------------------------------------
    IF v_tramite.analista_id = p_analista_nuevo_id THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'MISMO_ANALISTA',
            'mensaje',    'El trámite ya está asignado a ' || v_analista_nuevo.nombre || '.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Guardar analista anterior para la respuesta
    -- -------------------------------------------------------------------------
    v_analista_anterior_id := v_tramite.analista_id;
    IF v_analista_anterior_id IS NOT NULL THEN
        SELECT nombre INTO v_nombre_anterior
        FROM   usuario WHERE id = v_analista_anterior_id;
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Pasar el motivo al trigger vía variable de sesión LOCAL
    --    TRUE = is_local: la variable vuelve a NULL al salir de la transacción.
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- -------------------------------------------------------------------------
    -- 7. Actualizar analista_id
    --    Dispara trg_tramite_asignar_gerente (BEFORE) y
    --             trg_tramite_registrar_asignacion (AFTER) con el motivo
    -- -------------------------------------------------------------------------
    UPDATE tramite
    SET    analista_id = p_analista_nuevo_id
    WHERE  id = p_tramite_id;

    PERFORM set_config('app.motivo_reasignacion', '', TRUE);  -- limpieza por higiene

    -- -------------------------------------------------------------------------
    -- 8. Retornar resultado
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok',                     true,
        'tramite_id',             p_tramite_id,
        'analista_anterior_id',   v_analista_anterior_id,
        'analista_anterior_nombre', v_nombre_anterior,
        'analista_nuevo_id',      p_analista_nuevo_id,
        'analista_nuevo_nombre',  v_analista_nuevo.nombre,
        'motivo',                 p_motivo,
        'estado_tramite',         v_tramite.estado::text
    );
END;
$$;

COMMENT ON FUNCTION reasignar_tramite(uuid, uuid, text) IS
    'Reasigna un trámite a un nuevo analista de forma atómica. '
    'Si el llamante es un JWT autenticado: valida que sea gerente o director, '
    'y que un gerente solo asigne analistas de su propio ramo. '
    'Valida también: trámite no terminal, analista activo, rol correcto, no el mismo. '
    'Pasa el motivo al trigger registrar_asignacion_tramite vía set_config().';

GRANT EXECUTE ON FUNCTION reasignar_tramite(uuid, uuid, text)
    TO authenticated, service_role;


-- =============================================================================
-- SECCIÓN 2: reasignar_tramites_masivo — reasignación en masa (vacaciones/baja)
-- =============================================================================
--
-- Reasigna todos los trámites activos no terminales de un analista a otro en
-- una sola transacción. El set_config() se llama una sola vez antes del loop
-- y el trigger lo lee en cada iteración — misma transacción = misma conexión.
--
-- Validaciones:
--   1. Analista origen existe (puede estar inactivo — ya se fue de vacaciones)
--   2. Analista destino existe, activo, con rol='analista'
--   3. Ambos analistas son del mismo ramo
--   4. Si el llamante es JWT autenticado: debe ser gerente o director
--   5. Si el llamante es gerente: su ramo debe coincidir con el ramo de los analistas
-- =============================================================================

CREATE OR REPLACE FUNCTION reasignar_tramites_masivo(
    p_analista_origen_id    uuid,
    p_analista_destino_id   uuid,
    p_motivo                text        DEFAULT NULL,
    p_realizado_por         uuid        DEFAULT NULL,   -- para auditoría futura
    p_solo_estados          text[]      DEFAULT NULL    -- NULL = todos los no terminales
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_origen            usuario%ROWTYPE;
    v_destino           usuario%ROWTYPE;
    v_caller_uid        uuid;
    v_caller_rol        rol_usuario;
    v_caller_ramo       ramo_usuario;
    v_tramite_id        uuid;
    v_folio             text;
    v_total             integer  := 0;
    v_folios            text[]   := ARRAY[]::text[];
BEGIN
    -- -------------------------------------------------------------------------
    -- 0. Validar autorización del llamante
    -- -------------------------------------------------------------------------
    v_caller_uid := auth.uid();

    IF v_caller_uid IS NOT NULL THEN
        SELECT rol, ramo
        INTO   v_caller_rol, v_caller_ramo
        FROM   usuario
        WHERE  id = v_caller_uid AND activo = TRUE;

        IF v_caller_rol NOT IN ('director_general', 'director_ops', 'gerente') THEN
            RETURN jsonb_build_object(
                'ok',         false,
                'error_code', 'SIN_AUTORIZACION',
                'mensaje',    'Solo gerentes y directores pueden reasignar trámites.'
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 1. Validar analista origen (puede estar inactivo — de vacaciones)
    -- -------------------------------------------------------------------------
    SELECT * INTO v_origen FROM usuario WHERE id = p_analista_origen_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_ORIGEN_NO_ENCONTRADO',
            'mensaje',    'El analista origen ' || p_analista_origen_id || ' no existe.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Validar analista destino
    -- -------------------------------------------------------------------------
    SELECT * INTO v_destino FROM usuario WHERE id = p_analista_destino_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_DESTINO_NO_ENCONTRADO',
            'mensaje',    'El analista destino ' || p_analista_destino_id || ' no existe.'
        );
    END IF;

    IF v_destino.activo = FALSE THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_DESTINO_INACTIVO',
            'mensaje',    'El analista ' || v_destino.nombre || ' está inactivo y no puede recibir trámites.'
        );
    END IF;

    IF v_destino.rol != 'analista' THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_DESTINO_ROL_INCORRECTO',
            'mensaje',    'El usuario destino no tiene rol analista.',
            'rol_actual', v_destino.rol::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Mismo ramo — ambos analistas deben ser del mismo ramo
    -- -------------------------------------------------------------------------
    IF v_origen.ramo IS DISTINCT FROM v_destino.ramo THEN
        RETURN jsonb_build_object(
            'ok',           false,
            'error_code',   'RAMO_DIFERENTE',
            'mensaje',      'Los analistas deben pertenecer al mismo ramo.',
            'ramo_origen',  v_origen.ramo::text,
            'ramo_destino', v_destino.ramo::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Si el llamante es gerente, su ramo debe coincidir
    -- -------------------------------------------------------------------------
    IF v_caller_uid IS NOT NULL AND v_caller_rol = 'gerente' THEN
        IF v_caller_ramo IS DISTINCT FROM v_origen.ramo THEN
            RETURN jsonb_build_object(
                'ok',           false,
                'error_code',   'RAMO_DIFERENTE',
                'mensaje',      'Un gerente solo puede reasignar analistas de su propio ramo.',
                'tu_ramo',      v_caller_ramo::text,
                'ramo_analistas', v_origen.ramo::text
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Pasar motivo al trigger — una sola vez, válido para todo el loop
    --    El set_config con is_local=TRUE vive en la transacción actual.
    --    El loop corre en la misma transacción → el trigger lo lee en cada UPDATE.
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- -------------------------------------------------------------------------
    -- 6. Loop: reasignar todos los trámites activos no terminales
    -- -------------------------------------------------------------------------
    FOR v_tramite_id, v_folio IN
        SELECT t.id, t.folio
        FROM   tramite t
        WHERE  t.analista_id = p_analista_origen_id
          AND  t.activo      = TRUE
          AND  t.estado NOT IN ('aprobado', 'rechazado')
          AND  (p_solo_estados IS NULL OR t.estado::text = ANY(p_solo_estados))
        ORDER BY t.ultima_actividad DESC   -- más recientes primero
    LOOP
        UPDATE tramite
        SET    analista_id = p_analista_destino_id
        WHERE  id = v_tramite_id;
        -- trg_tramite_asignar_gerente (BEFORE): actualiza gerente_id si cambia ramo
        -- trg_tramite_registrar_asignacion (AFTER): crea tramite_evento con el motivo

        v_total  := v_total + 1;
        v_folios := array_append(v_folios, v_folio);
    END LOOP;

    PERFORM set_config('app.motivo_reasignacion', '', TRUE);  -- limpieza

    -- -------------------------------------------------------------------------
    -- 7. Retornar resumen
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok',                    true,
        'analista_origen_id',    p_analista_origen_id,
        'analista_origen_nombre', v_origen.nombre,
        'analista_destino_id',   p_analista_destino_id,
        'analista_destino_nombre', v_destino.nombre,
        'ramo',                  v_origen.ramo::text,
        'motivo',                p_motivo,
        'total_reasignados',     v_total,
        'folios_reasignados',    v_folios
    );
END;
$$;

COMMENT ON FUNCTION reasignar_tramites_masivo(uuid, uuid, text, uuid, text[]) IS
    'Reasigna todos los trámites activos no terminales de un analista a otro. '
    'Caso de uso: vacaciones o baja del analista. '
    'Llama set_config() una vez antes del loop — el trigger registrar_asignacion_tramite '
    'lee el motivo en cada iteración dentro de la misma transacción/conexión. '
    'Validaciones: mismo ramo, destino activo/analista, gerente del mismo ramo. '
    'p_solo_estados: filtrar por estados (NULL = todos los no terminales).';

GRANT EXECUTE ON FUNCTION reasignar_tramites_masivo(uuid, uuid, text, uuid, text[])
    TO authenticated, service_role;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000023_reasignacion_masiva.sql
-- =============================================================================

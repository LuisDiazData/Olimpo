-- =============================================================================
-- Migración: 20260616000000_modulo_17_ficha_completa_historial.sql
-- Módulo 17 — Ficha completa de póliza/trámite e historial unificado
-- =============================================================================
-- Esta migración da soporte de base de datos a la funcionalidad
-- "Gestión de pólizas y trámites con ficha completa e historial".
--
-- No crea tablas nuevas: la ficha de póliza se ensambla en la API a partir de
-- tablas existentes (tramite, tramite_evento, ot_activacion, comision_recibo).
-- Lo que sí necesita la DB son dos correcciones y una mejora del timeline:
--
-- HALLAZGO #1 — BUG LATENTE (estados terminales obsoletos):
--   reasignar_tramite() y reasignar_tramites_masivo() (migr. 21 y 23) todavía
--   bloquean la reasignación con la lista de terminales VIEJA
--   ('aprobado', 'rechazado'), que dejó de existir tras el rediseño de la
--   máquina de estados (migr. 20260529000030). Resultado: hoy NO bloquean
--   reasignar trámites ya cerrados. Se corrigen a los terminales actuales
--   (completado, rechazado_gnp, cancelado).
--
-- HALLAZGO #2 — TIMELINE INCOMPLETO (activaciones GNP):
--   registrar_activacion_gnp() inserta en ot_activacion + notificación, pero
--   NUNCA agrega un tramite_evento('activacion_gnp'). Las activaciones de GNP
--   y sus resoluciones quedaban fuera del historial/timeline. Se agrega un
--   trigger sobre ot_activacion que registra el evento (en alta y al resolver),
--   siguiendo el patrón de atribución de actor de los triggers existentes.
--
-- Relaciones con módulos anteriores:
--   ot_activacion   → tramite (Módulo 4 / Módulo 11)
--   tramite_evento  → tramite (Módulo 4) — historial inmutable append-only
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: reasignar_tramite() — corregir estados terminales
-- =============================================================================
-- Idéntica a la versión de la migración 20260524000023 salvo la lista de
-- estados terminales en la validación (paso 2). Se mantienen TODAS las
-- validaciones de autorización del llamante (defensa en profundidad).
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
    -- 0a. Identificar al llamante
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

    -- 1. Leer y bloquear el trámite
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

    -- 2. Validar estado — no reasignar trámites terminales
    --    (estados terminales actuales tras el rediseño de la máquina de estados)
    IF v_tramite.estado IN ('completado', 'rechazado_gnp', 'cancelado') THEN
        RETURN jsonb_build_object(
            'ok',          false,
            'error_code',  'ESTADO_TERMINAL',
            'mensaje',     'No se puede reasignar un trámite en estado ' || v_tramite.estado || '.',
            'estado_actual', v_tramite.estado::text
        );
    END IF;

    -- 3. Validar analista destino: existe, activo, rol correcto
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

    -- 0c. Si el llamante es gerente, su ramo debe coincidir con el del analista
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

    -- 4. Evitar no-op: mismo analista
    IF v_tramite.analista_id = p_analista_nuevo_id THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'MISMO_ANALISTA',
            'mensaje',    'El trámite ya está asignado a ' || v_analista_nuevo.nombre || '.'
        );
    END IF;

    -- 5. Guardar analista anterior para la respuesta
    v_analista_anterior_id := v_tramite.analista_id;
    IF v_analista_anterior_id IS NOT NULL THEN
        SELECT nombre INTO v_nombre_anterior
        FROM   usuario WHERE id = v_analista_anterior_id;
    END IF;

    -- 6. Pasar el motivo al trigger vía variable de sesión LOCAL
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- 7. Actualizar analista_id (dispara triggers de gerente y de evento)
    UPDATE tramite
    SET    analista_id = p_analista_nuevo_id
    WHERE  id = p_tramite_id;

    PERFORM set_config('app.motivo_reasignacion', '', TRUE);  -- limpieza por higiene

    -- 8. Retornar resultado
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
    'Bloquea trámites en estado terminal (completado/rechazado_gnp/cancelado). '
    'Si el llamante es un JWT autenticado: valida que sea gerente o director, '
    'y que un gerente solo asigne analistas de su propio ramo.';

GRANT EXECUTE ON FUNCTION reasignar_tramite(uuid, uuid, text)
    TO authenticated, service_role;


-- =============================================================================
-- SECCIÓN 2: reasignar_tramites_masivo() — corregir estados terminales
-- =============================================================================
-- Idéntica a la versión de la migración 20260524000023 salvo la lista de
-- terminales en el loop de selección de trámites (paso 6).
-- =============================================================================

CREATE OR REPLACE FUNCTION reasignar_tramites_masivo(
    p_analista_origen_id    uuid,
    p_analista_destino_id   uuid,
    p_motivo                text        DEFAULT NULL,
    p_realizado_por         uuid        DEFAULT NULL,
    p_solo_estados          text[]      DEFAULT NULL
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
    -- 0. Validar autorización del llamante
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

    -- 1. Validar analista origen (puede estar inactivo — de vacaciones)
    SELECT * INTO v_origen FROM usuario WHERE id = p_analista_origen_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_ORIGEN_NO_ENCONTRADO',
            'mensaje',    'El analista origen ' || p_analista_origen_id || ' no existe.'
        );
    END IF;

    -- 2. Validar analista destino
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

    -- 3. Mismo ramo — ambos analistas deben ser del mismo ramo
    IF v_origen.ramo IS DISTINCT FROM v_destino.ramo THEN
        RETURN jsonb_build_object(
            'ok',           false,
            'error_code',   'RAMO_DIFERENTE',
            'mensaje',      'Los analistas deben pertenecer al mismo ramo.',
            'ramo_origen',  v_origen.ramo::text,
            'ramo_destino', v_destino.ramo::text
        );
    END IF;

    -- 4. Si el llamante es gerente, su ramo debe coincidir
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

    -- 5. Pasar motivo al trigger — una sola vez, válido para todo el loop
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- 6. Loop: reasignar todos los trámites activos no terminales
    --    (terminales actuales: completado / rechazado_gnp / cancelado)
    FOR v_tramite_id, v_folio IN
        SELECT t.id, t.folio
        FROM   tramite t
        WHERE  t.analista_id = p_analista_origen_id
          AND  t.activo      = TRUE
          AND  t.estado NOT IN ('completado', 'rechazado_gnp', 'cancelado')
          AND  (p_solo_estados IS NULL OR t.estado::text = ANY(p_solo_estados))
        ORDER BY t.ultima_actividad DESC
    LOOP
        UPDATE tramite
        SET    analista_id = p_analista_destino_id
        WHERE  id = v_tramite_id;

        v_total  := v_total + 1;
        v_folios := array_append(v_folios, v_folio);
    END LOOP;

    PERFORM set_config('app.motivo_reasignacion', '', TRUE);  -- limpieza

    -- 7. Retornar resumen
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
    'Reasigna todos los trámites activos no terminales (completado/rechazado_gnp/cancelado) '
    'de un analista a otro. Caso de uso: vacaciones o baja del analista.';

GRANT EXECUTE ON FUNCTION reasignar_tramites_masivo(uuid, uuid, text, uuid, text[])
    TO authenticated, service_role;


-- =============================================================================
-- SECCIÓN 3: Activaciones GNP en el timeline (tramite_evento)
-- =============================================================================
-- Trigger que registra un evento 'activacion_gnp' en el timeline cuando:
--   • Se registra una activación de GNP (AFTER INSERT en ot_activacion)
--   • GNP resuelve la OT (AFTER UPDATE OF resuelta/resultado → resuelta=TRUE)
--
-- Atribución de actor: humano (auth.uid()) salvo que haya un agente IA activo
-- en la sesión (app.agente_ia_actual) — mismo patrón que registrar_asignacion_tramite()
-- y registrar_cambio_estado_tramite(). Es robusto frente a cualquier vía de
-- inserción (RPC registrar_activacion_gnp, router de activaciones, o agente IA).
-- =============================================================================

CREATE OR REPLACE FUNCTION registrar_evento_ot_activacion()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_agente_ia TEXT;
    v_usuario   UUID;
    v_desc      TEXT;
BEGIN
    -- Actor: IA si hay agente activo en la sesión, humano (auth.uid()) si no.
    -- Si ambos resultan NULL, el evento queda atribuido al "sistema" (permitido
    -- por ck_evento_actor).
    v_agente_ia := NULLIF(current_setting('app.agente_ia_actual', TRUE), '');
    v_usuario   := CASE WHEN v_agente_ia IS NULL THEN auth.uid() ELSE NULL END;

    IF TG_OP = 'INSERT' THEN
        v_desc := 'GNP activó la OT ' || NEW.numero_ot || '.'
                  || COALESCE(' Motivo: ' || NEW.motivo, '');

        INSERT INTO tramite_evento (
            tramite_id, tipo_evento, usuario_id, agente_ia_nombre,
            descripcion, datos, visible_en_timeline, created_at
        ) VALUES (
            NEW.tramite_id, 'activacion_gnp', v_usuario, v_agente_ia,
            v_desc,
            jsonb_strip_nulls(jsonb_build_object(
                'ot_activacion_id', NEW.id,
                'numero_ot',        NEW.numero_ot,
                'motivo',           NEW.motivo
            )),
            TRUE, NOW()
        );

    ELSIF TG_OP = 'UPDATE' THEN
        -- Solo registrar al pasar a resuelta o al cambiar el resultado de una resuelta
        IF NEW.resuelta = TRUE
           AND (OLD.resuelta = FALSE OR NEW.resultado IS DISTINCT FROM OLD.resultado)
        THEN
            v_desc := 'GNP resolvió la OT ' || NEW.numero_ot
                      || COALESCE(': ' || NEW.resultado, '') || '.';

            INSERT INTO tramite_evento (
                tramite_id, tipo_evento, usuario_id, agente_ia_nombre,
                descripcion, datos, visible_en_timeline, created_at
            ) VALUES (
                NEW.tramite_id, 'activacion_gnp', v_usuario, v_agente_ia,
                v_desc,
                jsonb_strip_nulls(jsonb_build_object(
                    'ot_activacion_id', NEW.id,
                    'numero_ot',        NEW.numero_ot,
                    'resultado',        NEW.resultado,
                    'resuelta',         NEW.resuelta
                )),
                TRUE, NOW()
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_evento_ot_activacion() IS
    'Registra en tramite_evento un evento activacion_gnp cuando se crea una OT '
    '(AFTER INSERT) o cuando GNP la resuelve (AFTER UPDATE OF resuelta/resultado). '
    'Lleva las activaciones de GNP al timeline del trámite (y de la ficha de póliza).';

DROP TRIGGER IF EXISTS trg_ot_activacion_evento_insert ON ot_activacion;
CREATE TRIGGER trg_ot_activacion_evento_insert
    AFTER INSERT ON ot_activacion
    FOR EACH ROW
    EXECUTE FUNCTION registrar_evento_ot_activacion();

DROP TRIGGER IF EXISTS trg_ot_activacion_evento_update ON ot_activacion;
CREATE TRIGGER trg_ot_activacion_evento_update
    AFTER UPDATE OF resuelta, resultado ON ot_activacion
    FOR EACH ROW
    EXECUTE FUNCTION registrar_evento_ot_activacion();


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260616000000_modulo_17_ficha_completa_historial.sql
-- =============================================================================

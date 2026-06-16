-- =============================================================================
-- 20260616000001_recrear_rpc_cambiar_estado.sql
--
-- La migración 20260529000030 eliminó la función cambiar_estado_tramite (que
-- usaba el TYPE estado_tramite_old) y no la recreó. Los agentes IA la siguen
-- llamando vía db.rpc("cambiar_estado_tramite", ...), por lo que sin esta
-- migración el pipeline falla con "function does not exist".
--
-- Esta versión está alineada con la máquina de estados nueva
-- (cat_estado_tramite + estado_tramite_transicion). La validación de la
-- transición y el registro del evento los hacen los triggers de la tabla
-- tramite (trg_tramite_validar_transicion, trg_tramite_registrar_estado);
-- esta función solo orquesta y devuelve el contrato esperado por el tool MCP.
-- =============================================================================

CREATE OR REPLACE FUNCTION cambiar_estado_tramite(
    p_tramite_id        uuid,
    p_estado_nuevo      text,
    p_descripcion       text  DEFAULT 'Cambio de estado vía agente IA',
    p_datos             jsonb DEFAULT '{}'::jsonb,
    p_agente_ia_nombre  text  DEFAULT NULL,
    p_usuario_id        uuid  DEFAULT NULL
)
RETURNS TABLE (
    ok               boolean,
    estado_anterior  text,
    estado_nuevo     text,
    evento_id        uuid,
    error_msg        text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_estado_anterior text;
    v_evento_id       uuid;
BEGIN
    SELECT estado INTO v_estado_anterior
        FROM tramite WHERE id = p_tramite_id
        FOR UPDATE;

    IF v_estado_anterior IS NULL THEN
        RETURN QUERY SELECT false, NULL::text, NULL::text, NULL::uuid, 'Trámite no encontrado';
        RETURN;
    END IF;

    -- Mismo estado: no-op idempotente.
    IF v_estado_anterior = p_estado_nuevo THEN
        RETURN QUERY SELECT true, v_estado_anterior, p_estado_nuevo, NULL::uuid, NULL::text;
        RETURN;
    END IF;

    -- Validación previa explícita para devolver un error limpio (en vez de que
    -- el trigger lance EXCEPCIÓN y reviente el RPC).
    IF NOT estado_tramite_puede_transicionar(v_estado_anterior, p_estado_nuevo) THEN
        RETURN QUERY SELECT false, v_estado_anterior, p_estado_nuevo, NULL::uuid,
            format('Transición inválida: %s → %s', v_estado_anterior, p_estado_nuevo);
        RETURN;
    END IF;

    -- Atribuir el cambio al agente IA para el trigger de auditoría
    -- (registrar_cambio_estado_tramite lee app.agente_ia_actual).
    PERFORM set_config('app.agente_ia_actual', COALESCE(p_agente_ia_nombre, ''), true);

    UPDATE tramite SET estado = p_estado_nuevo WHERE id = p_tramite_id;

    -- El trigger ya insertó el evento de cambio de estado; lo enriquecemos con
    -- la descripción específica del actor y los datos provistos.
    SELECT id INTO v_evento_id
        FROM tramite_evento
        WHERE tramite_id = p_tramite_id AND tipo_evento = 'cambio_estado'
        ORDER BY created_at DESC
        LIMIT 1;

    IF v_evento_id IS NOT NULL THEN
        UPDATE tramite_evento
            SET descripcion = COALESCE(p_descripcion, descripcion),
                datos = datos || COALESCE(p_datos, '{}'::jsonb)
            WHERE id = v_evento_id;
    END IF;

    RETURN QUERY SELECT true, v_estado_anterior, p_estado_nuevo, v_evento_id, NULL::text;
END;
$$;

GRANT EXECUTE ON FUNCTION cambiar_estado_tramite(uuid, text, text, jsonb, text, uuid)
    TO authenticated, service_role;

-- =============================================================================
-- FIN DE MIGRACIÓN: 20260616000001_recrear_rpc_cambiar_estado.sql
-- =============================================================================

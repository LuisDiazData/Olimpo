-- =============================================================================
-- Migración: 20260524000024_sla_vista_semaforo.sql
-- Vista sla_tramite_vista — calcula semáforo, vencimiento y días restantes
-- =============================================================================
--
-- Problema que resuelve:
--   El router de SLAs (slas.py) necesitaba campos calculados que no están
--   físicamente en sla_tramite:
--     • estado_semaforo   → verde / amarillo / rojo / pausado / cumplido
--     • vencido           → boolean: NOW() > fecha_limite
--     • dias_restantes    → número real (negativo si ya venció)
--     • dias_habiles_plazo → de sla_definicion (JOIN)
--     • alerta_porcentaje → de sla_definicion (JOIN)
--
--   En lugar de calcularlos en Python (costoso, duplica lógica), se exponen
--   como vista. El router los lee con un SELECT normal.
--
-- Regla de semáforo:
--   cumplido   → estado terminal: trámite cerrado a tiempo
--   rojo       → incumplido O (en_curso Y NOW() > fecha_limite)
--   pausado    → en_proceso_gnp; el reloj está detenido
--   amarillo   → tiempo_transcurrido / plazo_total >= alerta_porcentaje%
--   verde      → en curso y debajo del umbral de alerta
--
-- Esta vista también sirve para el dashboard de directores (trámites
-- próximos a vencer, tasa de cumplimiento por ramo, etc.).
-- =============================================================================

CREATE OR REPLACE VIEW sla_tramite_vista AS
SELECT
    -- Campos directos de sla_tramite
    st.id,
    st.tramite_id,
    st.sla_definicion_id,
    st.fecha_inicio,
    st.fecha_limite,
    st.estado,
    st.fecha_cumplimiento,
    st.alerta_enviada,
    st.alerta_enviada_en,
    st.pausado_en,
    st.segundos_pausados,
    st.created_at,
    st.updated_at,

    -- Campos de sla_definicion (desnormalizados para la UI)
    sd.nombre            AS sla_nombre,
    sd.dias_habiles      AS dias_habiles_plazo,
    sd.alerta_porcentaje,
    sd.tipo_tramite      AS sla_tipo_tramite,
    sd.ramo              AS sla_ramo,
    sd.prioridad_aplica  AS sla_prioridad,

    -- -------------------------------------------------------------------------
    -- Campo calculado: estado_semaforo
    -- -------------------------------------------------------------------------
    CASE
        WHEN st.estado = 'cumplido'
            THEN 'cumplido'::text
        WHEN st.estado = 'incumplido'
            THEN 'rojo'::text
        WHEN st.estado = 'pausado'
            THEN 'pausado'::text
        WHEN NOW() > st.fecha_limite
            THEN 'rojo'::text
        WHEN (
            -- Porcentaje de tiempo transcurrido >= umbral de alerta
            EXTRACT(EPOCH FROM (NOW() - st.fecha_inicio))
            / NULLIF(EXTRACT(EPOCH FROM (st.fecha_limite - st.fecha_inicio)), 0)
            * 100
        ) >= sd.alerta_porcentaje
            THEN 'amarillo'::text
        ELSE 'verde'::text
    END AS estado_semaforo,

    -- -------------------------------------------------------------------------
    -- Campo calculado: vencido
    -- -------------------------------------------------------------------------
    (NOW() > st.fecha_limite AND st.estado NOT IN ('cumplido', 'incumplido', 'pausado'))
        AS vencido,

    -- -------------------------------------------------------------------------
    -- Campo calculado: dias_restantes
    -- Positivo = tiempo restante; negativo = ya venció; NULL si no aplica
    -- -------------------------------------------------------------------------
    ROUND(
        EXTRACT(EPOCH FROM (st.fecha_limite - NOW()))::numeric / 86400,
        1
    ) AS dias_restantes,

    -- Porcentaje del tiempo consumido (útil para barras de progreso en la UI)
    ROUND(
        LEAST(
            EXTRACT(EPOCH FROM (NOW() - st.fecha_inicio))::numeric
            / NULLIF(EXTRACT(EPOCH FROM (st.fecha_limite - st.fecha_inicio))::numeric, 0)
            * 100,
            100
        ),
        1
    ) AS porcentaje_consumido

FROM sla_tramite st
JOIN sla_definicion sd ON sd.id = st.sla_definicion_id;

COMMENT ON VIEW sla_tramite_vista IS
    'Vista de sla_tramite enriquecida con campos calculados: '
    'estado_semaforo (verde/amarillo/rojo/pausado/cumplido), vencido (bool), '
    'dias_restantes (decimal, negativo si venció), porcentaje_consumido. '
    'Incluye datos de sla_definicion vía JOIN (nombre, dias_habiles, alerta_porcentaje). '
    'La usan el router de SLAs, el dashboard de directores y los agentes MCP.';

-- La vista hereda las políticas RLS de sus tablas base.
-- No se necesita ENABLE ROW LEVEL SECURITY en vistas en Supabase/PostgREST.
GRANT SELECT ON sla_tramite_vista TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000024_sla_vista_semaforo.sql
-- =============================================================================

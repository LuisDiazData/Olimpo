-- =============================================================================
-- Migración: 20260522000014_pipeline_reintento.sql
-- Tabla pipeline_reintento — resiliencia y recuperación del pipeline de agentes IA
-- =============================================================================
-- Propósito:
--   Cuando un agente IA falla (error de red, timeout LLM, excepción inesperada),
--   el pipeline no debe abortar silenciosamente. Esta tabla implementa una cola
--   de reintentos con backoff: cada fallo registra cuándo volver a intentarlo,
--   cuántos intentos se han hecho y cuál fue el motivo del fallo.
--
-- Flujo de uso:
--   1. Un agente falla → el worker Celery inserta en pipeline_reintento
--      con estado='pendiente' e intentar_desde = NOW() + backoff
--   2. El scheduler de Celery consulta filas WHERE estado='pendiente'
--      AND intentar_desde <= NOW() y reactiva el agente
--   3. Si el reintento tiene éxito → estado='completado'
--   4. Si fallaron todos los intentos (intento_num = max_intentos) → estado='abandonado'
--      y el trámite se marca requiere_atencion = TRUE manualmente desde el backend
--
-- Relación con agente_ia_log:
--   Cada reintento crea una nueva fila en agente_ia_log con intento incrementado.
--   pipeline_reintento.agente_ia_log_id apunta al último log de intento para
--   correlación rápida sin JOIN adicional.
--
-- Relaciones:
--   pipeline_reintento.tramite_id       → tramite.id       (Módulo 4)
--   pipeline_reintento.agente_ia_log_id → agente_ia_log.id (Módulo 10)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: ENUM estado_reintento
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type
        WHERE typname = 'estado_reintento'
          AND typnamespace = 'public'::regnamespace
    ) THEN
        CREATE TYPE public.estado_reintento AS ENUM (
            'pendiente',    -- en cola, esperando hasta intentar_desde
            'en_proceso',   -- el worker lo tomó y está ejecutando el agente
            'completado',   -- reintento exitoso, el agente terminó sin error
            'abandonado'    -- se agotaron los intentos sin éxito
        );

        COMMENT ON TYPE public.estado_reintento IS
            'Estado del reintento en la cola. '
            'pendiente → en_proceso → completado (éxito). '
            'pendiente → en_proceso → pendiente (nuevo intento, intento_num++). '
            'pendiente → abandonado (intento_num = max_intentos y falló de nuevo).';
    END IF;
END;
$$;


-- =============================================================================
-- SECCIÓN 2: TABLA pipeline_reintento
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.pipeline_reintento (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Contexto del reintento
    -- -------------------------------------------------------------------------
    -- Trámite que se estaba procesando cuando ocurrió el fallo
    tramite_id      UUID                NOT NULL REFERENCES public.tramite(id),

    -- Qué agente falló y debe reintentarse
    agente_nombre   TEXT                NOT NULL
                    CHECK (agente_nombre IN (
                        'agente_1', 'agente_2', 'agente_3',
                        'agente_4', 'agente_5', 'agente_6'
                    )),

    -- -------------------------------------------------------------------------
    -- Estado y control de cola
    -- -------------------------------------------------------------------------
    estado          public.estado_reintento NOT NULL DEFAULT 'pendiente',

    -- Número de intento actual (empieza en 1 — el primer reintento tras el fallo)
    intento_num     SMALLINT            NOT NULL DEFAULT 1
                    CHECK (intento_num >= 1),

    -- Máximo de intentos permitidos antes de marcar como abandonado
    max_intentos    SMALLINT            NOT NULL DEFAULT 3
                    CHECK (max_intentos >= 1),

    -- Garantía de consistencia: intento_num no puede superar max_intentos
    CONSTRAINT ck_reintento_intentos CHECK (intento_num <= max_intentos),

    -- -------------------------------------------------------------------------
    -- Motivo del fallo original
    -- -------------------------------------------------------------------------
    -- Texto del error que disparó el reintento (traceback, mensaje de excepción, etc.)
    motivo          TEXT                NOT NULL,
    CONSTRAINT ck_reintento_motivo_not_empty CHECK (TRIM(motivo) <> ''),

    -- -------------------------------------------------------------------------
    -- Scheduling
    -- -------------------------------------------------------------------------
    -- Timestamp desde el que el scheduler puede tomar este reintento.
    -- El worker Celery implementa el backoff modificando este campo:
    --   intento_num=1 → intentar_desde = NOW() + 2 minutos
    --   intento_num=2 → intentar_desde = NOW() + 10 minutos
    --   intento_num=3 → intentar_desde = NOW() + 30 minutos
    -- El cálculo del backoff es responsabilidad del worker, no de la DB.
    intentar_desde  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- Trazabilidad — enlace al último intento de ejecución
    -- -------------------------------------------------------------------------
    -- FK al registro de agente_ia_log del último intento (NULL hasta que Celery
    -- crea el registro de log al iniciar el reintento).
    agente_ia_log_id UUID               NULL REFERENCES public.agente_ia_log(id),

    -- -------------------------------------------------------------------------
    -- Auditoría Olimpo
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.pipeline_reintento IS
    'Cola de reintentos del pipeline de agentes IA. '
    'Cuando un agente falla, el worker Celery inserta aquí con estado=pendiente. '
    'El scheduler reactiva el agente cuando intentar_desde <= NOW(). '
    'Máximo max_intentos intentos — si se agotan, estado=abandonado y el trámite '
    'se marca requiere_atencion=TRUE en el backend.';

COMMENT ON COLUMN public.pipeline_reintento.tramite_id IS
    'Trámite que se procesaba cuando ocurrió el fallo. '
    'El worker usa este id para reanudar el pipeline desde el agente correcto.';
COMMENT ON COLUMN public.pipeline_reintento.agente_nombre IS
    'Agente que debe reintentarse. El worker lo instancia y lo llama con el tramite_id.';
COMMENT ON COLUMN public.pipeline_reintento.intento_num IS
    'Número de intento en curso (1-indexed). Se incrementa con cada reintento fallido.';
COMMENT ON COLUMN public.pipeline_reintento.max_intentos IS
    'Límite de intentos. Configurable — trámites urgentes podrían tener max_intentos=5.';
COMMENT ON COLUMN public.pipeline_reintento.motivo IS
    'Traceback o mensaje de error que generó el reintento. Para debugging y observabilidad.';
COMMENT ON COLUMN public.pipeline_reintento.intentar_desde IS
    'El worker solo toma filas donde intentar_desde <= NOW(). '
    'Implementa backoff exponencial al ser actualizado por el worker en cada fallo.';
COMMENT ON COLUMN public.pipeline_reintento.agente_ia_log_id IS
    'FK al último agente_ia_log creado para este reintento. '
    'Permite correlacionar el reintento con su trace de Langfuse sin JOIN adicional.';


-- =============================================================================
-- SECCIÓN 3: ÍNDICES
-- =============================================================================

-- Índice principal para el scheduler de Celery.
-- Consulta: "dame todos los reintentos pendientes que ya pueden ejecutarse,
--            ordenados por agente para agrupar la carga"
-- Es parcial (solo estado='pendiente') porque es el único estado que el
-- scheduler consulta en el loop. Los demás estados son archivos históricos.
CREATE INDEX IF NOT EXISTS idx_pipeline_reintento_pendientes
    ON public.pipeline_reintento (agente_nombre, intentar_desde)
    WHERE estado = 'pendiente';

COMMENT ON INDEX idx_pipeline_reintento_pendientes IS
    'Índice parcial para el scheduler Celery. '
    'Query: agente_nombre + intentar_desde WHERE estado = ''pendiente''. '
    'Solo indexa filas accionables — los estados completado/abandonado quedan fuera.';

-- Índice para ver el historial de reintentos de un trámite específico
CREATE INDEX IF NOT EXISTS idx_pipeline_reintento_tramite
    ON public.pipeline_reintento (tramite_id, created_at DESC);

COMMENT ON INDEX idx_pipeline_reintento_tramite IS
    'Historial de reintentos de un trámite. Usado en el panel de detalle del trámite '
    'para que el analista vea por qué el pipeline se reintentó.';


-- =============================================================================
-- SECCIÓN 4: TRIGGER updated_at
-- =============================================================================

CREATE TRIGGER trg_pipeline_reintento_updated_at
    BEFORE UPDATE ON public.pipeline_reintento
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- SECCIÓN 5: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- El pipeline_reintento es una tabla de operaciones internas del sistema.
-- Los agentes IA (service_role) escriben y leen sin restricción.
-- Los usuarios humanos solo necesitan visibilidad para diagnóstico:
--   director_general / director_ops → ven todos los reintentos
--   gerentes → no tienen caso de uso directo sobre esta tabla
--   analistas → no tienen caso de uso directo sobre esta tabla
--
-- INSERT/UPDATE: solo service_role (workers Celery). No se crean policies de
-- escritura para authenticated — la escritura es responsabilidad del backend.

ALTER TABLE public.pipeline_reintento ENABLE ROW LEVEL SECURITY;

-- Directores pueden ver el estado del pipeline para diagnóstico y soporte
CREATE POLICY pol_pipeline_reintento_select
    ON public.pipeline_reintento
    FOR SELECT
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_pipeline_reintento_select ON public.pipeline_reintento IS
    'Solo directores pueden ver la cola de reintentos. '
    'Permite diagnosticar agentes atascados desde la UI del Superadmin o el dashboard. '
    'Los agentes IA (service_role) bypasan RLS para lectura y escritura.';


-- =============================================================================
-- SECCIÓN 6: GRANTS
-- =============================================================================

-- authenticated solo tiene SELECT (y solo para directores por la policy de arriba)
-- INSERT y UPDATE los hace el backend con service_role — sin GRANT a authenticated
GRANT SELECT ON TABLE public.pipeline_reintento TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000014_pipeline_reintento.sql
-- =============================================================================

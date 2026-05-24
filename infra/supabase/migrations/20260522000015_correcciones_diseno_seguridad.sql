-- =============================================================================
-- Migración: 20260522000015_correcciones_diseno_seguridad.sql
-- Correcciones de diseño, seguridad y rendimiento post-diagnóstico
-- =============================================================================
-- CORRECCIONES INCLUIDAS:
--
--   DISEÑO-01: Índice compuesto en tramite.paso_pipeline_actual para detectar
--     trámites con agente IA activo y calcular timeouts del pipeline.
--
--   DISEÑO-02: Eliminar el UNIQUE constraint en tramite.folio_ot y reemplazar
--     por un índice simple. folio_ot no es un identificador universal único:
--     GNP puede reutilizar números de OT entre ramos o años distintos, y en
--     el modelo actual un trámite puede cambiar de OT (force_update_folio).
--     La tabla ot_activacion guarda el historial completo con su propia clave.
--
--   DISEÑO-03: Reemplazar calcular_fecha_limite_sla() con versión con límite de
--     iteraciones. La versión original podía entrar en un bucle infinito si
--     dias_inhabil tenía todos los días marcados como inhábiles para un ramo.
--
--   DISEÑO-04: Agregar columna origen_sistema a tramite_evento y actualizar el
--     CHECK constraint del actor para documentar explícitamente el caso de
--     eventos generados por procesos del sistema (sin usuario humano ni agente IA).
--
--   SEG-01: Revocar EXECUTE de notificar_a_rol() a authenticated. Esta función
--     itera sobre usuarios y envía notificaciones masivas — es un vector de
--     escalación de privilegios si un analista o gerente puede llamarla.
--     Se crea una función wrapper notificar_a_rol_director() que valida el rol.
--
--   SEG-02: Agregar SET search_path a registrar_validacion_aprendizaje() que
--     en la migración original (000005) no lo tenía, creando vulnerabilidad
--     de privilege escalation via search_path hijacking.
--
--   SEG-03: Reemplazar crear_notificacion() con versión que valida que el
--     usuario destino exista y esté activo antes de insertar. La versión
--     anterior podía crear notificaciones para usuarios inexistentes o dados
--     de baja, generando ruido y potenciales inconsistencias.
--
--   PERF-01: Índices en agente_ia_log para análisis de costos por agente y
--     detección de ejecuciones lentas. El Superadmin los necesita para la
--     vista "Agent Health".
-- =============================================================================


-- =============================================================================
-- DISEÑO-01: ÍNDICE EN tramite.paso_pipeline_actual
-- =============================================================================
-- Permite detectar eficientemente trámites con agente IA en ejecución activa
-- y calcular si superaron el PIPELINE_TIMEOUT_MINUTOS de configuracion_sistema.
-- El índice es parcial: solo indexa filas donde hay un agente corriendo (NOT NULL)
-- y el trámite está activo. Excluye el 90%+ de filas (trámites terminados).

CREATE INDEX IF NOT EXISTS idx_tramite_pipeline_activo
    ON public.tramite (paso_pipeline_actual, paso_pipeline_inicio)
    WHERE paso_pipeline_actual IS NOT NULL AND activo = TRUE;

COMMENT ON INDEX idx_tramite_pipeline_activo IS
    'Detecta trámites con agente IA activo en este momento. '
    'El scheduler de timeouts consulta paso_pipeline_inicio para identificar '
    'ejecuciones que superaron PIPELINE_TIMEOUT_MINUTOS. '
    'Parcial: solo trámites activos con agente corriendo (< 1% del total).';


-- =============================================================================
-- DISEÑO-02: ELIMINAR UNIQUE EN tramite.folio_ot — REEMPLAZAR POR ÍNDICE SIMPLE
-- =============================================================================
-- Justificación técnica:
--   folio_ot proviene de GNP y NO está bajo nuestro control. GNP puede:
--     a) Reutilizar números de OT en distintos períodos o ramos.
--     b) Asignar la misma OT a un trámite modificado (corrección de GNP).
--   El constraint UNIQUE actual bloquea estas situaciones con un error de DB,
--   forzando intervención manual. Es mejor permitir duplicados y manejarlos
--   en la lógica de negocio de la app. La tabla ot_activacion (Módulo 11)
--   es la fuente canónica del historial de OTs.
--
--   tramite.folio_ot es solo el campo de "acceso rápido" a la OT principal.
--   Si GNP reasigna o corrige el número, la app debe poder actualizarlo sin error.

-- Eliminar el constraint UNIQUE original
ALTER TABLE public.tramite
    DROP CONSTRAINT IF EXISTS uq_tramite_folio_ot;

-- Verificar y recrear el índice simple (si ya existe el del módulo 4, este es
-- redundante pero idempotente gracias a IF NOT EXISTS)
-- El índice idx_tramite_folio_ot ya existe desde 20260522000003 y es un índice
-- simple (no unique). Solo necesitamos asegurarnos que el UNIQUE constraint
-- haya sido eliminado.

COMMENT ON COLUMN public.tramite.folio_ot IS
    'Número de OT asignado por GNP (campo de acceso rápido). '
    'No tiene constraint UNIQUE — GNP puede reutilizar números. '
    'El historial completo de OTs vive en ot_activacion.';


-- =============================================================================
-- DISEÑO-03: REEMPLAZAR calcular_fecha_limite_sla() CON LÍMITE DE ITERACIONES
-- =============================================================================
-- Problema con la versión original (20260522000007):
--   El WHILE LOOP no tiene cota superior. Si por error en dias_inhabil se marcan
--   demasiados días como inhábiles, la función entra en un loop infinito que
--   eventualmente mata la sesión PostgreSQL por statement_timeout.
--
-- Solución: límite de iteraciones = p_dias * 4
--   En el peor caso realista, 4 semanas por cada día hábil solicitado es más
--   que suficiente (máximo 2 días inhábiles consecutivos en México). Si se
--   supera este límite, la función lanza EXCEPTION con mensaje explicativo
--   para que el administrador corrija los datos de dias_inhabil.

CREATE OR REPLACE FUNCTION public.calcular_fecha_limite_sla(
    p_inicio    TIMESTAMPTZ,
    p_dias      INTEGER,
    p_ramo      ramo_usuario DEFAULT NULL
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_fecha_actual  DATE    := p_inicio::DATE;
    v_contador      INTEGER := 0;
    -- Límite de iteraciones: 4 semanas de días calendario por cada día hábil pedido.
    -- Protege contra loops infinitos cuando dias_inhabil está mal configurado.
    v_max_iter      INTEGER := p_dias * 28;
    v_iteraciones   INTEGER := 0;
BEGIN
    IF p_dias <= 0 THEN
        RAISE EXCEPTION
            'dias_habiles debe ser mayor a 0, se recibió %', p_dias;
    END IF;

    WHILE v_contador < p_dias LOOP
        v_fecha_actual  := v_fecha_actual + 1;
        v_iteraciones   := v_iteraciones + 1;

        -- Límite de seguridad: evitar bucle infinito por datos incorrectos
        IF v_iteraciones > v_max_iter THEN
            RAISE EXCEPTION
                'calcular_fecha_limite_sla: se superó el límite de % iteraciones '
                'calculando % días hábiles desde % para ramo %. '
                'Verificar que la tabla dia_inhabil no tenga periodos completos '
                'marcados como inhábiles para este ramo.',
                v_max_iter, p_dias, p_inicio, p_ramo;
        END IF;

        -- Saltar fines de semana (0=domingo, 6=sábado)
        IF EXTRACT(DOW FROM v_fecha_actual) IN (0, 6) THEN
            CONTINUE;
        END IF;

        -- Saltar días inhábiles globales (aplica_ramo IS NULL)
        -- y días inhábiles específicos del ramo del trámite
        IF EXISTS (
            SELECT 1 FROM public.dia_inhabil
            WHERE fecha = v_fecha_actual
              AND (
                aplica_ramo IS NULL
                OR (p_ramo IS NOT NULL AND aplica_ramo = p_ramo)
              )
        ) THEN
            CONTINUE;
        END IF;

        v_contador := v_contador + 1;
    END LOOP;

    -- Preservar la hora exacta del inicio — solo avanza la fecha
    RETURN (v_fecha_actual::TEXT || ' ' || (p_inicio AT TIME ZONE 'UTC')::TIME::TEXT)::TIMESTAMPTZ;
END;
$$;

COMMENT ON FUNCTION public.calcular_fecha_limite_sla(TIMESTAMPTZ, INTEGER, ramo_usuario) IS
    'Calcula el deadline de un SLA en días hábiles, excluyendo fines de semana '
    'y los días configurados en dia_inhabil que apliquen al ramo dado. '
    'Si p_ramo es NULL, solo excluye los días globales (aplica_ramo IS NULL). '
    'Límite de iteraciones = p_dias * 28 para proteger contra loops infinitos '
    'causados por datos incorrectos en dia_inhabil.';


-- =============================================================================
-- DISEÑO-04: COLUMNA origen_sistema EN tramite_evento
-- =============================================================================
-- Agrega contexto para el tercer caso de actor: un proceso del sistema (job de
-- Celery, scheduled task) que no es ni un usuario humano ni un agente IA.
-- Ejemplos: el job de alertas SLA, el job de limpieza de passwords ZIP,
-- el scheduler de reintentos de pipeline.
--
-- El CHECK constraint existente ck_evento_actor ya permitía el caso de ambos
-- NULL (comentado como "eventos del sistema"). Se formaliza documentando qué
-- proceso del sistema generó el evento.

ALTER TABLE public.tramite_evento
    ADD COLUMN IF NOT EXISTS origen_sistema TEXT NULL;

COMMENT ON COLUMN public.tramite_evento.origen_sistema IS
    'Proceso del sistema que generó el evento cuando usuario_id y agente_ia_nombre '
    'son ambos NULL. Ejemplos: ''job_alertas_sla'', ''job_limpieza_passwords'', '
    '''scheduler_pipeline_reintento''. Mejora la trazabilidad de eventos automáticos.';

-- Actualizar el CHECK constraint del actor para documentar los 3 casos válidos.
-- Primero lo eliminamos, luego lo recreamos con mejor documentación.
-- NOTA: El nombre del constraint en la tabla original es ck_evento_actor.

ALTER TABLE public.tramite_evento
    DROP CONSTRAINT IF EXISTS ck_evento_actor;

ALTER TABLE public.tramite_evento
    ADD CONSTRAINT ck_evento_actor CHECK (
        -- Caso 1: Actor humano (usuario_id tiene valor, agente_ia_nombre es NULL)
        (usuario_id IS NOT NULL AND agente_ia_nombre IS NULL)
        -- Caso 2: Actor IA (agente_ia_nombre tiene valor, usuario_id es NULL)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NOT NULL)
        -- Caso 3: Proceso del sistema (ambos NULL, origen_sistema documenta el proceso)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NULL)
    );

COMMENT ON CONSTRAINT ck_evento_actor ON public.tramite_evento IS
    'Exactamente uno de los tres casos de actor es válido: '
    '(1) usuario humano: usuario_id NOT NULL, agente_ia_nombre IS NULL. '
    '(2) agente IA: agente_ia_nombre NOT NULL, usuario_id IS NULL. '
    '(3) proceso del sistema: ambos NULL, origen_sistema documenta el proceso automático.';


-- =============================================================================
-- SEG-01: REVOCAR notificar_a_rol() DE authenticated
-- =============================================================================
-- Vulnerabilidad:
--   La función notificar_a_rol() itera sobre TODOS los usuarios de un rol y
--   llama crear_notificacion() por cada uno. Un analista autenticado podría
--   invocarla vía RPC y enviar notificaciones masivas a cualquier rol,
--   incluyendo directores, con cualquier contenido — un vector de spam
--   interno o escalación de información sensible.
--
-- Solución:
--   1. REVOKE EXECUTE en notificar_a_rol() de authenticated.
--   2. Crear notificar_a_rol_director() wrapper SECURITY DEFINER que valida
--      que el caller sea director_general o director_ops antes de invocar
--      la función interna.
--
-- El backend (service_role) puede seguir llamando notificar_a_rol() directamente
-- sin necesidad del wrapper — bypasa RLS y tiene acceso total.

REVOKE EXECUTE ON FUNCTION public.notificar_a_rol(
    rol_usuario,
    ramo_usuario,
    tipo_notificacion,
    TEXT,
    TEXT,
    UUID,
    JSONB
) FROM authenticated;


-- Wrapper con validación de rol para uso desde el frontend o APIs autenticadas
CREATE OR REPLACE FUNCTION public.notificar_a_rol_director(
    p_rol           rol_usuario,
    p_ramo          ramo_usuario        DEFAULT NULL,
    p_tipo          tipo_notificacion   DEFAULT NULL,
    p_titulo        TEXT                DEFAULT NULL,
    p_cuerpo        TEXT                DEFAULT NULL,
    p_tramite_id    UUID                DEFAULT NULL,
    p_datos         JSONB               DEFAULT '{}'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
    -- Solo directores pueden usar esta función desde el cliente autenticado
    IF auth_rol() NOT IN ('director_general', 'director_ops') THEN
        RAISE EXCEPTION
            'Acceso denegado: notificar_a_rol_director() requiere rol '
            'director_general o director_ops. Rol actual: %', auth_rol();
    END IF;

    -- Delegar a la función interna que tiene la lógica completa
    RETURN public.notificar_a_rol(
        p_rol,
        p_ramo,
        p_tipo,
        p_titulo,
        p_cuerpo,
        p_tramite_id,
        p_datos
    );
END;
$$;

COMMENT ON FUNCTION public.notificar_a_rol_director(rol_usuario, ramo_usuario, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Wrapper de notificar_a_rol() para uso desde clientes autenticados. '
    'Valida que el caller sea director_general o director_ops antes de ejecutar. '
    'El backend (service_role) llama notificar_a_rol() directamente sin este wrapper. '
    'REVOKE en notificar_a_rol() previene que analistas envíen notificaciones masivas.';

GRANT EXECUTE ON FUNCTION public.notificar_a_rol_director(
    rol_usuario,
    ramo_usuario,
    tipo_notificacion,
    TEXT,
    TEXT,
    UUID,
    JSONB
) TO authenticated;


-- =============================================================================
-- SEG-02: SET search_path EN registrar_validacion_aprendizaje()
-- =============================================================================
-- La función registrar_validacion_aprendizaje() definida en 20260522000005
-- es un trigger BEFORE UPDATE que se ejecuta con privilegios del owner (SECURITY
-- DEFINER implícito en triggers según el contexto de ejecución). Sin search_path
-- explícito, un atacante con CREATE SCHEMA podría inyectar funciones en un
-- esquema temporal y secuestrar la ruta de búsqueda durante la ejecución.

CREATE OR REPLACE FUNCTION public.registrar_validacion_aprendizaje()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
    IF NEW.aprendizaje_validado = TRUE AND OLD.aprendizaje_validado = FALSE THEN
        NEW.validado_por     := auth.uid();
        NEW.fecha_validacion := NOW();
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.registrar_validacion_aprendizaje() IS
    'Al marcar un aprendizaje como validado, auto-registra quién lo validó y cuándo. '
    'El analista solo necesita hacer UPDATE aprendizaje_validado = TRUE. '
    'search_path explícito para prevenir privilege escalation via schema hijacking.';


-- =============================================================================
-- SEG-03: REEMPLAZAR crear_notificacion() CON VALIDACIÓN DE USUARIO DESTINO
-- =============================================================================
-- Vulnerabilidad en la versión original (20260522000008):
--   La función no verifica que p_usuario_id exista en la tabla usuario y esté
--   activo. Un backend con bug podría crear notificaciones para:
--     a) UUIDs inexistentes en usuario (FK a usuario.id garantiza existencia
--        en la tabla, pero no que el usuario esté activo).
--     b) Usuarios dados de baja (activo = FALSE) — notificaciones huérfanas
--        que nunca serán leídas y consumen espacio.
--
-- La FK a usuario(id) ya garantiza que el UUID exista. Solo agregamos
-- la validación de usuario activo antes de insertar.

CREATE OR REPLACE FUNCTION public.crear_notificacion(
    p_usuario_id    UUID,
    p_tipo          tipo_notificacion,
    p_titulo        TEXT,
    p_cuerpo        TEXT,
    p_tramite_id    UUID    DEFAULT NULL,
    p_datos         JSONB   DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_activa        BOOLEAN;
    v_notif_id      UUID;
    v_usuario_activo BOOLEAN;
BEGIN
    -- SEG-03: Validar que el usuario destino exista y esté activo
    SELECT activo INTO v_usuario_activo
    FROM public.usuario
    WHERE id = p_usuario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'crear_notificacion: el usuario % no existe en public.usuario.',
            p_usuario_id;
    END IF;

    IF v_usuario_activo = FALSE THEN
        -- Usuario inactivo (dado de baja) — no insertar, retornar NULL silenciosamente
        -- para no romper el pipeline cuando un analista fue desactivado durante
        -- el procesamiento de un trámite que le estaba asignado.
        RETURN NULL;
    END IF;

    -- Verificar preferencias del usuario (modelo opt-out)
    SELECT activa INTO v_activa
    FROM public.notificacion_config
    WHERE usuario_id = p_usuario_id
      AND tipo       = p_tipo;

    -- Si existe config y está desactivada, no insertar
    IF FOUND AND v_activa = FALSE THEN
        RETURN NULL;
    END IF;

    -- Insertar la notificación
    INSERT INTO public.notificacion (
        usuario_id,
        tipo,
        titulo,
        cuerpo,
        tramite_id,
        datos
    ) VALUES (
        p_usuario_id,
        p_tipo,
        TRIM(p_titulo),
        TRIM(p_cuerpo),
        p_tramite_id,
        COALESCE(p_datos, '{}')
    )
    RETURNING id INTO v_notif_id;

    RETURN v_notif_id;
END;
$$;

COMMENT ON FUNCTION public.crear_notificacion(UUID, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Crea una notificación para un usuario respetando sus preferencias. '
    'Modelo opt-out: si no hay config, se crea la notificación. '
    'Si el usuario está inactivo o desactivó ese tipo, retorna NULL sin insertar. '
    'El INSERT dispara Supabase Realtime al navegador del destinatario. '
    'SEG-03: valida que el usuario exista y esté activo antes de insertar.';


-- =============================================================================
-- PERF-01: ÍNDICES EN agente_ia_log PARA ANÁLISIS DE COSTOS Y RENDIMIENTO
-- =============================================================================
-- El Superadmin necesita dos vistas en "Agent Health" (Fase 7 del roadmap):
--   1. Costo acumulado por agente en un período → idx_agente_log_agente_costo
--   2. Ejecuciones más lentas por agente → idx_agente_log_duracion
--
-- Ambos son índices parciales que cubren solo las ejecuciones completadas
-- (el 80%+ del volumen en un sistema maduro) — excluyen los iniciados y fallidos
-- para mantener el tamaño del índice pequeño y el lookup eficiente.

-- Índice para análisis de costos por agente y período
CREATE INDEX IF NOT EXISTS idx_agente_log_agente_costo
    ON public.agente_ia_log (agente_nombre, inicio DESC, costo_usd)
    WHERE costo_usd IS NOT NULL AND estado = 'completado';

COMMENT ON INDEX idx_agente_log_agente_costo IS
    'Análisis de costos en el Superadmin: gasto en USD por agente y período. '
    'Query típica: GROUP BY agente_nombre, date_trunc(''day'', inicio) '
    'SUM(costo_usd) WHERE estado = ''completado''. '
    'Parcial: solo ejecuciones completadas con costo registrado.';

-- Índice para detección de ejecuciones lentas (outliers de rendimiento)
CREATE INDEX IF NOT EXISTS idx_agente_log_duracion
    ON public.agente_ia_log (agente_nombre, duracion_ms DESC)
    WHERE estado = 'completado' AND duracion_ms IS NOT NULL;

COMMENT ON INDEX idx_agente_log_duracion IS
    'Detección de ejecuciones lentas: las N más tardadas por agente. '
    'Permite detectar degradación gradual del rendimiento de los LLMs. '
    'Query típica: ORDER BY duracion_ms DESC LIMIT 10 WHERE agente_nombre = X.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000015_correcciones_diseno_seguridad.sql
-- =============================================================================

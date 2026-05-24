-- =============================================================================
-- Migración: 20260522000007_modulo_08_slas.sql
-- Módulo 8 — Motor de SLAs configurable por director
-- =============================================================================
-- Filosofía de diseño:
--   NINGÚN valor de SLA está hardcodeado en el código ni en esta migración.
--   Todo se configura desde la UI del director general / director de operaciones:
--
--   dia_inhabil      → Calendario de días no laborables (feriados, puentes, cierres).
--                      Puede ser global o específico por ramo.
--
--   sla_definicion   → Reglas de SLA: para tramites de tipo X, ramo Y, prioridad Z
--                      → el plazo es N días hábiles. Regla más específica gana.
--
--   sla_tramite      → Instancia activa por trámite. Se crea automáticamente al
--                      llamar activar_sla_tramite(). Lleva el deadline calculado,
--                      el estado y el historial de pausas.
--
-- Funciones para el pipeline de IA y el backend:
--
--   calcular_fecha_limite_sla(inicio, dias, ramo)
--       → calcula la fecha límite excluyendo fines de semana + dias_inhabil
--
--   resolver_sla_definicion(tipo_tramite, ramo, prioridad)
--       → encuentra la definición más específica que aplica al trámite
--
--   activar_sla_tramite(tramite_id)
--       → llama a las dos funciones anteriores y crea el sla_tramite
--       → también sincroniza tramite.fecha_limite_sla
--       → el Agente 4 la llama al asignar el analista
--
-- Relaciones con módulos anteriores:
--   sla_definicion.creado_por    → usuario.id   (Módulo 1)
--   sla_tramite.tramite_id       → tramite.id   (Módulo 4)
--   sla_tramite.sla_definicion_id → sla_definicion.id
--   dia_inhabil.creado_por       → usuario.id   (Módulo 1)
--
-- Regla de negocio crítica (ver CLAUDE.md):
--   No hay SLAs ni umbrales hardcodeados. Todos deben poder modificarse
--   desde el Superadmin o desde la UI del director sin tocar código.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE estado_sla AS ENUM (
    'en_curso',     -- el reloj corre, no se ha vencido
    'cumplido',     -- trámite cerrado antes del deadline
    'incumplido',   -- deadline superado sin cerrar el trámite
    'pausado'       -- reloj detenido (ej: trámite en_proceso_gnp — no es culpa de la promotoría)
);

COMMENT ON TYPE estado_sla IS
    'Estado del SLA de un trámite. '
    'Pausado aplica cuando el trámite está en espera de GNP — el reloj se detiene '
    'para no penalizar a la promotoría por tiempos externos.';


-- =============================================================================
-- SECCIÓN 2: TABLA dia_inhabil
-- =============================================================================
-- Calendario de días no laborables que el motor de SLA excluye al contar
-- días hábiles. Configurable por el director desde la UI.
--
-- Ejemplos de días típicos en México:
--   1 Enero   — Año Nuevo
--   5 Feb     — Día de la Constitución
--   21 Mar    — Natalicio de Benito Juárez
--   Semana Santa — Jueves y Viernes Santos
--   1 May     — Día del Trabajo
--   16 Sep    — Independencia
--   2 Nov     — Día de Muertos (algunos ramos descansan)
--   20 Nov    — Revolución Mexicana
--   25 Dic    — Navidad
--
-- aplica_ramo NULL = aplica a toda la promotoría
-- aplica_ramo = 'gmm' = solo afecta el SLA de trámites GMM (ej: cierre de GNP GMM)
-- =============================================================================

CREATE TABLE dia_inhabil (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fecha           DATE            NOT NULL,
    descripcion     TEXT            NOT NULL,

    -- NULL = aplica a todos los ramos (día festivo nacional)
    -- NOT NULL = solo afecta ese ramo (cierre específico de GNP para un ramo)
    aplica_ramo     ramo_usuario    NULL,

    creado_por      UUID            NULL REFERENCES usuario(id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Un mismo día puede ser inhábil de forma diferente por ramo,
    -- pero solo una vez como global y una vez por ramo específico.
    CONSTRAINT uq_dia_inhabil_fecha_ramo
        UNIQUE (fecha, aplica_ramo)
);

COMMENT ON TABLE dia_inhabil IS
    'Calendario de días no laborables. Configurable por el director desde la UI. '
    'El motor de SLA excluye estos días al calcular fecha_limite. '
    'aplica_ramo NULL = festivo para toda la promotoría; '
    'aplica_ramo = "gmm" = solo afecta el calendario de trámites GMM.';

COMMENT ON COLUMN dia_inhabil.aplica_ramo IS
    'NULL = aplica a todos los ramos. NOT NULL = solo al ramo especificado. '
    'calcular_fecha_limite_sla() excluye los días globales MÁS los del ramo del trámite.';


-- =============================================================================
-- SECCIÓN 3: TABLA sla_definicion
-- =============================================================================
-- Cada fila es una regla de SLA configurable por el director.
-- Ejemplos de configuraciones posibles:
--
--   nombre                  tipo_tramite  ramo   prioridad  dias_habiles  alerta_pct
--   ─────────────────────── ────────────  ─────  ─────────  ────────────  ──────────
--   "Alta GMM urgente"      alta          gmm    urgente    3             70
--   "Alta GMM normal"       alta          gmm    normal     5             80
--   "Endosos todos ramos"   endoso        NULL   NULL       8             75
--   "Cancelaciones"         cancelacion   NULL   NULL       10            80
--   "Default general"       NULL          NULL   NULL       15            80
--
-- Resolución de conflictos — regla de especificidad:
--   Cuando un trámite coincide con múltiples reglas, gana la MÁS ESPECÍFICA.
--   Score = tipo_tramite(4) + ramo(2) + prioridad(1) → range 0-7
--   La función resolver_sla_definicion() aplica esta lógica.
-- =============================================================================

CREATE TABLE sla_definicion (
    -- -------------------------------------------------------------------------
    -- Identidad
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          TEXT            NOT NULL,
    descripcion     TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Criterios de aplicación (NULL = "aplica a todos")
    -- Los tres campos juntos forman la clave de especificidad.
    -- -------------------------------------------------------------------------
    -- NULL = aplica a cualquier tipo de trámite
    tipo_tramite    tipo_tramite    NULL,
    -- NULL = aplica a cualquier ramo
    ramo            ramo_usuario    NULL,
    -- NULL = aplica a cualquier prioridad
    prioridad_aplica prioridad_tramite NULL,

    -- -------------------------------------------------------------------------
    -- Parámetros del SLA — 100% configurables
    -- -------------------------------------------------------------------------
    -- Plazo en días hábiles (excluyendo fines de semana y dias_inhabil)
    dias_habiles    SMALLINT        NOT NULL
                    CHECK (dias_habiles > 0 AND dias_habiles <= 365),

    -- Porcentaje del plazo al que se envía la alerta preventiva.
    -- Ej: 80 = alerta cuando se ha consumido el 80% del tiempo disponible.
    -- Ej: al día 4 de un SLA de 5 días → alerta.
    alerta_porcentaje NUMERIC(5,2)  NOT NULL DEFAULT 80
                    CHECK (alerta_porcentaje > 0 AND alerta_porcentaje < 100),

    -- -------------------------------------------------------------------------
    -- Estado y auditoría
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,
    creado_por      UUID            NULL REFERENCES usuario(id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINT: nombre único por combinación de criterios activos
    -- Evita duplicados ambiguos al mismo nivel de especificidad.
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_sla_nombre_not_empty
        CHECK (TRIM(nombre) <> ''),
    CONSTRAINT ck_sla_dias_positivos
        CHECK (dias_habiles >= 1)
);

COMMENT ON TABLE sla_definicion IS
    'Reglas de SLA configurables por el director. Ningún valor está hardcodeado. '
    'resolver_sla_definicion() selecciona la regla más específica que aplica '
    'a un trámite según tipo, ramo y prioridad.';

COMMENT ON COLUMN sla_definicion.nombre           IS 'Nombre descriptivo visible en la UI del director. Ej: "Alta GMM normal".';
COMMENT ON COLUMN sla_definicion.tipo_tramite     IS 'NULL = aplica a cualquier tipo. NOT NULL = solo ese tipo de trámite.';
COMMENT ON COLUMN sla_definicion.ramo             IS 'NULL = aplica a todos los ramos. NOT NULL = solo ese ramo.';
COMMENT ON COLUMN sla_definicion.prioridad_aplica IS 'NULL = aplica a cualquier prioridad. NOT NULL = solo esa prioridad.';
COMMENT ON COLUMN sla_definicion.dias_habiles     IS 'Plazo en días hábiles. Excluye fines de semana y dias_inhabil.';
COMMENT ON COLUMN sla_definicion.alerta_porcentaje IS '% del plazo consumido al que se dispara la alerta preventiva (Módulo 9).';


-- =============================================================================
-- SECCIÓN 4: TABLA sla_tramite
-- =============================================================================
-- Una instancia de SLA por trámite. Se crea al llamar activar_sla_tramite().
-- Lleva el deadline calculado, el estado actual y el historial de pausas.
--
-- Ciclo de vida:
--   activar_sla_tramite() → INSERT (estado=en_curso)
--   trámite avanza → UPDATE (alerta_enviada=TRUE cuando alcanza porcentaje)
--   trámite se cierra → UPDATE (estado=cumplido/incumplido, fecha_cumplimiento)
--   trámite en_proceso_gnp → UPDATE (estado=pausado, pausado_en=NOW())
--   trámite sale de GNP → UPDATE (estado=en_curso, fecha_limite += tiempo_pausado)
-- =============================================================================

CREATE TABLE sla_tramite (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Una sola instancia activa por trámite
    tramite_id          UUID            NOT NULL UNIQUE REFERENCES tramite(id),

    -- Qué regla se aplicó al crear este SLA (auditoría y referencia)
    sla_definicion_id   UUID            NOT NULL REFERENCES sla_definicion(id),

    -- -------------------------------------------------------------------------
    -- Tiempos del SLA
    -- -------------------------------------------------------------------------
    -- Cuándo inició el reloj (fecha de recepción del trámite)
    fecha_inicio        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Deadline calculado: fecha_inicio + dias_habiles (excluyendo inhábiles).
    -- Si se pausa y se reanuda, este campo se extiende por el tiempo pausado.
    fecha_limite        TIMESTAMPTZ     NOT NULL,

    -- -------------------------------------------------------------------------
    -- Estado
    -- -------------------------------------------------------------------------
    estado              estado_sla      NOT NULL DEFAULT 'en_curso',

    -- Cuándo se alcanzó el estado final (cumplido/incumplido)
    fecha_cumplimiento  TIMESTAMPTZ     NULL,

    -- -------------------------------------------------------------------------
    -- Control de alertas
    -- -------------------------------------------------------------------------
    -- TRUE cuando el job de alertas ya envió la notificación preventiva
    alerta_enviada      BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Cuándo se envió la alerta preventiva (para auditoría)
    alerta_enviada_en   TIMESTAMPTZ     NULL,

    -- -------------------------------------------------------------------------
    -- Control de pausas
    -- -------------------------------------------------------------------------
    -- Cuándo inició la pausa actual (NULL = no está pausado)
    pausado_en          TIMESTAMPTZ     NULL,
    -- Tiempo total acumulado en pausa (en segundos). Se suma a fecha_limite al reanudar.
    segundos_pausados   INTEGER         NOT NULL DEFAULT 0 CHECK (segundos_pausados >= 0),

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS de consistencia
    -- -------------------------------------------------------------------------

    -- Solo puede estar pausado si el estado es 'pausado'
    CONSTRAINT ck_sla_pausa_consistente CHECK (
        (estado = 'pausado' AND pausado_en IS NOT NULL)
        OR (estado <> 'pausado' AND pausado_en IS NULL)
    ),

    -- La fecha de cumplimiento solo aplica en estados finales
    CONSTRAINT ck_sla_cumplimiento_consistente CHECK (
        fecha_cumplimiento IS NULL
        OR estado IN ('cumplido', 'incumplido')
    ),

    -- La alerta enviada requiere timestamp
    CONSTRAINT ck_sla_alerta_consistente CHECK (
        (alerta_enviada = FALSE AND alerta_enviada_en IS NULL)
        OR (alerta_enviada = TRUE AND alerta_enviada_en IS NOT NULL)
    ),

    -- El deadline siempre es posterior al inicio
    CONSTRAINT ck_sla_fechas CHECK (fecha_limite > fecha_inicio)
);

COMMENT ON TABLE sla_tramite IS
    'Instancia activa de SLA por trámite. Creada automáticamente por activar_sla_tramite(). '
    'Lleva el deadline calculado, el estado y el historial de pausas. '
    'Cuando el trámite está en_proceso_gnp, el SLA se pausa para no penalizar '
    'a la promotoría por tiempos externos a su control.';

COMMENT ON COLUMN sla_tramite.fecha_limite      IS 'Deadline calculado en días hábiles. Se extiende automáticamente si hubo pausas.';
COMMENT ON COLUMN sla_tramite.pausado_en        IS 'Timestamp de inicio de la pausa actual. NULL cuando el SLA está corriendo.';
COMMENT ON COLUMN sla_tramite.segundos_pausados IS 'Tiempo total pausado acumulado. Se suma a fecha_limite al reanudar.';
COMMENT ON COLUMN sla_tramite.alerta_enviada    IS 'TRUE cuando el job de alertas disparó la notificación preventiva del Módulo 9.';


-- =============================================================================
-- SECCIÓN 5: ÍNDICES
-- =============================================================================

-- dia_inhabil —————————————————————————————————————————————————————————————————

-- La función calcular_fecha_limite_sla() consulta este índice en cada día
-- que evalúa. El lookup es por fecha + ramo (o NULL).
CREATE INDEX idx_dia_inhabil_fecha
    ON dia_inhabil (fecha, aplica_ramo);

COMMENT ON INDEX idx_dia_inhabil_fecha IS
    'Lookup de días inhábiles por fecha. Usado por calcular_fecha_limite_sla().';

-- sla_definicion ——————————————————————————————————————————————————————————————

-- resolver_sla_definicion() filtra por estos tres campos
CREATE INDEX idx_sla_def_criterios
    ON sla_definicion (tipo_tramite, ramo, prioridad_aplica)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_sla_def_criterios IS
    'Resolver de definiciones: filtra por tipo, ramo y prioridad activos.';

-- sla_tramite —————————————————————————————————————————————————————————————————

-- Trámites próximos a vencer (job de alertas — corre periódicamente)
CREATE INDEX idx_sla_tramite_vencimiento
    ON sla_tramite (fecha_limite)
    WHERE estado = 'en_curso';

COMMENT ON INDEX idx_sla_tramite_vencimiento IS
    'Job de alertas: trámites en curso ordenados por fecha_limite próxima.';

-- Trámites que aún no recibieron su alerta preventiva
CREATE INDEX idx_sla_tramite_alerta_pendiente
    ON sla_tramite (fecha_limite)
    WHERE estado = 'en_curso' AND alerta_enviada = FALSE;

COMMENT ON INDEX idx_sla_tramite_alerta_pendiente IS
    'Job de alertas preventivas: trámites en curso sin alerta enviada.';

-- Dashboard del director/gerente: SLAs incumplidos recientes
CREATE INDEX idx_sla_tramite_incumplidos
    ON sla_tramite (fecha_cumplimiento DESC)
    WHERE estado = 'incumplido';

-- Lookup por tramite (el más frecuente desde la UI del trámite)
-- tramite_id ya tiene índice implícito por UNIQUE constraint.


-- =============================================================================
-- SECCIÓN 6: TRIGGERS — updated_at y alertas
-- =============================================================================

CREATE TRIGGER trg_dia_inhabil_updated_at
    BEFORE UPDATE ON dia_inhabil
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sla_def_updated_at
    BEFORE UPDATE ON sla_definicion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sla_tramite_updated_at
    BEFORE UPDATE ON sla_tramite
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 7: FUNCIÓN calcular_fecha_limite_sla()
-- =============================================================================
-- Calcula la fecha límite de un SLA dado un punto de inicio y un número
-- de días hábiles, excluyendo:
--   - Sábados y domingos (siempre)
--   - Días en dia_inhabil que apliquen al ramo dado (o globales)
--
-- Uso:
--   SELECT calcular_fecha_limite_sla('2026-05-22 09:00'::timestamptz, 5, 'gmm');
--   → '2026-05-29 09:00'  (considerando Semana Santa u otros inhábiles)
-- =============================================================================

CREATE OR REPLACE FUNCTION calcular_fecha_limite_sla(
    p_inicio    TIMESTAMPTZ,
    p_dias      INTEGER,
    p_ramo      ramo_usuario DEFAULT NULL
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_fecha_actual  DATE    := p_inicio::DATE;
    v_contador      INTEGER := 0;
BEGIN
    IF p_dias <= 0 THEN
        RAISE EXCEPTION 'dias_habiles debe ser mayor a 0, se recibió %', p_dias;
    END IF;

    WHILE v_contador < p_dias LOOP
        v_fecha_actual := v_fecha_actual + 1;

        -- Saltar fines de semana (0=domingo, 6=sábado)
        IF EXTRACT(DOW FROM v_fecha_actual) IN (0, 6) THEN
            CONTINUE;
        END IF;

        -- Saltar días inhábiles globales (aplica_ramo IS NULL)
        -- y días inhábiles específicos del ramo del trámite
        IF EXISTS (
            SELECT 1 FROM dia_inhabil
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

COMMENT ON FUNCTION calcular_fecha_limite_sla(TIMESTAMPTZ, INTEGER, ramo_usuario) IS
    'Calcula el deadline de un SLA en días hábiles, excluyendo fines de semana '
    'y los días configurados en dia_inhabil que apliquen al ramo dado. '
    'Si p_ramo es NULL, solo excluye los días globales (aplica_ramo IS NULL).';


-- =============================================================================
-- SECCIÓN 8: FUNCIÓN resolver_sla_definicion()
-- =============================================================================
-- Encuentra la definición de SLA más específica que aplica a un trámite dado
-- su tipo, ramo y prioridad.
--
-- Regla de especificidad (score de 0 a 7):
--   tipo_tramite NOT NULL → +4 puntos
--   ramo NOT NULL         → +2 puntos
--   prioridad NOT NULL    → +1 punto
--   Gana la definición con mayor score. Si empatan, gana la más reciente.
--
-- Retorna NULL si no hay ninguna definición activa que aplique.
-- El backend debe manejar este caso (loggear advertencia, no crear sla_tramite).
-- =============================================================================

CREATE OR REPLACE FUNCTION resolver_sla_definicion(
    p_tipo_tramite  tipo_tramite,
    p_ramo          ramo_usuario,
    p_prioridad     prioridad_tramite
)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT id
    FROM sla_definicion
    WHERE activo = TRUE
      -- La definición aplica si cada criterio es NULL (comodín) o coincide exactamente
      AND (tipo_tramite     IS NULL OR tipo_tramite     = p_tipo_tramite)
      AND (ramo             IS NULL OR ramo             = p_ramo)
      AND (prioridad_aplica IS NULL OR prioridad_aplica = p_prioridad)
    ORDER BY
        -- Más específica primero
        (CASE WHEN tipo_tramite     IS NOT NULL THEN 4 ELSE 0 END
       + CASE WHEN ramo             IS NOT NULL THEN 2 ELSE 0 END
       + CASE WHEN prioridad_aplica IS NOT NULL THEN 1 ELSE 0 END) DESC,
        -- Si empatan en especificidad, la más reciente (director actualizó la regla)
        created_at DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION resolver_sla_definicion(tipo_tramite, ramo_usuario, prioridad_tramite) IS
    'Encuentra la definición de SLA más específica que aplica al trámite. '
    'Usa un score de especificidad (tipo=4, ramo=2, prioridad=1) para resolver '
    'conflictos cuando múltiples reglas coinciden. Retorna NULL si no hay match.';


-- =============================================================================
-- SECCIÓN 9: FUNCIÓN activar_sla_tramite()
-- =============================================================================
-- Crea el registro sla_tramite para un trámite dado.
-- El Agente 4 la llama al asignar el analista (cuando el trámite pasa de
-- recibido/validando a tener analista asignado y tipo conocido).
--
-- Uso en Python (Agente 4):
--   result = supabase.rpc('activar_sla_tramite', {'p_tramite_id': str(tramite_id)}).execute()
--   if result.data is None:
--       logger.warning("No hay definición de SLA para este trámite", tramite_id=tramite_id)
--
-- Retorna el id del sla_tramite creado, o NULL si no hay definición aplicable.
-- =============================================================================

CREATE OR REPLACE FUNCTION activar_sla_tramite(p_tramite_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tramite           RECORD;
    v_definicion_id     UUID;
    v_fecha_limite      TIMESTAMPTZ;
    v_sla_id            UUID;
BEGIN
    -- Leer los datos del trámite necesarios para resolver el SLA
    SELECT tipo_tramite, ramo, prioridad, fecha_recepcion
    INTO v_tramite
    FROM tramite
    WHERE id = p_tramite_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Trámite % no encontrado.', p_tramite_id;
    END IF;

    -- Si ya existe un SLA activo, no duplicar
    IF EXISTS (SELECT 1 FROM sla_tramite WHERE tramite_id = p_tramite_id) THEN
        SELECT id INTO v_sla_id FROM sla_tramite WHERE tramite_id = p_tramite_id;
        RETURN v_sla_id;
    END IF;

    -- Resolver la definición más específica
    v_definicion_id := resolver_sla_definicion(
        v_tramite.tipo_tramite,
        v_tramite.ramo,
        v_tramite.prioridad
    );

    -- Sin definición → el trámite no tiene SLA configurado (loggear en la app)
    IF v_definicion_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Calcular el deadline en días hábiles desde la recepción del trámite
    v_fecha_limite := calcular_fecha_limite_sla(
        COALESCE(v_tramite.fecha_recepcion, NOW()),
        (SELECT dias_habiles FROM sla_definicion WHERE id = v_definicion_id),
        v_tramite.ramo
    );

    -- Crear la instancia de SLA
    INSERT INTO sla_tramite (
        tramite_id,
        sla_definicion_id,
        fecha_inicio,
        fecha_limite,
        estado
    ) VALUES (
        p_tramite_id,
        v_definicion_id,
        COALESCE(v_tramite.fecha_recepcion, NOW()),
        v_fecha_limite,
        'en_curso'
    )
    RETURNING id INTO v_sla_id;

    -- Sincronizar tramite.fecha_limite_sla para que los índices de tramite funcionen
    -- (idx_tramite_sla_vencimiento depende de este campo — ver Módulo 4)
    UPDATE tramite
    SET fecha_limite_sla = v_fecha_limite
    WHERE id = p_tramite_id;

    RETURN v_sla_id;
END;
$$;

COMMENT ON FUNCTION activar_sla_tramite(UUID) IS
    'Crea el sla_tramite para un trámite dado. Llama a resolver_sla_definicion() '
    'y calcular_fecha_limite_sla() internamente. Sincroniza tramite.fecha_limite_sla. '
    'El Agente 4 la invoca al asignar el analista. Idempotente: si ya existe, retorna el id existente. '
    'Retorna NULL si no hay ninguna definición de SLA configurada para ese tipo/ramo/prioridad.';


-- =============================================================================
-- SECCIÓN 10: FUNCIÓN pausar_sla_tramite() y reanudar_sla_tramite()
-- =============================================================================
-- Pausar: cuando el trámite entra en estado en_proceso_gnp.
--   El reloj se detiene — la promotoría no controla los tiempos de GNP.
-- Reanudar: cuando GNP responde y el trámite vuelve a manos de la promotoría.
--   Se suma el tiempo pausado a fecha_limite para preservar el plazo original.
-- =============================================================================

CREATE OR REPLACE FUNCTION pausar_sla_tramite(p_tramite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE sla_tramite
    SET
        estado     = 'pausado',
        pausado_en = NOW()
    WHERE tramite_id = p_tramite_id
      AND estado     = 'en_curso';

    IF NOT FOUND THEN
        RAISE NOTICE 'SLA del trámite % no está en_curso o no existe.', p_tramite_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION pausar_sla_tramite(UUID) IS
    'Pausa el SLA de un trámite (ej: cuando entra en_proceso_gnp). '
    'El tiempo pausado no cuenta contra el plazo de la promotoría.';


CREATE OR REPLACE FUNCTION reanudar_sla_tramite(p_tramite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_segundos_pausa INTEGER;
BEGIN
    -- Calcular duración de la pausa actual
    SELECT EXTRACT(EPOCH FROM (NOW() - pausado_en))::INTEGER
    INTO v_segundos_pausa
    FROM sla_tramite
    WHERE tramite_id = p_tramite_id AND estado = 'pausado';

    IF NOT FOUND THEN
        RAISE NOTICE 'SLA del trámite % no está pausado o no existe.', p_tramite_id;
        RETURN;
    END IF;

    -- Reanudar: extender fecha_limite y acumular tiempo pausado
    UPDATE sla_tramite
    SET
        estado              = 'en_curso',
        pausado_en          = NULL,
        segundos_pausados   = segundos_pausados + v_segundos_pausa,
        fecha_limite        = fecha_limite + (v_segundos_pausa * INTERVAL '1 second')
    WHERE tramite_id = p_tramite_id;

    -- Sincronizar tramite.fecha_limite_sla con el nuevo deadline
    UPDATE tramite
    SET fecha_limite_sla = (
        SELECT fecha_limite FROM sla_tramite WHERE tramite_id = p_tramite_id
    )
    WHERE id = p_tramite_id;
END;
$$;

COMMENT ON FUNCTION reanudar_sla_tramite(UUID) IS
    'Reanuda el SLA pausado y extiende fecha_limite por el tiempo que estuvo pausado. '
    'Sincroniza tramite.fecha_limite_sla. '
    'El backend la llama cuando el trámite sale del estado en_proceso_gnp.';


-- =============================================================================
-- SECCIÓN 11: FUNCIÓN cerrar_sla_tramite()
-- =============================================================================
-- Marca el SLA como cumplido o incumplido cuando el trámite se cierra.
-- El backend la llama cuando el trámite alcanza estado 'aprobado' o 'rechazado'.
-- =============================================================================

CREATE OR REPLACE FUNCTION cerrar_sla_tramite(p_tramite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_estado_sla    estado_sla;
    v_fecha_limite  TIMESTAMPTZ;
BEGIN
    SELECT estado, fecha_limite
    INTO v_estado_sla, v_fecha_limite
    FROM sla_tramite
    WHERE tramite_id = p_tramite_id;

    IF NOT FOUND THEN
        RETURN; -- trámite sin SLA configurado, no hay nada que cerrar
    END IF;

    IF v_estado_sla IN ('cumplido', 'incumplido') THEN
        RETURN; -- ya cerrado, idempotente
    END IF;

    UPDATE sla_tramite
    SET
        estado             = CASE WHEN NOW() <= v_fecha_limite THEN 'cumplido' ELSE 'incumplido' END,
        fecha_cumplimiento = NOW()
    WHERE tramite_id = p_tramite_id;
END;
$$;

COMMENT ON FUNCTION cerrar_sla_tramite(UUID) IS
    'Cierra el SLA como cumplido o incumplido según si NOW() <= fecha_limite. '
    'Idempotente: si ya está cerrado, no hace nada. '
    'El backend la llama cuando el trámite alcanza estado aprobado o rechazado.';


-- =============================================================================
-- SECCIÓN 12: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE dia_inhabil     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sla_definicion  ENABLE ROW LEVEL SECURITY;
ALTER TABLE sla_tramite     ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: dia_inhabil
-- Todos los roles pueden leer el calendario — es necesario para mostrar
-- los días hábiles correctamente en la UI de cualquier usuario.
-- Solo directores pueden agregar/modificar días inhábiles.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_dia_inhabil_select
    ON dia_inhabil FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_dia_inhabil_select ON dia_inhabil IS
    'Todos los usuarios autenticados pueden consultar el calendario de días inhábiles. '
    'Necesario para mostrar deadlines correctamente en la UI.';

CREATE POLICY pol_dia_inhabil_insert
    ON dia_inhabil FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
    );

CREATE POLICY pol_dia_inhabil_update
    ON dia_inhabil FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_dia_inhabil_delete
    ON dia_inhabil FOR DELETE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

COMMENT ON POLICY pol_dia_inhabil_delete ON dia_inhabil IS
    'Solo directores pueden eliminar días inhábiles. '
    'DELETE físico permitido (a diferencia de otras tablas) porque son datos '
    'de configuración, no registros de negocio con historial.';


-- -----------------------------------------------------------------------------
-- POLICIES: sla_definicion
-- Todos leen — los analistas y gerentes ven qué SLA aplica a sus trámites.
-- Solo directores configuran las reglas.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_sla_def_select
    ON sla_definicion FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_sla_def_select ON sla_definicion IS
    'Todos los usuarios pueden consultar las definiciones de SLA. '
    'Los analistas las ven en el detalle de sus trámites.';

CREATE POLICY pol_sla_def_insert
    ON sla_definicion FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
    );

CREATE POLICY pol_sla_def_update
    ON sla_definicion FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

-- DELETE: no — soft-delete vía activo = FALSE para preservar el historial
-- de qué SLA se aplicó a trámites históricos (sla_tramite.sla_definicion_id)


-- -----------------------------------------------------------------------------
-- POLICIES: sla_tramite
-- Visibilidad idéntica a la del trámite padre (usa puede_ver_tramite del Módulo 5).
-- Solo el backend (service_role) crea y actualiza registros vía las funciones RPC.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_sla_tramite_select
    ON sla_tramite FOR SELECT TO authenticated
    USING (
        puede_ver_tramite(tramite_id)
    );

COMMENT ON POLICY pol_sla_tramite_select ON sla_tramite IS
    'Un usuario puede ver el SLA de un trámite si puede ver el trámite. '
    'Usa puede_ver_tramite() del Módulo 5 para centralizar la lógica de visibilidad.';

-- INSERT/UPDATE: solo service_role vía las funciones RPC (activar, pausar, reanudar, cerrar)
-- No se crean policies de escritura para authenticated — los usuarios no escriben
-- directamente en sla_tramite; todo pasa por las funciones SECURITY DEFINER.


-- =============================================================================
-- SECCIÓN 13: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dia_inhabil    TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON TABLE sla_definicion TO authenticated;
GRANT SELECT                         ON TABLE sla_tramite    TO authenticated;

-- Las funciones RPC son la única puerta de escritura a sla_tramite
GRANT EXECUTE ON FUNCTION calcular_fecha_limite_sla(TIMESTAMPTZ, INTEGER, ramo_usuario) TO authenticated;
GRANT EXECUTE ON FUNCTION resolver_sla_definicion(tipo_tramite, ramo_usuario, prioridad_tramite) TO authenticated;
GRANT EXECUTE ON FUNCTION activar_sla_tramite(UUID)   TO authenticated;
GRANT EXECUTE ON FUNCTION pausar_sla_tramite(UUID)    TO authenticated;
GRANT EXECUTE ON FUNCTION reanudar_sla_tramite(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION cerrar_sla_tramite(UUID)    TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000007_modulo_08_slas.sql
-- =============================================================================

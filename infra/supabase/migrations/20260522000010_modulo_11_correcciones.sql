-- =============================================================================
-- Migración: 20260522000010_modulo_11_correcciones.sql
-- Módulo 11 — Correcciones y adiciones post-diagnóstico
-- =============================================================================
-- Esta migración corrige 4 hallazgos identificados en la auditoría del modelo
-- de datos contra el ERD de referencia. No modifica migraciones anteriores.
--
-- HALLAZGO #1 — BLOQUEANTE:
--   Faltaba tabla ot_activacion para el ciclo GNP completo. El estado
--   'activado' del trámite puede repetirse (endosos con múltiples activaciones).
--   tramite.folio_ot solo guarda la última OT; esta tabla guarda el historial.
--
-- HALLAZGO #2 — DISEÑO:
--   agente↔asistente modelado como one-to-many. En la realidad un asistente
--   puede trabajar para múltiples agentes de la misma familia/sociedad.
--   Se agrega tabla junction agente_asistente (many-to-many) y se puebla
--   con los vínculos existentes. asistente.agente_id queda como "agente principal".
--
-- HALLAZGO #3 — DISEÑO:
--   asistente solo tenía telefono TEXT NULL (un campo plano). Se agrega
--   tabla asistente_telefono con la misma estructura que agente_telefono.
--
-- HALLAZGO #4 — DISEÑO:
--   sla_definicion siempre iniciaba el SLA en fecha_recepcion. Se agregan
--   estado_inicio y estado_fin para soportar SLAs multi-estado (ej: tiempo
--   de respuesta de GNP desde turnado_gnp hasta en_proceso_gnp).
--
-- ADICIÓN:
--   Función resolver_agente_desde_email() — usada por el Agente 4 en la
--   cascada CUA. Busca el agente asociado a cualquier email de agente o
--   asistente y detecta ambigüedad cuando el asistente tiene múltiples agentes.
--
--   Valor 'activacion_gnp' al enum tipo_notificacion — el pipeline lo necesita
--   para notificar al analista cuando GNP activa una póliza.
--
-- Relaciones con módulos anteriores:
--   ot_activacion.tramite_id     → tramite.id     (Módulo 4)
--   ot_activacion.registrado_por → usuario.id     (Módulo 1)
--   agente_asistente.agente_id   → agente.id      (Módulo 2)
--   agente_asistente.asistente_id → asistente.id  (Módulo 2)
--   asistente_telefono.asistente_id → asistente.id (Módulo 2)
--   sla_definicion               → ya existe       (Módulo 8)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: ENUM — Agregar 'activacion_gnp' a tipo_notificacion
-- =============================================================================
-- El pipeline de Agente 5/backend necesita notificar al analista cuando
-- GNP activa una póliza. Este valor faltaba en el enum original.
-- IF NOT EXISTS previene error si se re-ejecuta la migración.
-- =============================================================================

ALTER TYPE tipo_notificacion ADD VALUE IF NOT EXISTS 'activacion_gnp';

COMMENT ON TYPE tipo_notificacion IS
    'Catálogo de eventos que generan notificaciones en Olimpo CRM. '
    'Incluye activacion_gnp para notificar cuando GNP activa una póliza (Módulo 11).';


-- =============================================================================
-- SECCIÓN 2: TABLA ot_activacion
-- =============================================================================
-- Historial de Órdenes de Trabajo (OT) de GNP por trámite.
-- Un trámite puede tener MÚLTIPLES activaciones — especialmente endosos que
-- pueden ser activados parcialmente, rechazados por GNP y re-procesados.
--
-- Diferencia con tramite.folio_ot:
--   tramite.folio_ot      → la OT más reciente/principal (campo de acceso rápido)
--   ot_activacion         → historial completo de todas las OTs del trámite
--
-- Flujo típico con múltiples activaciones (endoso de póliza pyme):
--   1. Trámite turnado a GNP → OT-001 generada
--   2. GNP activa parcialmente → INSERT ot_activacion(OT-001, motivo='parcial')
--   3. Analista complementa documentos → trámite vuelve a completo
--   4. GNP activa definitivamente → INSERT ot_activacion(OT-001, resuelta=TRUE)
-- =============================================================================

CREATE TABLE ot_activacion (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Trámite al que pertenece esta activación
    -- -------------------------------------------------------------------------
    tramite_id          UUID            NOT NULL REFERENCES tramite(id),

    -- -------------------------------------------------------------------------
    -- Datos de la OT de GNP
    -- -------------------------------------------------------------------------
    -- Número de OT asignado por GNP (puede repetirse si GNP reutiliza el número)
    numero_ot           TEXT            NOT NULL,
    -- Descripción de por qué se generó esta activación
    -- Ej: "Alta nueva", "Endoso ampliación de suma", "Corrección de vigencia"
    motivo              TEXT            NULL,
    -- Fecha en que GNP registró la activación en sus sistemas
    fecha_activacion    DATE            NOT NULL DEFAULT CURRENT_DATE,

    -- -------------------------------------------------------------------------
    -- Resolución de la activación
    -- -------------------------------------------------------------------------
    -- Fecha en que GNP cerró esta activación (aprobó o rechazó)
    fecha_resolucion    DATE            NULL,
    -- TRUE cuando GNP cerró la activación definitivamente
    resuelta            BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Resultado final de GNP para esta activación
    resultado           TEXT            NULL
                        CHECK (resultado IS NULL
                            OR resultado IN ('aprobado', 'rechazado', 'pendiente')),

    -- -------------------------------------------------------------------------
    -- Notas y contexto del analista
    -- -------------------------------------------------------------------------
    notas               TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Actor que registró esta activación en el CRM
    -- -------------------------------------------------------------------------
    registrado_por      UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Fecha de resolución solo si está resuelta
    CONSTRAINT ck_ot_resolucion_consistente CHECK (
        fecha_resolucion IS NULL OR resuelta = TRUE
    ),

    -- Resultado solo si está resuelta
    CONSTRAINT ck_ot_resultado_consistente CHECK (
        resultado IS NULL OR resuelta = TRUE
    ),

    -- La fecha de resolución no puede ser anterior a la activación
    CONSTRAINT ck_ot_fechas CHECK (
        fecha_resolucion IS NULL OR fecha_resolucion >= fecha_activacion
    ),

    CONSTRAINT ck_ot_numero_not_empty CHECK (TRIM(numero_ot) <> '')
);

COMMENT ON TABLE ot_activacion IS
    'Historial completo de Órdenes de Trabajo de GNP por trámite. '
    'Un trámite puede tener múltiples activaciones (especialmente endosos). '
    'tramite.folio_ot guarda la OT principal para acceso rápido; '
    'esta tabla guarda el detalle y la historia de cada interacción con GNP.';

COMMENT ON COLUMN ot_activacion.tramite_id       IS 'Trámite al que pertenece esta OT. Un trámite puede tener múltiples OTs.';
COMMENT ON COLUMN ot_activacion.numero_ot        IS 'Número de OT asignado por GNP. Registrado por el analista al recibirlo.';
COMMENT ON COLUMN ot_activacion.fecha_activacion IS 'Fecha en que GNP generó o activó la OT en sus sistemas internos.';
COMMENT ON COLUMN ot_activacion.resuelta         IS 'TRUE cuando GNP cerró esta OT (aprobó o rechazó). FALSE mientras está en proceso.';
COMMENT ON COLUMN ot_activacion.resultado        IS 'Resultado final: aprobado | rechazado | pendiente. NULL hasta que GNP resuelva.';
COMMENT ON COLUMN ot_activacion.registrado_por   IS 'Usuario del CRM que capturó esta activación. NULL si fue registrado por service_role.';


-- =============================================================================
-- SECCIÓN 3: TABLA agente_asistente — junction many-to-many
-- =============================================================================
-- Un asistente puede trabajar para múltiples agentes (ej: familia de agentes,
-- despacho con varios agentes GNP). Esto es común en promotorías mexicanas.
--
-- Relación con asistente.agente_id existente:
--   asistente.agente_id = el agente PRINCIPAL (usado por defecto en el Agente 4)
--   agente_asistente    = TODOS los agentes para los que trabaja el asistente
--
-- Uso por el Agente 4 (cascada CUA):
--   Si resolver_agente_desde_email() detecta que un asistente tiene múltiples
--   agentes activos en esta tabla (ambiguo=TRUE), el trámite se crea con
--   requiere_atencion=TRUE para que un humano seleccione el agente correcto.
--
-- Al crear esta migración, se puebla automáticamente con las relaciones
-- ya existentes (asistente.agente_id → agente_asistente).
-- =============================================================================

CREATE TABLE agente_asistente (
    -- -------------------------------------------------------------------------
    -- Clave primaria compuesta — un par (agente, asistente) es único
    -- -------------------------------------------------------------------------
    agente_id       UUID        NOT NULL REFERENCES agente(id),
    asistente_id    UUID        NOT NULL REFERENCES asistente(id),

    -- -------------------------------------------------------------------------
    -- Estado del vínculo — soft-delete para preservar historial
    -- -------------------------------------------------------------------------
    -- FALSE cuando el asistente deja de trabajar para este agente específico
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (agente_id, asistente_id)
);

COMMENT ON TABLE agente_asistente IS
    'Junction many-to-many: un asistente puede trabajar para múltiples agentes. '
    'El Agente 4 detecta ambigüedad cuando hay > 1 agente activo para el mismo asistente '
    'y marca el trámite con requiere_atencion = TRUE. '
    'asistente.agente_id sigue siendo el agente principal para resolución por defecto.';

COMMENT ON COLUMN agente_asistente.agente_id    IS 'Agente para el que trabaja el asistente.';
COMMENT ON COLUMN agente_asistente.asistente_id IS 'Asistente que trabaja para el agente.';
COMMENT ON COLUMN agente_asistente.activo       IS 'FALSE cuando el asistente deja de representar a este agente. El registro se preserva.';

-- Poblar con los vínculos ya existentes (migración no destructiva)
INSERT INTO agente_asistente (agente_id, asistente_id, activo)
SELECT agente_id, id, TRUE
FROM asistente
ON CONFLICT (agente_id, asistente_id) DO NOTHING;

COMMENT ON INDEX agente_asistente_pkey IS
    'Un par (agente, asistente) es único. Previene vínculos duplicados.';


-- =============================================================================
-- SECCIÓN 4: TABLA asistente_telefono
-- =============================================================================
-- Múltiples teléfonos por asistente. Misma estructura que agente_telefono.
-- El campo asistente.telefono (TEXT NULL) queda como teléfono legacy/simple
-- para compatibilidad. Los nuevos registros deben usar esta tabla.
-- =============================================================================

CREATE TABLE asistente_telefono (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    asistente_id    UUID            NOT NULL REFERENCES asistente(id) ON DELETE CASCADE,
    tipo            tipo_telefono   NOT NULL DEFAULT 'celular',
    numero          TEXT            NOT NULL,
    -- Solo un teléfono preferente por asistente (enforced por índice único parcial)
    preferente      BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_asistente_tel_numero CHECK (TRIM(numero) <> '')
);

COMMENT ON TABLE asistente_telefono IS
    'Teléfonos del asistente. Un asistente puede tener varios; '
    'el campo preferente identifica el número principal. '
    'Misma estructura que agente_telefono para consistencia del modelo.';

COMMENT ON COLUMN asistente_telefono.tipo       IS 'Tipo de teléfono: celular, oficina, casa, whatsapp, otro.';
COMMENT ON COLUMN asistente_telefono.preferente IS 'Solo un teléfono por asistente puede ser preferente (enforced por índice único parcial).';


-- =============================================================================
-- SECCIÓN 5: ALTER TABLE sla_definicion — agregar estado_inicio y estado_fin
-- =============================================================================
-- Permite definir SLAs que corran entre estados específicos del trámite.
--
-- Casos de uso:
--   NULL / NULL     → SLA de la promotoría: desde recepción hasta aprobado/rechazado
--   turnado_gnp / en_proceso_gnp → SLA de respuesta de GNP
--   completo / turnado_gnp       → SLA de "tiempo de turno al portal GNP"
--
-- La función activar_sla_tramite() debe leer estado_inicio para determinar
-- el punto de inicio correcto del SLA (se actualiza en el backend, no en DB).
-- =============================================================================

ALTER TABLE sla_definicion
    ADD COLUMN IF NOT EXISTS estado_inicio  estado_tramite  NULL,
    ADD COLUMN IF NOT EXISTS estado_fin     estado_tramite  NULL;

COMMENT ON COLUMN sla_definicion.estado_inicio IS
    'Estado del trámite en que inicia el conteo del SLA. '
    'NULL = inicia desde la recepción del trámite (comportamiento por defecto). '
    'Ejemplo: turnado_gnp para medir el tiempo de respuesta de GNP.';

COMMENT ON COLUMN sla_definicion.estado_fin IS
    'Estado del trámite en que termina el conteo del SLA. '
    'NULL = termina en aprobado o rechazado (comportamiento por defecto). '
    'Ejemplo: en_proceso_gnp para medir solo el tiempo de acuse de GNP.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- ot_activacion ————————————————————————————————————————————————————————————————

-- Timeline de OTs de un trámite (el más frecuente desde la UI)
CREATE INDEX idx_ot_tramite
    ON ot_activacion (tramite_id, fecha_activacion DESC);

COMMENT ON INDEX idx_ot_tramite IS
    'Historial de OTs de un trámite ordenado por fecha. Query principal desde el panel del trámite.';

-- OTs pendientes de resolución (dashboard de seguimiento GNP)
CREATE INDEX idx_ot_pendientes
    ON ot_activacion (fecha_activacion DESC)
    WHERE resuelta = FALSE;

COMMENT ON INDEX idx_ot_pendientes IS
    'OTs que GNP aún no ha resuelto. Dashboard de seguimiento de trámites en GNP.';

-- Búsqueda por número de OT (cuando GNP notifica por email o teléfono)
CREATE INDEX idx_ot_numero
    ON ot_activacion (numero_ot);

-- agente_asistente ————————————————————————————————————————————————————————————

-- Buscar todos los agentes de un asistente (Agente 4: ¿para quién trabaja este email?)
CREATE INDEX idx_agente_asistente_asistente
    ON agente_asistente (asistente_id)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_agente_asistente_asistente IS
    'Agentes activos de un asistente. El Agente 4 usa este índice para detectar ambigüedad '
    '(cuando un asistente trabaja para > 1 agente activo).';

-- Buscar todos los asistentes de un agente (UI: ficha del agente)
CREATE INDEX idx_agente_asistente_agente
    ON agente_asistente (agente_id)
    WHERE activo = TRUE;

-- asistente_telefono ——————————————————————————————————————————————————————————

CREATE INDEX idx_asistente_tel_asistente
    ON asistente_telefono (asistente_id);

-- Solo UN teléfono preferente por asistente — índice único parcial
CREATE UNIQUE INDEX uq_asistente_telefono_preferente
    ON asistente_telefono (asistente_id)
    WHERE preferente = TRUE;

COMMENT ON INDEX uq_asistente_telefono_preferente IS
    'Garantiza que cada asistente tenga máximo un teléfono marcado como preferente.';


-- =============================================================================
-- SECCIÓN 7: TRIGGERS
-- =============================================================================

-- updated_at
CREATE TRIGGER trg_ot_activacion_updated_at
    BEFORE UPDATE ON ot_activacion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Auditoría — audit_table_change() ya existe desde módulo 10
CREATE TRIGGER trg_ot_activacion_audit
    AFTER INSERT OR UPDATE OR DELETE ON ot_activacion
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_ot_activacion_audit ON ot_activacion IS
    'Audita todo cambio en OTs de GNP. Permite responder: '
    '"¿Quién marcó esta OT como resuelta y cuándo?"';

CREATE TRIGGER trg_agente_asistente_audit
    AFTER INSERT OR UPDATE OR DELETE ON agente_asistente
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_agente_asistente_audit ON agente_asistente IS
    'Audita cambios en vínculos agente↔asistente. '
    'Permite rastrear cuándo un asistente empezó o dejó de representar a un agente.';


-- =============================================================================
-- SECCIÓN 8: FUNCIÓN registrar_activacion_gnp()
-- =============================================================================
-- Función RPC que el analista llama desde la UI cuando GNP activa una póliza.
-- También puede ser llamada por el backend cuando el Agente captura una activación.
--
-- Efectos secundarios:
--   1. Inserta el registro en ot_activacion
--   2. Actualiza tramite.folio_ot con el número de OT (si es la primera o si se
--      pasa force_update=TRUE)
--   3. Crea notificación 'activacion_gnp' si hay analista asignado
--
-- Uso en Python (Agente o backend):
--   supabase.rpc('registrar_activacion_gnp', {
--       'p_tramite_id': str(tramite_id),
--       'p_numero_ot': 'OT-2026-00123',
--       'p_motivo': 'Alta de póliza GMM',
--       'p_fecha_activacion': '2026-05-23',
--       'p_force_update_folio': False
--   }).execute()
-- =============================================================================

CREATE OR REPLACE FUNCTION registrar_activacion_gnp(
    p_tramite_id            UUID,
    p_numero_ot             TEXT,
    p_motivo                TEXT        DEFAULT NULL,
    p_fecha_activacion      DATE        DEFAULT CURRENT_DATE,
    p_notas                 TEXT        DEFAULT NULL,
    p_force_update_folio    BOOLEAN     DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ot_id         UUID;
    v_analista_id   UUID;
    v_folio         TEXT;
BEGIN
    IF TRIM(p_numero_ot) = '' THEN
        RAISE EXCEPTION 'El número de OT no puede estar vacío.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tramite WHERE id = p_tramite_id) THEN
        RAISE EXCEPTION 'Trámite % no encontrado.', p_tramite_id;
    END IF;

    -- Insertar la activación
    INSERT INTO ot_activacion (
        tramite_id,
        numero_ot,
        motivo,
        fecha_activacion,
        notas,
        registrado_por
    ) VALUES (
        p_tramite_id,
        TRIM(p_numero_ot),
        p_motivo,
        p_fecha_activacion,
        p_notas,
        auth.uid()
    )
    RETURNING id INTO v_ot_id;

    -- Actualizar tramite.folio_ot si es la primera OT o si se fuerza
    SELECT folio_ot, analista_id INTO v_folio, v_analista_id
    FROM tramite WHERE id = p_tramite_id;

    IF v_folio IS NULL OR p_force_update_folio THEN
        UPDATE tramite
        SET folio_ot = TRIM(p_numero_ot)
        WHERE id = p_tramite_id;
    END IF;

    -- Notificar al analista asignado (si existe)
    IF v_analista_id IS NOT NULL THEN
        PERFORM crear_notificacion(
            v_analista_id,
            'activacion_gnp',
            'GNP activó una póliza',
            'La OT ' || TRIM(p_numero_ot) || ' fue activada por GNP.' ||
                COALESCE(' Motivo: ' || p_motivo, ''),
            p_tramite_id,
            jsonb_build_object('numero_ot', TRIM(p_numero_ot), 'ot_activacion_id', v_ot_id)
        );
    END IF;

    RETURN v_ot_id;
END;
$$;

COMMENT ON FUNCTION registrar_activacion_gnp(UUID, TEXT, TEXT, DATE, TEXT, BOOLEAN) IS
    'Registra una activación de GNP para un trámite. '
    'Inserta en ot_activacion, actualiza tramite.folio_ot si es la primera OT, '
    'y envía notificación activacion_gnp al analista asignado. '
    'Idempotente respecto a ot_activacion (no impide duplicados intencionales de GNP).';


-- =============================================================================
-- SECCIÓN 9: FUNCIÓN resolver_agente_desde_email()
-- =============================================================================
-- Función crítica para el Agente 4 durante la cascada CUA.
-- Dado un email, encuentra el agente asociado buscando en:
--   1. agente_email     → email de agente directo (más confiable)
--   2. asistente.email  → email de asistente → retorna su agente principal
--      + verifica ambigüedad en agente_asistente (múltiples agentes activos)
--
-- Retorna NULL si el email no pertenece a ningún agente ni asistente conocido.
-- El Agente 4 maneja el NULL marcando requiere_atencion = TRUE en el trámite.
--
-- Uso en Python (Agente 4):
--   result = supabase.rpc('resolver_agente_desde_email', {
--       'p_email': remitente_email
--   }).execute()
--   if result.data is None:
--       # email desconocido — marcar requiere_atencion
--   elif result.data['ambiguo']:
--       # asistente con múltiples agentes — marcar requiere_atencion
--   else:
--       agente_id = result.data['agente_id']
--       via       = result.data['via']  # 'agente_directo' o 'asistente'
-- =============================================================================

CREATE TYPE resolucion_email_agente AS (
    agente_id       UUID,
    via             TEXT,       -- 'agente_directo' | 'asistente'
    asistente_id    UUID,       -- NULL cuando via = 'agente_directo'
    ambiguo         BOOLEAN     -- TRUE si el asistente tiene > 1 agente activo
);

CREATE OR REPLACE FUNCTION resolver_agente_desde_email(p_email TEXT)
RETURNS resolucion_email_agente
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_resultado     resolucion_email_agente;
    v_agente_id     UUID;
    v_asistente_id  UUID;
    v_agente_ppal   UUID;
    v_count_agentes INTEGER;
BEGIN
    -- Paso 1: buscar en agente_email (el agente envió el correo directamente)
    SELECT ae.agente_id INTO v_agente_id
    FROM agente_email ae
    JOIN agente a ON a.id = ae.agente_id AND a.activo = TRUE
    WHERE ae.email = LOWER(TRIM(p_email))
    LIMIT 1;

    IF v_agente_id IS NOT NULL THEN
        v_resultado.agente_id    := v_agente_id;
        v_resultado.via          := 'agente_directo';
        v_resultado.asistente_id := NULL;
        v_resultado.ambiguo      := FALSE;
        RETURN v_resultado;
    END IF;

    -- Paso 2: buscar en asistente (el asistente envió el correo)
    SELECT id, agente_id INTO v_asistente_id, v_agente_ppal
    FROM asistente
    WHERE email = LOWER(TRIM(p_email))
      AND activo = TRUE
    LIMIT 1;

    IF v_asistente_id IS NULL THEN
        RETURN NULL;  -- email desconocido en el sistema
    END IF;

    -- Verificar cuántos agentes activos tiene este asistente en la junction
    SELECT COUNT(*) INTO v_count_agentes
    FROM agente_asistente aa
    JOIN agente a ON a.id = aa.agente_id AND a.activo = TRUE
    WHERE aa.asistente_id = v_asistente_id
      AND aa.activo = TRUE;

    v_resultado.agente_id    := v_agente_ppal;      -- agente principal por defecto
    v_resultado.via          := 'asistente';
    v_resultado.asistente_id := v_asistente_id;
    -- ambiguo = TRUE cuando hay más de 1 agente activo y el Agente 4 no puede
    -- determinar automáticamente a cuál de ellos pertenece este trámite
    v_resultado.ambiguo      := (v_count_agentes > 1);

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION resolver_agente_desde_email(TEXT) IS
    'Resuelve el agente asociado a un email entrante. '
    'Paso 1: busca en agente_email (agente directo). '
    'Paso 2: busca en asistente → retorna agente principal. '
    'Si el asistente tiene > 1 agente activo, ambiguo=TRUE → el Agente 4 '
    'debe marcar requiere_atencion=TRUE para resolución manual. '
    'Retorna NULL si el email no está registrado en el CRM.';

COMMENT ON TYPE resolucion_email_agente IS
    'Resultado de resolver_agente_desde_email(). '
    'agente_id: UUID del agente identificado. '
    'via: como se identificó (agente_directo | asistente). '
    'asistente_id: UUID del asistente cuando via=asistente. '
    'ambiguo: TRUE cuando el asistente trabaja para múltiples agentes — requiere decisión humana.';


-- =============================================================================
-- SECCIÓN 10: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE ot_activacion       ENABLE ROW LEVEL SECURITY;
ALTER TABLE agente_asistente    ENABLE ROW LEVEL SECURITY;
ALTER TABLE asistente_telefono  ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: ot_activacion
-- Visibilidad idéntica al trámite padre (usa puede_ver_tramite del Módulo 5).
-- Escritura: analistas sobre sus trámites, gerentes y directores sobre los suyos.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_ot_select
    ON ot_activacion FOR SELECT TO authenticated
    USING (
        puede_ver_tramite(tramite_id)
    );

COMMENT ON POLICY pol_ot_select ON ot_activacion IS
    'Un usuario puede ver las OTs de un trámite si puede ver el trámite. '
    'Usa puede_ver_tramite() del Módulo 5 para centralizar la lógica de visibilidad.';

CREATE POLICY pol_ot_insert
    ON ot_activacion FOR INSERT TO authenticated
    WITH CHECK (
        puede_ver_tramite(tramite_id)
        AND auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

COMMENT ON POLICY pol_ot_insert ON ot_activacion IS
    'Cualquier usuario que puede ver el trámite puede registrar una activación de GNP.';

CREATE POLICY pol_ot_update
    ON ot_activacion FOR UPDATE TO authenticated
    USING (
        puede_ver_tramite(tramite_id)
        AND auth_rol() IN ('director_general', 'director_ops', 'gerente')
    )
    WITH CHECK (
        puede_ver_tramite(tramite_id)
        AND auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

COMMENT ON POLICY pol_ot_update ON ot_activacion IS
    'Solo directores y gerentes pueden modificar el resultado de una OT. '
    'Los analistas pueden registrar pero no corregir OTs (evita manipulación de resultados).';

-- DELETE: nadie — las OTs son registros históricos de GNP, nunca se borran


-- -----------------------------------------------------------------------------
-- POLICIES: agente_asistente
-- Misma estrategia que agente: todos leen, directores y gerentes gestionan.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_agente_asistente_select
    ON agente_asistente FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_agente_asistente_select ON agente_asistente IS
    'Todos los usuarios autenticados pueden ver los vínculos agente↔asistente. '
    'Necesario para que el Agente 4 resuelva la cascada CUA.';

CREATE POLICY pol_agente_asistente_insert
    ON agente_asistente FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_agente_asistente_update
    ON agente_asistente FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- DELETE: no — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: asistente_telefono
-- Misma estrategia que agente_telefono.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_asistente_tel_select
    ON asistente_telefono FOR SELECT TO authenticated
    USING (TRUE);

CREATE POLICY pol_asistente_tel_insert
    ON asistente_telefono FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_asistente_tel_update
    ON asistente_telefono FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- Teléfonos SÍ se pueden eliminar físicamente (sin impacto de integridad)
CREATE POLICY pol_asistente_tel_delete
    ON asistente_telefono FOR DELETE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );


-- =============================================================================
-- SECCIÓN 11: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON TABLE ot_activacion      TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE agente_asistente   TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE asistente_telefono TO authenticated;

GRANT EXECUTE ON FUNCTION registrar_activacion_gnp(UUID, TEXT, TEXT, DATE, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION resolver_agente_desde_email(TEXT) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000010_modulo_11_correcciones.sql
-- =============================================================================

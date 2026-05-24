-- =============================================================================
-- Migración: 20260522000003_modulo_04_tramites.sql
-- Módulo 4 — Trámites: tabla central de operaciones del CRM Olimpo
-- =============================================================================
-- Filosofía de diseño:
--   Dos tablas con responsabilidades distintas y complementarias:
--
--   tramite        → Estado ACTUAL. Siempre consistente. Se actualiza constantemente.
--                    Responde: ¿dónde está este trámite? ¿quién lo atiende? ¿cuándo vence?
--
--   tramite_evento → Historia INMUTABLE. Append-only. Nunca se edita ni borra.
--                    Responde: ¿cómo llegó hasta aquí? ¿quién hizo qué y cuándo?
--                    Alimenta el RAG con contexto rico y ordenado cronológicamente.
--
-- Principios anti-huérfano:
--   1. analista_id es NULL solo en estado 'recibido' — CHECK en DB lo enforce.
--   2. Trigger auto-asigna gerente_id al momento de asignar analista_id.
--   3. ultima_actividad se actualiza con cada INSERT en tramite_evento.
--   4. requiere_atencion permite que el agente IA escale a humano.
--
-- Relaciones con módulos anteriores:
--   tramite.poliza_id    → poliza.id     (Módulo 3 — nullable)
--   tramite.asegurado_id → asegurado.id  (Módulo 3 — nullable)
--   tramite.agente_id    → agente.id     (Módulo 2 — nullable: NULL cuando cascada CUA falla)
--   tramite.asistente_id → asistente.id  (Módulo 2 — nullable)
--   tramite.analista_id  → usuario.id    (Módulo 1 — nullable solo en recibido)
--   tramite.gerente_id   → usuario.id    (Módulo 1 — auto-asignado por trigger)
--
-- Relaciones con módulos futuros:
--   correo.tramite_id    → tramite.id    (Módulo 5)
--   adjunto.tramite_id   → tramite.id    (Módulo 5)
--   sla_tramite.tramite_id → tramite.id  (Módulo 7)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

-- Máquina de estados del trámite (orden refleja el flujo normal)
CREATE TYPE estado_tramite AS ENUM (
    'recibido',             -- llegó el correo/tramite, aún sin procesar
    'validando',            -- los agentes IA están procesando documentos
    'pendiente_documentos', -- faltan documentos, se solicitaron al agente
    'completo',             -- documentación completa, listo para GNP
    'turnado_gnp',          -- enviado a GNP, esperando acuse
    'en_proceso_gnp',       -- GNP lo está procesando internamente
    'activado',             -- GNP activó la póliza (puede repetirse en endosos)
    'aprobado',             -- proceso finalizado con éxito
    'rechazado'             -- GNP rechazó o el trámite no prosperó
);

COMMENT ON TYPE estado_tramite IS
    'Máquina de estados del trámite. '
    'Flujo normal: recibido→validando→pendiente_documentos↔completo→turnado_gnp→en_proceso_gnp→activado→aprobado. '
    'El estado activado puede repetirse (endosos con múltiples activaciones).';


CREATE TYPE tipo_tramite AS ENUM (
    'alta',         -- nueva póliza
    'endoso',       -- modificación a póliza existente
    'renovacion',   -- renovación de póliza vencida
    'cancelacion',  -- cancelación de póliza
    'siniestro',    -- reporte de siniestro
    'reactivacion', -- reactivación de póliza cancelada
    'consulta',     -- consulta general sin tramitación formal
    'desconocido'   -- Agente 2 no pudo determinar el tipo con confianza suficiente
);

COMMENT ON TYPE tipo_tramite IS
    'Tipo de gestión que representa el trámite. Determina los documentos requeridos.';


CREATE TYPE prioridad_tramite AS ENUM (
    'normal',
    'alta',
    'urgente'
);

COMMENT ON TYPE prioridad_tramite IS
    'Prioridad de atención. Afecta el orden en el dashboard del analista y las alertas de SLA.';


CREATE TYPE canal_origen_tramite AS ENUM (
    'email',    -- llegó por correo electrónico (flujo principal)
    'manual',   -- creado manualmente por un analista o director
    'portal'    -- futuro: portal de agentes
);

COMMENT ON TYPE canal_origen_tramite IS
    'Canal por el que ingresó el trámite al sistema.';


CREATE TYPE tipo_evento_tramite AS ENUM (
    'creacion',              -- trámite creado en el sistema
    'cambio_estado',         -- cambio en la máquina de estados
    'asignacion',            -- analista asignado por primera vez
    'reasignacion',          -- cambio de analista
    'nota_analista',         -- nota interna escrita por analista o gerente
    'documento_agregado',    -- nuevo documento procesado
    'correo_recibido',       -- correo entrante vinculado al trámite
    'correo_enviado',        -- correo saliente del Agente 6 enviado
    'accion_agente_ia',      -- acción realizada por un agente IA (1-6)
    'activacion_gnp',        -- GNP activó la póliza
    'solicitud_documentos',  -- se solicitaron documentos faltantes al agente
    'rechazo_gnp',           -- GNP rechazó el trámite
    'aprendizaje_rag'        -- evento generado para entrenar el RAG
);

COMMENT ON TYPE tipo_evento_tramite IS
    'Catálogo de eventos que pueden ocurrir en la vida de un trámite. '
    'Cada evento en tramite_evento tiene exactamente uno de estos tipos.';


-- =============================================================================
-- SECCIÓN 2: GENERADOR DE FOLIO INTERNO (TRM-YYYY-NNNNN)
-- =============================================================================
-- El folio reinicia cada año: TRM-2025-00001, TRM-2025-00002, ..., TRM-2026-00001.
-- Se usa una tabla de contadores por año para garantizar atomicidad y unicidad
-- incluso bajo carga concurrente (INSERT ... ON CONFLICT es atómico en PostgreSQL).
-- =============================================================================

CREATE TABLE tramite_folio_contador (
    anio        SMALLINT    PRIMARY KEY,
    contador    INTEGER     NOT NULL DEFAULT 0
);

COMMENT ON TABLE tramite_folio_contador IS
    'Contador de folios por año. Garantiza que TRM-YYYY-NNNNN sea único y secuencial. '
    'Operado exclusivamente por la función siguiente_folio_tramite().';


CREATE OR REPLACE FUNCTION siguiente_folio_tramite()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_anio      SMALLINT;
    v_contador  INTEGER;
BEGIN
    v_anio := EXTRACT(YEAR FROM NOW())::SMALLINT;

    -- INSERT o incremento atómico — thread-safe bajo concurrencia
    INSERT INTO tramite_folio_contador (anio, contador)
    VALUES (v_anio, 1)
    ON CONFLICT (anio) DO UPDATE
        SET contador = tramite_folio_contador.contador + 1
    RETURNING contador INTO v_contador;

    -- Formato: TRM-2025-00001
    RETURN 'TRM-' || v_anio::TEXT || '-' || LPAD(v_contador::TEXT, 5, '0');
END;
$$;

COMMENT ON FUNCTION siguiente_folio_tramite() IS
    'Genera el siguiente folio interno secuencial por año (TRM-YYYY-NNNNN). '
    'Reinicia a 00001 cada año nuevo. Seguro bajo concurrencia.';


-- =============================================================================
-- SECCIÓN 3: TABLA tramite — estado actual del trámite
-- =============================================================================

CREATE TABLE tramite (
    -- -------------------------------------------------------------------------
    -- Identificadores
    -- -------------------------------------------------------------------------
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Folio interno: auto-generado por trigger antes del INSERT
    folio           TEXT                    NOT NULL,
    -- Folio OT: asignado por GNP, llega después de turnar el trámite
    folio_ot        TEXT                    NULL,

    -- -------------------------------------------------------------------------
    -- Clasificación
    -- -------------------------------------------------------------------------
    tipo_tramite    tipo_tramite            NOT NULL,
    estado          estado_tramite          NOT NULL DEFAULT 'recibido',
    prioridad       prioridad_tramite       NOT NULL DEFAULT 'normal',
    canal_origen    canal_origen_tramite    NOT NULL DEFAULT 'email',
    -- Ramo denormalizado para RLS sin JOIN — se copia de poliza o se extrae
    -- del contexto por el Agente 2 al momento de clasificar el trámite
    ramo            ramo_usuario            NULL,

    -- -------------------------------------------------------------------------
    -- Relaciones con entidades del CRM
    -- -------------------------------------------------------------------------
    -- Póliza vinculada — NULL si es un alta nueva y la póliza aún no existe
    poliza_id       UUID    NULL REFERENCES poliza(id),
    -- Asegurado principal del trámite — NULL hasta que el Agente 3 lo identifique
    asegurado_id    UUID    NULL REFERENCES asegurado(id),
    -- Agente que gestiona — identificado por el Agente 4 via cascada CUA.
    -- NULL cuando la cascada falla (confianza < umbral): el trámite se crea
    -- con requiere_atencion = TRUE para que un analista lo asigne manualmente.
    -- El CHECK abajo exige que esté presente a partir del estado 'completo'.
    agente_id       UUID    NULL REFERENCES agente(id),
    -- Asistente — solo si el correo vino de un asistente en lugar del agente
    asistente_id    UUID    NULL REFERENCES asistente(id),
    -- Analista responsable — EL DUEÑO del trámite.
    -- NULL solo en 'recibido'. El CHECK abajo lo enforce a partir de 'validando'.
    analista_id     UUID    NULL REFERENCES usuario(id),
    -- Gerente del analista — auto-asignado por trigger cuando se asigna analista.
    -- Denormalizado para evitar JOINs en dashboards y RLS.
    gerente_id      UUID    NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Descripción y contexto
    -- -------------------------------------------------------------------------
    titulo          TEXT    NOT NULL,   -- descripción breve: "Alta GMM Familia García"
    descripcion     TEXT    NULL,       -- descripción detallada del trámite

    -- Datos estructurados producidos por cada agente IA.
    -- Estructura esperada (se va llenando conforme avanza el pipeline):
    -- {
    --   "agente_1": { "adjuntos": 3, "zips_procesados": 1, "archivos_extraidos": 4 },
    --   "agente_2": { "confianza_agente": 0.92, "confianza_tipo_tramite": 0.88 },
    --   "agente_3": { "documentos_ocr": ["INE", "solicitud_alta"], "ilegibles": [] },
    --   "agente_4": { "metodo_id": "cua_directo", "confianza_asignacion": 0.97 },
    --   "agente_5": { "docs_validos": 3, "docs_faltantes": ["carta_medica"] },
    --   "agente_6": { "correo_borrador_id": "uuid", "palabras": 245 }
    -- }
    datos_tramite   JSONB   NULL DEFAULT '{}',

    -- Resumen generado por IA — texto legible para el RAG y para la UI.
    -- El Agente 5 o 6 lo actualiza con cada cambio significativo.
    resumen_ia      TEXT    NULL,

    -- Tags para filtrar en la UI y enriquecer el RAG
    -- Ejemplos: ["urgente", "cliente-vip", "documentos-incompletos", "rechazo-previo"]
    etiquetas       TEXT[]  NOT NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Señales de atención y calidad
    -- -------------------------------------------------------------------------
    -- El agente IA lo activa cuando detecta que necesita intervención humana
    -- (cascada fallida, documento ilegible, ambigüedad alta, rechazo previo)
    requiere_atencion   BOOLEAN     NOT NULL DEFAULT FALSE,
    -- Score 0-1 asignado por el Agente 2 basado en complejidad documental y ramo
    score_complejidad   NUMERIC(3,2) NULL CHECK (score_complejidad BETWEEN 0 AND 1),

    -- -------------------------------------------------------------------------
    -- Monitoreo del pipeline IA
    -- -------------------------------------------------------------------------
    -- Indica qué agente IA está procesando activamente el trámite en este momento.
    -- NULL = ningún agente corriendo (idle o pipeline completado).
    -- Permite detectar trámites atascados y reanudar pipelines tras fallos.
    -- Valores: 'agente_1' | 'agente_2' | 'agente_3' | 'agente_4' | 'agente_5' | 'agente_6'
    paso_pipeline_actual TEXT        NULL,
    -- Timestamp de cuándo inició el paso actual — para detectar timeouts
    paso_pipeline_inicio TIMESTAMPTZ NULL,

    -- -------------------------------------------------------------------------
    -- Fechas de seguimiento GNP
    -- -------------------------------------------------------------------------
    fecha_recepcion     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Deadline calculado por el motor de SLAs (Módulo 7)
    fecha_limite_sla    TIMESTAMPTZ NULL,
    -- Cuándo se envió a GNP (estado turnado_gnp)
    ot_fecha_envio      DATE        NULL,
    -- Cuándo respondió GNP (aprobado o rechazado)
    ot_fecha_respuesta  DATE        NULL,
    -- Motivo de rechazo cuando GNP rechaza — texto libre del analista o IA
    motivo_rechazo_gnp  TEXT        NULL,

    -- -------------------------------------------------------------------------
    -- Actividad — anti-abandono
    -- -------------------------------------------------------------------------
    -- Se actualiza automáticamente en cada INSERT a tramite_evento.
    -- Permite detectar trámites sin actividad y activar alertas.
    ultima_actividad    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- Estado y auditoría
    -- -------------------------------------------------------------------------
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    CONSTRAINT uq_tramite_folio     UNIQUE (folio),
    CONSTRAINT uq_tramite_folio_ot  UNIQUE (folio_ot),

    -- CONTRATO ANTI-HUÉRFANO — analista obligatorio tras estados iniciales
    CONSTRAINT ck_tramite_analista_requerido CHECK (
        estado IN ('recibido', 'validando')
        OR analista_id IS NOT NULL
    ),

    -- CONTRATO DE IDENTIFICACIÓN — agente obligatorio antes de turnar a GNP
    -- NULL en estados tempranos (Agente 4 aún no terminó o cascada fallida).
    -- requiere_atencion = TRUE cuando agente_id sigue NULL pasando 'validando'.
    CONSTRAINT ck_tramite_agente_requerido CHECK (
        estado IN ('recibido', 'validando', 'pendiente_documentos')
        OR agente_id IS NOT NULL
    ),

    -- El motivo de rechazo solo aplica cuando el estado es 'rechazado'
    CONSTRAINT ck_tramite_rechazo_consistente CHECK (
        motivo_rechazo_gnp IS NULL OR estado = 'rechazado'
    ),

    -- Las fechas OT solo aplican cuando existe folio_ot
    CONSTRAINT ck_tramite_ot_envio CHECK (
        ot_fecha_envio IS NULL OR folio_ot IS NOT NULL
    ),

    CONSTRAINT ck_tramite_titulo CHECK (TRIM(titulo) <> '')
);

COMMENT ON TABLE tramite IS
    'Tabla central del CRM Olimpo. Representa el estado ACTUAL de cada gestión. '
    'Se actualiza constantemente. El historial completo vive en tramite_evento. '
    'Constraint ck_tramite_analista_requerido elimina los trámites sin dueño a nivel DB.';

COMMENT ON COLUMN tramite.folio               IS 'Folio interno auto-generado: TRM-YYYY-NNNNN. Reinicia por año. Nunca NULL.';
COMMENT ON COLUMN tramite.folio_ot            IS 'Número de Orden de Trabajo asignado por GNP. Llega al turnarse el trámite.';
COMMENT ON COLUMN tramite.ramo                IS 'Ramo denormalizado desde poliza o extraído por Agente 2. Evita JOINs en RLS.';
COMMENT ON COLUMN tramite.analista_id         IS 'Dueño del trámite. NULL solo en recibido/validando — el CHECK lo enforce.';
COMMENT ON COLUMN tramite.gerente_id          IS 'Gerente del analista. Auto-asignado por trigger cuando se asigna analista_id.';
COMMENT ON COLUMN tramite.datos_tramite       IS 'Salidas estructuradas de los 6 agentes IA. Se construye incrementalmente.';
COMMENT ON COLUMN tramite.resumen_ia          IS 'Resumen textual generado por IA. Alimenta el RAG y aparece en la UI del analista.';
COMMENT ON COLUMN tramite.etiquetas           IS 'Tags de texto libre para filtrado en UI y enriquecimiento del RAG.';
COMMENT ON COLUMN tramite.requiere_atencion   IS 'True cuando el agente IA detecta que necesita decisión o acción humana urgente.';
COMMENT ON COLUMN tramite.score_complejidad   IS 'Score 0-1 de complejidad asignado por Agente 2. Ayuda a priorizar y asignar.';
COMMENT ON COLUMN tramite.ultima_actividad    IS 'Timestamp de la última actividad. Actualizado por trigger en cada tramite_evento.';
COMMENT ON COLUMN tramite.fecha_limite_sla    IS 'Deadline de SLA calculado por el motor de SLAs (Módulo 7). NULL hasta activarse.';


-- =============================================================================
-- SECCIÓN 4: TABLA tramite_evento — historia inmutable del trámite
-- =============================================================================
-- Registro append-only de todo lo que ocurrió en la vida del trámite.
-- NUNCA se edita ni elimina un evento.
-- Es la fuente de verdad para:
--   - El timeline del trámite en la UI
--   - Los chunks de texto que alimentan el RAG
--   - La trazabilidad para auditorías y disputas
--   - El análisis de tiempos entre estados para SLA
-- =============================================================================

CREATE TABLE tramite_evento (
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    tramite_id      UUID                    NOT NULL REFERENCES tramite(id) ON DELETE CASCADE,
    tipo_evento     tipo_evento_tramite     NOT NULL,

    -- Para eventos tipo 'cambio_estado': estado antes y después
    estado_anterior estado_tramite          NULL,
    estado_nuevo    estado_tramite          NULL,

    -- Actor humano — NULL si el evento fue generado por un agente IA
    usuario_id      UUID                    NULL REFERENCES usuario(id),
    -- Actor IA — NULL si el evento fue generado por un humano
    -- Valores esperados: 'agente_1' a 'agente_6', o nombre del proceso
    agente_ia_nombre TEXT                   NULL,

    -- Descripción legible para humanos — es el texto principal que lee el RAG.
    -- Debe ser autocontenido: "El Agente 5 validó 3 documentos. Falta: carta médica."
    descripcion     TEXT                    NOT NULL,

    -- Datos estructurados del evento para procesamiento programático
    -- Estructura varía por tipo_evento. Ejemplos:
    --   cambio_estado:        { "razon": "documentos completos" }
    --   documento_agregado:   { "documento_id": "uuid", "tipo": "INE", "confianza": 0.95 }
    --   correo_recibido:      { "correo_id": "uuid", "asunto": "..." }
    --   accion_agente_ia:     { "agente": "agente_5", "resultado": {...} }
    --   rechazo_gnp:          { "codigo_rechazo": "R-042", "detalle": "..." }
    datos           JSONB                   NULL DEFAULT '{}',

    -- Controla si el evento aparece en el timeline visible del analista.
    -- false: eventos internos de la IA que no aportan a la UI pero sí al RAG.
    visible_en_timeline BOOLEAN             NOT NULL DEFAULT TRUE,

    -- Sin updated_at — los eventos son INMUTABLES
    created_at      TIMESTAMPTZ             NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- cambio_estado requiere ambos estados
    CONSTRAINT ck_evento_cambio_estado CHECK (
        tipo_evento <> 'cambio_estado'
        OR (estado_anterior IS NOT NULL AND estado_nuevo IS NOT NULL)
    ),

    -- Solo un actor por evento (humano o IA, no ambos ni ninguno)
    CONSTRAINT ck_evento_actor CHECK (
        (usuario_id IS NOT NULL AND agente_ia_nombre IS NULL)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NOT NULL)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NULL) -- eventos del sistema
    ),

    CONSTRAINT ck_evento_descripcion CHECK (TRIM(descripcion) <> '')
);

COMMENT ON TABLE tramite_evento IS
    'Historia inmutable del trámite. Append-only — nunca se edita ni elimina. '
    'Alimenta el RAG con contexto cronológico rico. '
    'El timeline de la UI lee de aquí filtrando visible_en_timeline = TRUE.';

COMMENT ON COLUMN tramite_evento.descripcion        IS 'Texto legible y autocontenido. Principal insumo del RAG para este trámite.';
COMMENT ON COLUMN tramite_evento.visible_en_timeline IS 'FALSE para eventos internos de IA que no aportan valor al analista en la UI.';
COMMENT ON COLUMN tramite_evento.usuario_id         IS 'Actor humano. NULL si el evento fue generado por un agente IA.';
COMMENT ON COLUMN tramite_evento.agente_ia_nombre   IS 'Actor IA. NULL si el evento fue generado por un humano.';


-- =============================================================================
-- SECCIÓN 5: ÍNDICES
-- =============================================================================

-- tramite — queries de dashboard (el patrón más frecuente)
CREATE INDEX idx_tramite_analista_estado
    ON tramite (analista_id, estado)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_tramite_analista_estado IS
    'Query principal del dashboard del analista: sus trámites por estado.';

CREATE INDEX idx_tramite_gerente_estado
    ON tramite (gerente_id, estado)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_tramite_gerente_estado IS
    'Query principal del dashboard del gerente: trámites de su equipo por estado.';

CREATE INDEX idx_tramite_agente
    ON tramite (agente_id);

CREATE INDEX idx_tramite_poliza
    ON tramite (poliza_id)
    WHERE poliza_id IS NOT NULL;

CREATE INDEX idx_tramite_ramo_estado
    ON tramite (ramo, estado)
    WHERE activo = TRUE;

-- Índice para detectar trámites sin actividad reciente (SLA y anti-abandono)
CREATE INDEX idx_tramite_ultima_actividad
    ON tramite (ultima_actividad)
    WHERE activo = TRUE AND estado NOT IN ('aprobado', 'rechazado');

COMMENT ON INDEX idx_tramite_ultima_actividad IS
    'Detecta trámites inactivos para alertas de SLA. Solo trámites abiertos.';

-- Índice para trámites que requieren atención humana urgente
CREATE INDEX idx_tramite_requiere_atencion
    ON tramite (requiere_atencion, prioridad)
    WHERE requiere_atencion = TRUE AND activo = TRUE;

-- Folio OT — búsqueda cuando GNP responde con el número de OT
CREATE INDEX idx_tramite_folio_ot
    ON tramite (folio_ot)
    WHERE folio_ot IS NOT NULL;

-- Búsqueda por folio interno en la barra de búsqueda de la UI
CREATE INDEX idx_tramite_folio
    ON tramite (folio);

-- SLA: trámites próximos a vencer
CREATE INDEX idx_tramite_sla_vencimiento
    ON tramite (fecha_limite_sla)
    WHERE fecha_limite_sla IS NOT NULL
      AND activo = TRUE
      AND estado NOT IN ('aprobado', 'rechazado');

-- JSONB: búsquedas dentro de datos_tramite y etiquetas
CREATE INDEX idx_tramite_datos
    ON tramite USING gin (datos_tramite);

CREATE INDEX idx_tramite_etiquetas
    ON tramite USING gin (etiquetas);

-- tramite_evento — queries del timeline
CREATE INDEX idx_tramite_evento_tramite_ts
    ON tramite_evento (tramite_id, created_at DESC);

COMMENT ON INDEX idx_tramite_evento_tramite_ts IS
    'Timeline del trámite ordenado por tiempo. Query más frecuente de tramite_evento.';

CREATE INDEX idx_tramite_evento_tipo
    ON tramite_evento (tramite_id, tipo_evento);

-- Para el RAG: eventos visibles ordenados por tiempo
CREATE INDEX idx_tramite_evento_rag
    ON tramite_evento (tramite_id, created_at)
    WHERE visible_en_timeline = TRUE;

COMMENT ON INDEX idx_tramite_evento_rag IS
    'Eventos visibles para construcción de chunks RAG por trámite.';


-- =============================================================================
-- SECCIÓN 6: FUNCIONES Y TRIGGERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 Auto-generación del folio en INSERT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_folio_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.folio IS NULL THEN
        NEW.folio := siguiente_folio_tramite();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tramite_set_folio
    BEFORE INSERT ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION set_folio_tramite();

COMMENT ON TRIGGER trg_tramite_set_folio ON tramite IS
    'Genera el folio TRM-YYYY-NNNNN automáticamente si no se provee en el INSERT.';


-- -----------------------------------------------------------------------------
-- 6.2 updated_at automático
-- set_updated_at() ya existe desde migración 20260522000000.
-- -----------------------------------------------------------------------------

CREATE TRIGGER trg_tramite_updated_at
    BEFORE UPDATE ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 6.3 Auto-asignación de gerente_id cuando se asigna analista_id
-- Busca el gerente activo del mismo ramo que el analista.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION asignar_gerente_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ramo_analista ramo_usuario;
    v_gerente_id    UUID;
BEGIN
    -- Solo actuar si analista_id cambió y tiene un valor
    IF NEW.analista_id IS NOT NULL
       AND (OLD.analista_id IS NULL OR OLD.analista_id <> NEW.analista_id)
    THEN
        -- Obtener el ramo del analista asignado
        SELECT ramo INTO v_ramo_analista
        FROM usuario
        WHERE id = NEW.analista_id;

        -- Buscar el gerente activo de ese ramo
        SELECT id INTO v_gerente_id
        FROM usuario
        WHERE rol = 'gerente'
          AND ramo = v_ramo_analista
          AND activo = TRUE
        LIMIT 1;

        NEW.gerente_id := v_gerente_id;

        -- Si el trámite no tiene ramo, heredarlo del analista
        IF NEW.ramo IS NULL THEN
            NEW.ramo := v_ramo_analista;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION asignar_gerente_tramite() IS
    'Al asignar analista_id, auto-busca y asigna el gerente activo de su ramo. '
    'También hereda el ramo al trámite si aún no lo tiene.';

CREATE TRIGGER trg_tramite_asignar_gerente
    BEFORE INSERT OR UPDATE OF analista_id ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION asignar_gerente_tramite();


-- -----------------------------------------------------------------------------
-- 6.4 Registro automático de cambios de estado en tramite_evento
--
-- Atribución de cambios al actor correcto:
--   Los agentes IA corren con service_role — auth.uid() devuelve NULL.
--   Para que el trigger sepa qué agente hizo el cambio, el agente IA debe
--   declararse ANTES de ejecutar el UPDATE usando una variable de sesión:
--
--     -- Python (Agente 5):
--     supabase.rpc('set_agente_ia_sesion', {'nombre': 'agente_5'}).execute()
--     supabase.table('tramite').update({'estado': 'completo'}).eq('id', id).execute()
--
--   El trigger lee app.agente_ia_actual de la sesión PostgreSQL.
--   Si es NULL (lo hizo un humano), usa auth.uid() en su lugar.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_agente_ia_sesion(nombre TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT set_config('app.agente_ia_actual', nombre, TRUE);
$$;

COMMENT ON FUNCTION set_agente_ia_sesion(TEXT) IS
    'Los agentes IA llaman esta función antes de modificar tramite para que '
    'los triggers de auditoría puedan atribuir el cambio al agente correcto. '
    'La variable vive solo en la sesión actual (TRUE = local a la transacción).';


CREATE OR REPLACE FUNCTION registrar_cambio_estado_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_agente_ia     TEXT;
    v_usuario_id    UUID;
BEGIN
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN

        -- Determinar actor: ¿humano o agente IA?
        v_agente_ia  := NULLIF(current_setting('app.agente_ia_actual', TRUE), '');
        v_usuario_id := CASE WHEN v_agente_ia IS NULL THEN auth.uid() ELSE NULL END;

        INSERT INTO tramite_evento (
            tramite_id,
            tipo_evento,
            estado_anterior,
            estado_nuevo,
            usuario_id,
            agente_ia_nombre,
            descripcion,
            datos,
            visible_en_timeline,
            created_at
        ) VALUES (
            NEW.id,
            'cambio_estado',
            OLD.estado,
            NEW.estado,
            v_usuario_id,
            v_agente_ia,
            CASE
                WHEN v_agente_ia IS NOT NULL
                THEN v_agente_ia || ' cambió el estado de "' || OLD.estado || '" a "' || NEW.estado || '".'
                ELSE 'Estado cambiado de "' || OLD.estado || '" a "' || NEW.estado || '".'
            END,
            jsonb_build_object(
                'estado_anterior',   OLD.estado,
                'estado_nuevo',      NEW.estado,
                'actor',             COALESCE(v_agente_ia, 'usuario')
            ),
            TRUE,
            NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_cambio_estado_tramite() IS
    'Registra automáticamente cada cambio de estado en tramite_evento. '
    'Lee app.agente_ia_actual (set_agente_ia_sesion) para atribuir el cambio '
    'al agente IA correcto cuando es service_role quien ejecuta el UPDATE.';

CREATE TRIGGER trg_tramite_registrar_estado
    AFTER UPDATE OF estado ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION registrar_cambio_estado_tramite();


-- -----------------------------------------------------------------------------
-- 6.5 Registro automático de asignación/reasignación en tramite_evento
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION registrar_asignacion_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_nombre_analista TEXT;
    v_tipo            tipo_evento_tramite;
    v_descripcion     TEXT;
BEGIN
    IF NEW.analista_id IS DISTINCT FROM OLD.analista_id
       AND NEW.analista_id IS NOT NULL
    THEN
        SELECT nombre INTO v_nombre_analista
        FROM usuario WHERE id = NEW.analista_id;

        v_tipo := CASE
            WHEN OLD.analista_id IS NULL THEN 'asignacion'
            ELSE 'reasignacion'
        END;

        v_descripcion := CASE
            WHEN OLD.analista_id IS NULL
            THEN 'Trámite asignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
            ELSE 'Trámite reasignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
        END;

        INSERT INTO tramite_evento (
            tramite_id, tipo_evento, usuario_id, agente_ia_nombre,
            descripcion, datos, visible_en_timeline, created_at
        ) VALUES (
            NEW.id, v_tipo,
            CASE WHEN NULLIF(current_setting('app.agente_ia_actual', TRUE), '') IS NULL
                 THEN auth.uid() ELSE NULL END,
            NULLIF(current_setting('app.agente_ia_actual', TRUE), ''),
            v_descripcion,
            jsonb_build_object(
                'analista_anterior_id', OLD.analista_id,
                'analista_nuevo_id',    NEW.analista_id
            ),
            TRUE, NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tramite_registrar_asignacion
    AFTER UPDATE OF analista_id ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION registrar_asignacion_tramite();


-- -----------------------------------------------------------------------------
-- 6.6 Actualización de ultima_actividad en tramite al insertar un evento
-- Mantiene el campo anti-abandono sincronizado automáticamente.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION actualizar_ultima_actividad_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE tramite
    SET ultima_actividad = NOW()
    WHERE id = NEW.tramite_id;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION actualizar_ultima_actividad_tramite() IS
    'Cada nuevo evento en tramite_evento actualiza ultima_actividad en tramite. '
    'Permite detectar trámites abandonados consultando solo la tabla tramite.';

CREATE TRIGGER trg_tramite_evento_actividad
    AFTER INSERT ON tramite_evento
    FOR EACH ROW
    EXECUTE FUNCTION actualizar_ultima_actividad_tramite();


-- -----------------------------------------------------------------------------
-- 6.7 Evento de creación automático al insertar un trámite
-- El primer evento de toda historia es la creación del trámite.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION registrar_creacion_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO tramite_evento (
        tramite_id,
        tipo_evento,
        usuario_id,
        descripcion,
        datos,
        visible_en_timeline,
        created_at
    ) VALUES (
        NEW.id,
        'creacion',
        auth.uid(),
        'Trámite ' || NEW.folio || ' creado. Tipo: ' || NEW.tipo_tramite ||
            '. Canal: ' || NEW.canal_origen || '.',
        jsonb_build_object(
            'folio',         NEW.folio,
            'tipo_tramite',  NEW.tipo_tramite,
            'canal_origen',  NEW.canal_origen,
            'estado_inicial', NEW.estado
        ),
        TRUE,
        NOW()
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tramite_registrar_creacion
    AFTER INSERT ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION registrar_creacion_tramite();


-- =============================================================================
-- SECCIÓN 7: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--   director_general / director_ops — ven y gestionan todos los trámites
--   gerente — ve los trámites de su ramo (via gerente_id o ramo)
--   analista — ve solo los trámites donde es el analista asignado
--
-- tramite_evento hereda la visibilidad del tramite padre via subquery.
-- Los eventos son append-only: INSERT sí, UPDATE y DELETE no.
-- =============================================================================

ALTER TABLE tramite         ENABLE ROW LEVEL SECURITY;
ALTER TABLE tramite_evento  ENABLE ROW LEVEL SECURITY;
ALTER TABLE tramite_folio_contador ENABLE ROW LEVEL SECURITY;

-- El contador de folios es interno — solo service_role lo opera
-- authenticated no necesita acceso directo


-- -----------------------------------------------------------------------------
-- POLICIES: tramite
-- -----------------------------------------------------------------------------

CREATE POLICY pol_tramite_select_director
    ON tramite FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

COMMENT ON POLICY pol_tramite_select_director ON tramite IS
    'Directores ven todos los trámites sin restricción de ramo ni analista.';

CREATE POLICY pol_tramite_select_gerente
    ON tramite FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (
            gerente_id = auth.uid()
            -- Fallback: ramo coincide (cubre trámites antes de asignar gerente_id)
            OR (ramo IS NOT NULL AND ramo::text = auth_ramo())
        )
    );

COMMENT ON POLICY pol_tramite_select_gerente ON tramite IS
    'Gerente ve trámites donde es el gerente asignado o que coinciden con su ramo.';

CREATE POLICY pol_tramite_select_analista
    ON tramite FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    );

COMMENT ON POLICY pol_tramite_select_analista ON tramite IS
    'Analista ve únicamente los trámites donde es el analista asignado. '
    'Los trámites en recibido/validando sin asignar son invisibles hasta ser asignados.';

-- INSERT: cualquier rol autenticado puede crear trámites
-- (el Agente 1 usa service_role; analistas crean trámites manuales)
CREATE POLICY pol_tramite_insert
    ON tramite FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- UPDATE: cada rol actualiza lo que puede ver
CREATE POLICY pol_tramite_update_director
    ON tramite FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_tramite_update_gerente
    ON tramite FOR UPDATE TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (gerente_id = auth.uid() OR (ramo IS NOT NULL AND ramo::text = auth_ramo()))
    )
    WITH CHECK (
        auth_rol() = 'gerente'
        AND (gerente_id = auth.uid() OR (ramo IS NOT NULL AND ramo::text = auth_ramo()))
    );

CREATE POLICY pol_tramite_update_analista
    ON tramite FOR UPDATE TO authenticated
    USING (auth_rol() = 'analista' AND analista_id = auth.uid())
    WITH CHECK (auth_rol() = 'analista' AND analista_id = auth.uid());

-- DELETE: nadie — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: tramite_evento (append-only — no UPDATE, no DELETE)
-- -----------------------------------------------------------------------------

-- SELECT: misma visibilidad que el trámite padre
CREATE POLICY pol_tramite_evento_select
    ON tramite_evento FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM tramite t
            WHERE t.id = tramite_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente'
                    AND (t.gerente_id = auth.uid()
                         OR (t.ramo IS NOT NULL AND t.ramo::text = auth_ramo())))
                OR (auth_rol() = 'analista' AND t.analista_id = auth.uid())
              )
        )
    );

-- INSERT: cualquier rol puede agregar eventos a trámites que puede ver
-- (notas de analistas, acciones manuales, etc.)
-- Los agentes IA usan service_role (bypasa RLS)
CREATE POLICY pol_tramite_evento_insert
    ON tramite_evento FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM tramite t
            WHERE t.id = tramite_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente'
                    AND (t.gerente_id = auth.uid()
                         OR (t.ramo IS NOT NULL AND t.ramo::text = auth_ramo())))
                OR (auth_rol() = 'analista' AND t.analista_id = auth.uid())
              )
        )
    );

-- UPDATE y DELETE: absolutamente nadie — los eventos son sagrados e inmutables


-- =============================================================================
-- SECCIÓN 8: GRANTS
-- =============================================================================

-- tramite_folio_contador: solo service_role (el trigger lo usa internamente)
-- No se otorga acceso a authenticated

GRANT SELECT, INSERT, UPDATE ON TABLE tramite TO authenticated;
GRANT SELECT, INSERT ON TABLE tramite_evento TO authenticated;
-- tramite_evento: sin UPDATE ni DELETE para nadie — append-only

-- Los agentes IA llaman esta función para identificarse antes de modificar tramite
GRANT EXECUTE ON FUNCTION set_agente_ia_sesion(TEXT) TO authenticated;

-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000003_modulo_04_tramites.sql
-- =============================================================================

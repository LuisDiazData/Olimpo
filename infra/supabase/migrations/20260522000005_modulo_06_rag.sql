-- =============================================================================
-- Migración: 20260522000005_modulo_06_rag.sql
-- Módulo 6 — RAG: Base de conocimiento vectorial del CRM Olimpo
-- =============================================================================
-- Tres RAGs con propósitos distintos y complementarios:
--
--   rag_gnp          → Conocimiento estático de GNP: manuales, requisitos por
--                       producto, formularios modelo, circulares. Curado por humanos
--                       vía la app rag-ingest. Se filtra por metadata ANTES del
--                       vector search para mayor precisión y menor costo.
--
--   rag_polizas      → Historial dinámico de pólizas: se construye automáticamente
--                       conforme el Agente 5 procesa trámites. Empieza vacío.
--                       Cada trámite aprobado/rechazado/activado agrega un chunk.
--                       Con el tiempo genera patrones por agente, ramo y tipo.
--
--   rag_aprendizajes → Memoria de rechazos de GNP: cada rechazo genera un chunk
--                       que explica QUÉ salió mal y CÓMO corregirlo. Es el
--                       diferenciador competitivo — el sistema aprende de sus errores.
--                       Los analistas validan los aprendizajes para filtrar ruido.
--
-- Modelo de embeddings: OpenAI text-embedding-3-small (1536 dimensiones)
-- Similaridad: coseno (los embeddings de OpenAI están normalizados)
-- Índice: HNSW — mejor precisión en producción vs. IVFFlat
--
-- Flujo de escritura:
--   rag_gnp:          app rag-ingest → genera chunks → llama OpenAI → INSERT
--   rag_polizas:      Agente 5 al completar validación → INSERT (via Celery)
--   rag_aprendizajes: Agente 5 al recibir rechazo GNP → INSERT (via Celery)
--                     Analista/Gerente → valida con UPDATE aprendizaje_validado
--
-- Flujo de lectura (Agente 5 — Validación):
--   1. Pre-filtrar por ramo, tipo_tramite, tipo_documento, vigente
--   2. Vector search con embedding del documento a validar
--   3. Contextualizar respuesta con chunks más similares
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: EXTENSIÓN PGVECTOR
-- =============================================================================
-- Supabase la habilita por defecto, pero se declara explícitamente en la
-- migración para que sea reproducible en cualquier ambiente.

CREATE EXTENSION IF NOT EXISTS vector;

-- pg_trgm ya fue requerida en módulos anteriores (idx_agente_nombre, etc.)
-- Se declara aquí también para garantizar que exista antes de los índices RAG.
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- =============================================================================
-- SECCIÓN 2: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_fuente_rag AS ENUM (
    'manual',               -- Manual técnico de GNP (ej: Manual de Suscripción GMM)
    'requisitos',           -- Lista oficial de requisitos por producto y tipo de trámite
    'ejemplo_formulario',   -- Formulario GNP correctamente llenado (gold standard)
    'circular',             -- Circular o comunicado oficial de GNP con fecha de vigencia
    'politica_interna',     -- Política interna de la promotoría (no de GNP)
    'otro'
);

COMMENT ON TYPE tipo_fuente_rag IS
    'Tipo de documento origen del chunk en rag_gnp. '
    'Determina el peso y la confiabilidad del conocimiento.';


CREATE TYPE tipo_chunk_poliza AS ENUM (
    'validacion_exitosa',   -- Agente 5 validó todos los documentos del trámite
    'activacion_gnp',       -- GNP activó la póliza (puede repetirse en endosos)
    'aprobacion_final',     -- Trámite cerrado como aprobado
    'rechazo_gnp',          -- GNP rechazó — también genera chunk en rag_aprendizajes
    'endoso_procesado',     -- Endoso completado exitosamente
    'patron_detectado'      -- Patrón observado por el sistema en el historial de la póliza
);

COMMENT ON TYPE tipo_chunk_poliza IS
    'Tipo de evento que originó el chunk en rag_polizas. '
    'Permite filtrar el historial por tipo de evento.';


-- =============================================================================
-- SECCIÓN 3: TABLA rag_gnp — Conocimiento estático de GNP
-- =============================================================================
-- Fuente de verdad sobre requisitos, productos y procedimientos de GNP.
-- Curado manualmente via la app rag-ingest.
-- Se filtra por metadata (ramo, tipo_tramite, tipo_documento) ANTES del
-- vector search para reducir el espacio de búsqueda y aumentar la precisión.
-- =============================================================================

CREATE TABLE rag_gnp (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Vector embedding — corazón del RAG
    -- -------------------------------------------------------------------------
    -- text-embedding-3-small: 1536 dimensiones, normalizado (cosine ≈ dot product)
    -- NULL temporalmente durante el proceso de ingesta (chunk creado, embedding pendiente)
    embedding           vector(1536)    NULL,

    -- -------------------------------------------------------------------------
    -- Contenido del chunk
    -- -------------------------------------------------------------------------
    -- Texto del chunk listo para embeberse. Debe ser auto-contenido e incluir
    -- contexto en el texto mismo. Ejemplo:
    -- "[Ramo: GMM] [Trámite: Alta] [Vigente desde: 2024-01-01]
    --  Para el alta de una póliza de GMM se requieren los siguientes documentos:
    --  1. Solicitud de alta firmada por el contratante..."
    contenido           TEXT            NOT NULL,
    -- Hash SHA256 del contenido para detectar duplicados en re-ingestas
    hash_contenido      TEXT            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Metadata para pre-filtrado (SIEMPRE filtrar antes del vector search)
    -- -------------------------------------------------------------------------
    -- NULL = aplica a todos los ramos / tipos / documentos
    ramo                ramo_usuario    NULL,
    tipo_tramite        tipo_tramite    NULL,
    tipo_documento      tipo_documento  NULL,

    -- -------------------------------------------------------------------------
    -- Metadatos de la fuente
    -- -------------------------------------------------------------------------
    tipo_fuente         tipo_fuente_rag NOT NULL DEFAULT 'otro',
    titulo_fuente       TEXT            NOT NULL, -- ej: "Manual Suscripción GMM 2024"
    numero_pagina       SMALLINT        NULL,     -- página en el doc fuente
    seccion             TEXT            NULL,     -- sección o capítulo del documento

    -- -------------------------------------------------------------------------
    -- Control de vigencia — crítico para requisitos que cambian
    -- -------------------------------------------------------------------------
    vigente_desde       DATE            NULL,     -- cuándo entró en vigor este requisito
    vigente_hasta       DATE            NULL,     -- cuándo dejó de aplicar (NULL = aún vigente)
    -- Flag rápido para filtrar: WHERE vigente = TRUE sin calcular fechas en cada query
    vigente             BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Tags adicionales para búsqueda y filtrado semántico
    -- Ejemplos: ["suma_asegurada", "beneficiarios", "exclusiones", "espera"]
    tags                TEXT[]          NOT NULL DEFAULT '{}',

    -- Metadata flexible para datos adicionales del chunk
    -- Ej: { "numero_circular": "C-2024-042", "producto_gnp": "GMM Plus" }
    metadata            JSONB           NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Trazabilidad de la ingesta
    -- -------------------------------------------------------------------------
    -- Modelo de embedding usado — para saber cuándo re-embeberse
    version_embedding   TEXT            NULL,     -- ej: "text-embedding-3-small"
    -- Quién ingresó este chunk (usuario del rag-ingest)
    ingresado_por       UUID            NULL REFERENCES usuario(id),
    -- Quién validó que el contenido es correcto
    revisado_por        UUID            NULL REFERENCES usuario(id),
    -- Costo aproximado en tokens para análisis de costos
    num_tokens          INTEGER         NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_rag_gnp_hash UNIQUE (hash_contenido),

    CONSTRAINT ck_rag_gnp_vigencia CHECK (
        vigente_hasta IS NULL OR vigente_desde IS NULL
        OR vigente_hasta >= vigente_desde
    ),

    CONSTRAINT ck_rag_gnp_contenido CHECK (TRIM(contenido) <> ''),
    CONSTRAINT ck_rag_gnp_titulo    CHECK (TRIM(titulo_fuente) <> '')
);

COMMENT ON TABLE rag_gnp IS
    'Base de conocimiento estático de GNP: manuales, requisitos, formularios, circulares. '
    'Curado manualmente vía rag-ingest. Filtrar por ramo/tipo/vigente ANTES del vector search.';

COMMENT ON COLUMN rag_gnp.embedding        IS 'Vector 1536-dim (text-embedding-3-small). NULL durante ingesta hasta que se genere.';
COMMENT ON COLUMN rag_gnp.contenido        IS 'Texto del chunk enriquecido con contexto. Incluye metadata en el texto para mejor embedding.';
COMMENT ON COLUMN rag_gnp.hash_contenido   IS 'SHA256 del contenido. Previene chunks duplicados en re-ingestas.';
COMMENT ON COLUMN rag_gnp.vigente          IS 'Flag de búsqueda rápida. Siempre filtrar WHERE vigente = TRUE antes del vector search.';
COMMENT ON COLUMN rag_gnp.tags             IS 'Tags semánticos adicionales: ["exclusiones", "espera", "suma_asegurada", etc.].';
COMMENT ON COLUMN rag_gnp.version_embedding IS 'Modelo usado para generar el embedding. Cambiar si se migra de modelo.';


-- =============================================================================
-- SECCIÓN 4: TABLA rag_polizas — Historial dinámico de pólizas
-- =============================================================================
-- Se construye automáticamente conforme el Agente 5 procesa trámites.
-- Empieza VACÍO — no hay carga histórica inicial.
-- Con el tiempo construye un "diario de vida" por póliza que el Agente 5
-- usa para entender el contexto antes de validar un nuevo trámite.
-- =============================================================================

CREATE TABLE rag_poliza (
    id                  UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Vector embedding
    -- -------------------------------------------------------------------------
    embedding           vector(1536)        NULL,

    -- -------------------------------------------------------------------------
    -- Contenido del chunk — narrativa del evento
    -- -------------------------------------------------------------------------
    -- Texto narrativo generado por el Agente 5. Debe ser auto-contenido. Ejemplo:
    -- "Póliza 123456 (GMM Individual) - Agente: Juan García (CUA 1234567)
    --  Trámite TRM-2025-00042 procesado el 15/03/2025.
    --  Documentos: INE (vigente hasta 2028), Solicitud Alta GNP, Comprobante Domicilio.
    --  Resultado: 3 documentos válidos. GNP activó el 20/03/2025."
    contenido           TEXT                NOT NULL,

    -- -------------------------------------------------------------------------
    -- Vínculos con entidades del CRM
    -- -------------------------------------------------------------------------
    poliza_id           UUID                NULL REFERENCES poliza(id),
    tramite_id          UUID                NOT NULL REFERENCES tramite(id),
    -- Evento específico que originó este chunk (si aplica)
    tramite_evento_id   UUID                NULL REFERENCES tramite_evento(id),

    -- -------------------------------------------------------------------------
    -- Metadata para pre-filtrado
    -- -------------------------------------------------------------------------
    tipo_chunk          tipo_chunk_poliza   NOT NULL,
    -- Denormalizado del trámite para filtrar sin JOIN
    ramo                ramo_usuario        NULL,
    tipo_tramite        tipo_tramite        NULL,
    -- CUA del agente — permite buscar historial por agente
    agente_cua          TEXT                NULL,

    -- -------------------------------------------------------------------------
    -- Trazabilidad
    -- -------------------------------------------------------------------------
    version_embedding   TEXT                NULL,
    num_tokens          INTEGER             NULL,
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW()
    -- Sin updated_at — chunks inmutables una vez creados
);

COMMENT ON TABLE rag_poliza IS
    'Historial vectorial de pólizas. Se construye automáticamente por el Agente 5. '
    'Empieza vacío. Cada trámite significativo agrega un chunk narrativo. '
    'Chunks inmutables — append-only.';

COMMENT ON COLUMN rag_poliza.contenido        IS 'Narrativa del evento generada por el Agente 5. Auto-contenida para contexto de búsqueda.';
COMMENT ON COLUMN rag_poliza.tramite_id       IS 'Trámite que originó este chunk. NOT NULL — cada chunk tiene su tramite de origen.';
COMMENT ON COLUMN rag_poliza.agente_cua       IS 'CUA del agente denormalizado. Permite filtrar historial por agente sin JOIN.';


-- =============================================================================
-- SECCIÓN 5: TABLA rag_aprendizaje — Memoria de rechazos de GNP
-- =============================================================================
-- Cada rechazo de GNP genera un chunk de aprendizaje que explica:
--   - Qué salió mal (causa del rechazo)
--   - Por qué GNP lo rechazó (regla o criterio aplicado)
--   - Cómo se corrigió (si se resolvió)
--
-- El Agente 5 consulta esta tabla PRIMERO antes de validar un trámite,
-- para anticipar rechazos basándose en patrones históricos.
--
-- Los analistas validan los aprendizajes para filtrar los incorrectos
-- antes de que afecten futuras validaciones.
-- =============================================================================

CREATE TABLE rag_aprendizaje (
    id                      UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Vector embedding
    -- -------------------------------------------------------------------------
    embedding               vector(1536)        NULL,

    -- -------------------------------------------------------------------------
    -- Contenido del aprendizaje — el núcleo del diferenciador competitivo
    -- -------------------------------------------------------------------------
    -- Texto generado por el Agente 5 al recibir el rechazo. Debe explicar
    -- con suficiente detalle para que el Agente 5 evite el mismo error. Ejemplo:
    -- "RECHAZO GNP - Ramo: GMM - Alta (01/04/2025)
    --  Problema: INE del asegurado vencida al inicio de vigencia.
    --  Detalle: La póliza inicia el 01/04/2025. La INE presentada venció el 31/03/2025.
    --  Regla GNP: Los documentos de identidad deben estar vigentes AL MENOS durante
    --  todo el primer período de cobertura (generalmente 1 año).
    --  Lección: Verificar que fecha_vencimiento_INE > fecha_inicio_poliza + 365 días.
    --  Corrección: Se solicitó nueva INE. Aprobado el 05/04/2025."
    contenido               TEXT                NOT NULL,

    -- -------------------------------------------------------------------------
    -- Vínculos con el trámite origen
    -- -------------------------------------------------------------------------
    tramite_id              UUID                NOT NULL REFERENCES tramite(id),
    poliza_id               UUID                NULL REFERENCES poliza(id),
    -- Documento específico que causó el rechazo (si identificado)
    documento_id            UUID                NULL REFERENCES documento(id),

    -- -------------------------------------------------------------------------
    -- Metadata para pre-filtrado — más específica que rag_gnp
    -- -------------------------------------------------------------------------
    ramo                    ramo_usuario        NOT NULL,
    tipo_tramite            tipo_tramite        NULL,
    tipo_documento          tipo_documento      NULL,   -- qué tipo de doc causó el rechazo

    -- -------------------------------------------------------------------------
    -- Datos del rechazo GNP
    -- -------------------------------------------------------------------------
    codigo_rechazo_gnp      TEXT                NULL,   -- código oficial de GNP si lo provee
    motivo_rechazo          TEXT                NOT NULL, -- descripción legible del motivo
    -- Qué acción correctiva se tomó y cuál fue el resultado
    correccion_aplicada     TEXT                NULL,
    -- TRUE si el trámite fue finalmente aprobado después de la corrección
    resuelto                BOOLEAN             NOT NULL DEFAULT FALSE,
    fecha_resolucion        DATE                NULL,

    -- -------------------------------------------------------------------------
    -- Control de calidad del aprendizaje
    -- -------------------------------------------------------------------------
    -- FALSE = generado por IA, no validado. Se usa pero con menor peso.
    -- TRUE = validado por analista o gerente. Alta confiabilidad.
    aprendizaje_validado    BOOLEAN             NOT NULL DEFAULT FALSE,
    validado_por            UUID                NULL REFERENCES usuario(id),
    fecha_validacion        TIMESTAMPTZ         NULL,
    -- El analista puede marcar un aprendizaje como incorrecto para excluirlo
    descartado              BOOLEAN             NOT NULL DEFAULT FALSE,
    motivo_descarte         TEXT                NULL,

    -- Tags para búsqueda semántica adicional
    tags                    TEXT[]              NOT NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Trazabilidad
    -- -------------------------------------------------------------------------
    version_embedding       TEXT                NULL,
    num_tokens              INTEGER             NULL,
    created_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_rag_aprendizaje_contenido CHECK (TRIM(contenido) <> ''),
    CONSTRAINT ck_rag_aprendizaje_motivo    CHECK (TRIM(motivo_rechazo) <> ''),

    CONSTRAINT ck_rag_aprendizaje_validacion CHECK (
        NOT aprendizaje_validado
        OR (validado_por IS NOT NULL AND fecha_validacion IS NOT NULL)
    ),

    CONSTRAINT ck_rag_aprendizaje_descarte CHECK (
        NOT descartado OR motivo_descarte IS NOT NULL
    ),

    CONSTRAINT ck_rag_aprendizaje_resolucion CHECK (
        NOT resuelto OR fecha_resolucion IS NOT NULL
    ),

    -- Un aprendizaje no puede estar validado y descartado al mismo tiempo
    CONSTRAINT ck_rag_aprendizaje_estado CHECK (
        NOT (aprendizaje_validado AND descartado)
    )
);

COMMENT ON TABLE rag_aprendizaje IS
    'Memoria de rechazos GNP. El diferenciador competitivo del CRM: '
    'cada rechazo se convierte en conocimiento que previene futuros rechazos. '
    'El Agente 5 consulta esta tabla antes de validar para anticipar problemas.';

COMMENT ON COLUMN rag_aprendizaje.contenido             IS 'Narrativa completa del rechazo + causa + lección + corrección. Auto-contenida.';
COMMENT ON COLUMN rag_aprendizaje.aprendizaje_validado  IS 'TRUE = analista validó que el aprendizaje es correcto. FALSE = solo IA, menor confianza.';
COMMENT ON COLUMN rag_aprendizaje.descartado            IS 'TRUE = aprendizaje incorrecto o ruido, excluido del RAG. Requiere motivo.';
COMMENT ON COLUMN rag_aprendizaje.resuelto              IS 'TRUE = el rechazo fue superado y el trámite aprobado tras la corrección.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- rag_gnp — índice HNSW para vector search + índices de pre-filtrado
-- ---------------------------------------------------------------------------

-- Índice HNSW principal para similaridad coseno
-- Solo sobre chunks con embedding generado (vigente = TRUE implícito en queries)
CREATE INDEX idx_rag_gnp_embedding
    ON rag_gnp USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON INDEX idx_rag_gnp_embedding IS
    'HNSW coseno sobre rag_gnp. Parámetros: m=16 (conexiones), ef_construction=64 (calidad). '
    'PRE-FILTRAR por ramo/tipo/vigente ANTES de usar este índice.';

-- Pre-filtrado: vigente + ramo (la combinación más frecuente)
CREATE INDEX idx_rag_gnp_vigente_ramo
    ON rag_gnp (vigente, ramo)
    WHERE vigente = TRUE;

COMMENT ON INDEX idx_rag_gnp_vigente_ramo IS
    'Pre-filtrado antes del vector search: ramo específico con contenido vigente.';

-- Pre-filtrado: vigente + tipo_tramite + tipo_documento
CREATE INDEX idx_rag_gnp_filtros
    ON rag_gnp (vigente, ramo, tipo_tramite, tipo_documento)
    WHERE vigente = TRUE;

-- Búsqueda por tags (GIN para arrays)
CREATE INDEX idx_rag_gnp_tags
    ON rag_gnp USING gin (tags);

-- Búsqueda en metadata JSONB
CREATE INDEX idx_rag_gnp_metadata
    ON rag_gnp USING gin (metadata);

-- Chunks sin embedding (pendientes de procesar en la cola)
CREATE INDEX idx_rag_gnp_sin_embedding
    ON rag_gnp (created_at)
    WHERE embedding IS NULL;

COMMENT ON INDEX idx_rag_gnp_sin_embedding IS
    'Worker de embeddings consulta aquí los chunks pendientes de procesar.';


-- ---------------------------------------------------------------------------
-- rag_poliza — índice HNSW + pre-filtrado por poliza y tipo
-- ---------------------------------------------------------------------------

CREATE INDEX idx_rag_poliza_embedding
    ON rag_poliza USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Historial de una póliza específica ordenado por tiempo
CREATE INDEX idx_rag_poliza_poliza_ts
    ON rag_poliza (poliza_id, created_at DESC)
    WHERE poliza_id IS NOT NULL;

COMMENT ON INDEX idx_rag_poliza_poliza_ts IS
    'Recupera el historial completo de una póliza ordenado cronológicamente.';

-- Pre-filtrado por ramo y tipo para búsqueda de patrones similares
CREATE INDEX idx_rag_poliza_ramo_tipo
    ON rag_poliza (ramo, tipo_chunk, tipo_tramite);

-- Historial por CUA del agente
CREATE INDEX idx_rag_poliza_agente_cua
    ON rag_poliza (agente_cua)
    WHERE agente_cua IS NOT NULL;

-- Chunks sin embedding pendientes
CREATE INDEX idx_rag_poliza_sin_embedding
    ON rag_poliza (created_at)
    WHERE embedding IS NULL;


-- ---------------------------------------------------------------------------
-- rag_aprendizaje — índice HNSW + pre-filtrado por ramo y validación
-- ---------------------------------------------------------------------------

CREATE INDEX idx_rag_aprendizaje_embedding
    ON rag_aprendizaje USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Pre-filtrado principal: aprendizajes activos y no descartados por ramo
CREATE INDEX idx_rag_aprendizaje_activos
    ON rag_aprendizaje (ramo, tipo_tramite, tipo_documento)
    WHERE descartado = FALSE;

COMMENT ON INDEX idx_rag_aprendizaje_activos IS
    'El Agente 5 pre-filtra aprendizajes no descartados por ramo/tipo antes del vector search.';

-- Aprendizajes validados por humanos (mayor confiabilidad)
CREATE INDEX idx_rag_aprendizaje_validados
    ON rag_aprendizaje (ramo, aprendizaje_validado)
    WHERE aprendizaje_validado = TRUE AND descartado = FALSE;

-- Pendientes de validación humana (para dashboard del analista/gerente)
CREATE INDEX idx_rag_aprendizaje_pendientes_validacion
    ON rag_aprendizaje (ramo, created_at DESC)
    WHERE aprendizaje_validado = FALSE AND descartado = FALSE;

COMMENT ON INDEX idx_rag_aprendizaje_pendientes_validacion IS
    'Dashboard: aprendizajes generados por IA que esperan validación humana.';

-- Aprendizajes por trámite origen
CREATE INDEX idx_rag_aprendizaje_tramite
    ON rag_aprendizaje (tramite_id);

-- Tags para búsqueda adicional
CREATE INDEX idx_rag_aprendizaje_tags
    ON rag_aprendizaje USING gin (tags);

-- Chunks sin embedding pendientes
CREATE INDEX idx_rag_aprendizaje_sin_embedding
    ON rag_aprendizaje (created_at)
    WHERE embedding IS NULL;


-- =============================================================================
-- SECCIÓN 7: TRIGGERS
-- =============================================================================

-- updated_at para rag_gnp y rag_aprendizaje (rag_poliza es inmutable)
CREATE TRIGGER trg_rag_gnp_updated_at
    BEFORE UPDATE ON rag_gnp
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_rag_aprendizaje_updated_at
    BEFORE UPDATE ON rag_aprendizaje
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- Trigger: cuando un aprendizaje se valida, registrar automáticamente quién y cuándo
CREATE OR REPLACE FUNCTION registrar_validacion_aprendizaje()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.aprendizaje_validado = TRUE AND OLD.aprendizaje_validado = FALSE THEN
        NEW.validado_por     := auth.uid();
        NEW.fecha_validacion := NOW();
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_validacion_aprendizaje() IS
    'Al marcar un aprendizaje como validado, auto-registra quién lo validó y cuándo. '
    'El analista solo necesita hacer UPDATE aprendizaje_validado = TRUE.';

CREATE TRIGGER trg_rag_aprendizaje_validacion
    BEFORE UPDATE OF aprendizaje_validado ON rag_aprendizaje
    FOR EACH ROW
    EXECUTE FUNCTION registrar_validacion_aprendizaje();


-- =============================================================================
-- SECCIÓN 8: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--
--   rag_gnp:
--     SELECT: todos los autenticados (el Agente 5 necesita leer para validar)
--     INSERT/UPDATE: solo directores y la app rag-ingest (service_role)
--     El campo 'vigente' se puede desactivar por gerentes para retirar contenido
--
--   rag_poliza:
--     SELECT: el analista ve chunks de pólizas que puede ver; directores ven todo
--     INSERT: solo service_role (Agente 5 via Celery) — los chunks son inmutables
--     No UPDATE, no DELETE
--
--   rag_aprendizaje:
--     SELECT: todos los autenticados (filtrado por ramo para gerentes/analistas)
--     INSERT: solo service_role (Agente 5)
--     UPDATE: analistas/gerentes pueden validar o descartar (campos específicos)
-- =============================================================================

ALTER TABLE rag_gnp          ENABLE ROW LEVEL SECURITY;
ALTER TABLE rag_poliza        ENABLE ROW LEVEL SECURITY;
ALTER TABLE rag_aprendizaje  ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------------
-- POLICIES: rag_gnp
-- ---------------------------------------------------------------------------

-- Todos leen el conocimiento de GNP (el Agente 5 lo necesita)
CREATE POLICY pol_rag_gnp_select
    ON rag_gnp FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_rag_gnp_select ON rag_gnp IS
    'Todos los usuarios autenticados pueden leer el conocimiento de GNP. '
    'El Agente 5 consulta esta tabla para validar documentos.';

-- Solo directores gestionan el contenido de GNP desde la app
-- (la app rag-ingest usa service_role y no necesita policy)
CREATE POLICY pol_rag_gnp_insert
    ON rag_gnp FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_rag_gnp_update
    ON rag_gnp FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));


-- ---------------------------------------------------------------------------
-- POLICIES: rag_poliza
-- ---------------------------------------------------------------------------

-- Directores ven todo el historial
CREATE POLICY pol_rag_poliza_select_director
    ON rag_poliza FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

-- Gerente ve chunks de pólizas de su ramo
CREATE POLICY pol_rag_poliza_select_gerente
    ON rag_poliza FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (ramo IS NULL OR ramo::text = auth_ramo())
    );

-- Analista ve chunks de sus trámites y pólizas asignadas
CREATE POLICY pol_rag_poliza_select_analista
    ON rag_poliza FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND (
            EXISTS (
                SELECT 1 FROM tramite t
                WHERE t.id = tramite_id
                  AND t.analista_id = auth.uid()
            )
        )
    );

-- INSERT: solo service_role (Agente 5 via Celery) — no se expone a authenticated
-- No UPDATE, no DELETE: chunks inmutables


-- ---------------------------------------------------------------------------
-- POLICIES: rag_aprendizaje
-- ---------------------------------------------------------------------------

-- Directores ven todos los aprendizajes
CREATE POLICY pol_rag_aprendizaje_select_director
    ON rag_aprendizaje FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

-- Gerente ve aprendizajes de su ramo (incluyendo no validados para revisarlos)
CREATE POLICY pol_rag_aprendizaje_select_gerente
    ON rag_aprendizaje FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

-- Analista ve aprendizajes validados y no descartados de su ramo
-- (excluye los pendientes de validación para no generar ruido)
CREATE POLICY pol_rag_aprendizaje_select_analista
    ON rag_aprendizaje FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND ramo::text = auth_ramo()
        AND descartado = FALSE
    );

-- UPDATE: analistas y gerentes pueden validar o descartar aprendizajes de su ramo
CREATE POLICY pol_rag_aprendizaje_update_validacion
    ON rag_aprendizaje FOR UPDATE TO authenticated
    USING (
        ramo::text = auth_ramo()
        AND auth_rol() IN ('gerente', 'analista', 'director_general', 'director_ops')
        AND descartado = FALSE
    )
    WITH CHECK (
        ramo::text = auth_ramo()
        OR auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_rag_aprendizaje_update_validacion ON rag_aprendizaje IS
    'Analistas y gerentes validan o descartan aprendizajes de su ramo. '
    'El trigger registra automáticamente quién validó y cuándo.';

-- INSERT: solo service_role (Agente 5) — no se expone a authenticated


-- =============================================================================
-- SECCIÓN 9: GRANTS
-- =============================================================================

GRANT SELECT ON TABLE rag_gnp TO authenticated;
GRANT INSERT, UPDATE (
    vigente, vigente_hasta, tags, metadata, revisado_por, updated_at
) ON TABLE rag_gnp TO authenticated;

GRANT SELECT ON TABLE rag_poliza TO authenticated;
-- Sin INSERT/UPDATE para authenticated — solo service_role

GRANT SELECT ON TABLE rag_aprendizaje TO authenticated;
GRANT UPDATE (
    aprendizaje_validado, descartado, motivo_descarte, tags, updated_at
) ON TABLE rag_aprendizaje TO authenticated;
-- INSERT solo service_role

GRANT EXECUTE ON FUNCTION registrar_validacion_aprendizaje() TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000005_modulo_06_rag.sql
-- =============================================================================

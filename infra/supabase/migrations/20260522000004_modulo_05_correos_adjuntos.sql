-- =============================================================================
-- Migración: 20260522000004_modulo_05_correos_adjuntos.sql
-- Módulo 5 — Correos, Adjuntos y Documentos del CRM Olimpo
-- =============================================================================
-- Cuatro tablas con responsabilidades distintas:
--
--   correo          → Registro de emails entrantes y salientes (Gmail API).
--                     El message_id de Gmail es la clave de idempotencia.
--
--   correo_tramite  → Junction many-to-many: un correo puede generar múltiples
--                     trámites; un trámite puede tener múltiples correos.
--
--   adjunto         → Archivos físicos del correo (PDFs, imágenes, ZIPs).
--                     Los ZIPs descomprimidos generan adjuntos hijos via
--                     adjunto_padre_id. Las contraseñas son TEMPORALES.
--
--   documento       → Resultado del OCR + clasificación por el Agente 3.
--                     Datos estructurados extraídos, tipo de documento,
--                     confianza, estado de validación por el Agente 5.
--
-- Flujo de un correo entrante:
--   Gmail → correo (recibido) →
--   Agente 1: adjuntos extraídos, ZIPs descomprimidos, passwords eliminados →
--   Agente 2: cuerpo analizado, datos extraídos, tramite creado →
--   Agente 3: OCR + clasificación → documentos creados →
--   Agente 4: correo_tramite vinculado, tramite asignado →
--   Agente 5: documentos validados →
--   Agente 6: correo saliente (borrador) creado
--
-- Relaciones con módulos anteriores:
--   correo_tramite.tramite_id → tramite.id   (Módulo 4)
--   correo.analista_id        → usuario.id   (Módulo 1)
--   documento.tramite_id      → tramite.id   (Módulo 4)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_correo AS ENUM (
    'entrante',   -- recibido desde agente/asistente vía Gmail BCC/DWD
    'saliente'    -- generado por Agente 6, revisado y enviado por analista
);

COMMENT ON TYPE tipo_correo IS
    'Dirección del correo. entrante: llega de agentes/asistentes. '
    'saliente: generado por el Agente 6 y enviado por el analista.';


CREATE TYPE estado_correo AS ENUM (
    -- Ciclo de vida de correos ENTRANTES
    'recibido',               -- llegó de Gmail, aún sin procesar
    'procesando',             -- pipeline Agentes 1-4 corriendo
    'procesado',              -- pipeline completado, trámite creado/vinculado
    'error_procesamiento',    -- pipeline falló, requiere revisión manual

    -- Ciclo de vida de correos SALIENTES (Agente 6)
    'borrador',               -- Agente 6 lo generó, pendiente de revisión
    'en_revision',            -- analista está revisando el borrador
    'aprobado',               -- analista aprobó, listo para enviar
    'enviado',                -- enviado vía Gmail API exitosamente
    'error_envio'             -- fallo en el envío, reintentando o requiere atención
);

COMMENT ON TYPE estado_correo IS
    'Estado del correo según su tipo. '
    'Entrantes: recibido→procesando→procesado. '
    'Salientes: borrador→en_revision→aprobado→enviado.';


CREATE TYPE estado_adjunto AS ENUM (
    'pendiente',    -- recién registrado, en cola para Agente 1
    'procesando',   -- Agente 1 extrayendo/descomprimiendo
    'procesado',    -- listo para OCR (Agente 3)
    'ilegible',     -- corrompido, formato no soportado
    'error'         -- error técnico durante el procesamiento
);

COMMENT ON TYPE estado_adjunto IS
    'Estado del adjunto en el pipeline del Agente 1.';


-- Tipos de documento reconocidos por GNP y el sistema
-- Se puede extender con ALTER TYPE ... ADD VALUE sin downtime
CREATE TYPE tipo_documento AS ENUM (
    -- Identificación personal
    'ine',                    -- Credencial para votar / INE
    'pasaporte',
    'acta_nacimiento',
    'curp',
    'comprobante_domicilio',

    -- Documentos de trámite GNP
    'solicitud_alta',         -- Solicitud de alta de póliza
    'formulario_gnp',         -- Cualquier forma oficial de GNP
    'carta_medica',           -- Carta médica (GMM, vida)
    'dictamen_medico',        -- Dictamen médico especializado
    'cuestionario_salud',     -- Cuestionario de salud (GMM, vida)
    'poliza_anterior',        -- Póliza anterior para renovaciones
    'endoso',                 -- Documento de endoso

    -- Documentos para autos
    'tarjeta_circulacion',
    'factura_vehiculo',
    'fotografia_vehiculo',

    -- Documentos para pyme / persona moral
    'acta_constitutiva',
    'poder_notarial',
    'cedula_fiscal',          -- Cédula de identificación fiscal
    'estado_cuenta',          -- Estado de cuenta bancario

    -- Documentos financieros
    'comprobante_pago',
    'recibo_prima',

    'otro'                    -- No clasificado o tipo no reconocido
);

COMMENT ON TYPE tipo_documento IS
    'Tipos de documento reconocidos por GNP. '
    'Usar ALTER TYPE ADD VALUE para agregar nuevos tipos sin migración completa.';


CREATE TYPE estado_validacion_documento AS ENUM (
    'pendiente_validacion',   -- Agente 5 aún no lo ha revisado
    'valido',                 -- Cumple requisitos GNP para este trámite
    'invalido',               -- No cumple (incompleto, mal llenado, tipo incorrecto)
    'ilegible',               -- OCR falló o calidad insuficiente
    'vencido',                -- Documento expirado (ej: INE caducada)
    'duplicado'               -- Ya existe un documento de este tipo en el trámite
);

COMMENT ON TYPE estado_validacion_documento IS
    'Resultado de la validación del Agente 5 contra requisitos GNP.';


-- =============================================================================
-- SECCIÓN 2: TABLA correo
-- =============================================================================

CREATE TABLE correo (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identificadores Gmail — clave de idempotencia
    -- -------------------------------------------------------------------------
    -- ID único del mensaje en Gmail. Previene procesar el mismo correo dos veces.
    -- NULL solo para correos salientes creados en el CRM (no tienen message_id aún).
    message_id      TEXT            NULL,
    -- ID del hilo de conversación en Gmail. Agrupa correos relacionados.
    thread_id       TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Clasificación
    -- -------------------------------------------------------------------------
    tipo            tipo_correo     NOT NULL,
    estado          estado_correo   NOT NULL DEFAULT 'recibido',

    -- -------------------------------------------------------------------------
    -- Cabeceras del correo
    -- -------------------------------------------------------------------------
    de_email        TEXT            NOT NULL,
    de_nombre       TEXT            NULL,
    -- Arrays para múltiples destinatarios
    para_emails     TEXT[]          NOT NULL DEFAULT '{}',
    cc_emails       TEXT[]          NOT NULL DEFAULT '{}',
    asunto          TEXT            NOT NULL DEFAULT '',

    -- -------------------------------------------------------------------------
    -- Cuerpo del correo
    -- -------------------------------------------------------------------------
    -- HTML del correo — para correos salientes incluye la firma del analista
    cuerpo_html     TEXT            NULL,
    -- Texto plano — extraído para el Agente 2 y como fallback de lectura
    cuerpo_texto    TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Fechas
    -- -------------------------------------------------------------------------
    -- Fecha real del correo (del header Date:, no de cuando se insertó en DB)
    fecha_correo    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- Para salientes: cuándo se envió exitosamente vía Gmail API
    fecha_envio     TIMESTAMPTZ     NULL,

    -- -------------------------------------------------------------------------
    -- Actor para correos salientes
    -- -------------------------------------------------------------------------
    -- Analista que aprobó y disparó el envío del borrador del Agente 6
    analista_id     UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Datos extraídos por el Agente 2 (entrantes)
    -- -------------------------------------------------------------------------
    -- Resultado estructurado del análisis del cuerpo por el Agente 2.
    -- Ejemplos: { "tipo_tramite_detectado": "alta", "confianza": 0.91,
    --             "numero_poliza_mencionado": "...", "ramo_detectado": "gmm" }
    datos_agente2   JSONB           NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- message_id único: previene duplicados del mismo correo de Gmail
    CONSTRAINT uq_correo_message_id UNIQUE (message_id),

    -- Solo correos entrantes tienen message_id; salientes lo reciben al enviarse
    CONSTRAINT ck_correo_message_id CHECK (
        tipo = 'saliente' OR message_id IS NOT NULL
    ),

    -- Fecha de envío solo para correos enviados
    CONSTRAINT ck_correo_fecha_envio CHECK (
        fecha_envio IS NULL OR estado = 'enviado'
    ),

    CONSTRAINT ck_correo_de_email CHECK (TRIM(de_email) <> '')
);

COMMENT ON TABLE correo IS
    'Registro central de todos los correos del CRM: entrantes (Gmail BCC/DWD) '
    'y salientes (borradores del Agente 6 enviados por el analista). '
    'message_id de Gmail es la clave de idempotencia para correos entrantes.';

COMMENT ON COLUMN correo.message_id   IS 'ID único de Gmail. UNIQUE — previene procesar el mismo correo dos veces.';
COMMENT ON COLUMN correo.thread_id    IS 'Hilo de conversación de Gmail. Permite agrupar intercambios relacionados.';
COMMENT ON COLUMN correo.datos_agente2 IS 'Salida estructurada del Agente 2: tipo de trámite detectado, confianzas, entidades extraídas.';
COMMENT ON COLUMN correo.analista_id  IS 'Solo para correos salientes: analista que revisó y aprobó el borrador del Agente 6.';


-- =============================================================================
-- SECCIÓN 3: TABLA correo_tramite — junction correo ↔ trámite
-- =============================================================================
-- Un correo puede dar origen a múltiples trámites (ej: un email con
-- renovaciones de 3 pólizas distintas).
-- Un trámite acumula múltiples correos a lo largo de su vida.
-- =============================================================================

CREATE TABLE correo_tramite (
    correo_id       UUID        NOT NULL REFERENCES correo(id)  ON DELETE CASCADE,
    tramite_id      UUID        NOT NULL REFERENCES tramite(id) ON DELETE CASCADE,
    -- Indica si este correo fue el que originó el trámite (vs. correos posteriores)
    es_origen       BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (correo_id, tramite_id)
);

COMMENT ON TABLE correo_tramite IS
    'Junction many-to-many entre correos y trámites. '
    'es_origen = TRUE marca el correo que dio origen al trámite.';

COMMENT ON COLUMN correo_tramite.es_origen IS
    'TRUE solo para el correo que generó el trámite. '
    'Los correos posteriores del mismo hilo tienen es_origen = FALSE.';


-- =============================================================================
-- SECCIÓN 4: TABLA adjunto — archivos físicos del correo
-- =============================================================================
-- Cada archivo adjunto al correo tiene un registro aquí.
-- Los ZIPs descomprimidos generan registros hijos con adjunto_padre_id.
-- Las contraseñas ZIP son TEMPORALES: se guardan, se usan y se eliminan.
-- =============================================================================

CREATE TABLE adjunto (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- FK al correo del que proviene este adjunto
    correo_id           UUID            NOT NULL REFERENCES correo(id) ON DELETE CASCADE,

    -- Self-reference para archivos extraídos de un ZIP.
    -- NULL = archivo directo del correo.
    -- NOT NULL = fue extraído de un ZIP (su padre).
    adjunto_padre_id    UUID            NULL REFERENCES adjunto(id) ON DELETE CASCADE,

    -- -------------------------------------------------------------------------
    -- Metadatos del archivo
    -- -------------------------------------------------------------------------
    nombre_archivo      TEXT            NOT NULL,
    tipo_mime           TEXT            NULL,   -- ej: "application/pdf", "image/jpeg"
    tamanio_bytes       BIGINT          NULL,   -- NULL si no se pudo determinar
    -- Ruta en Supabase Storage: /tramites/{tramite_id}/correos/{correo_id}/{adjunto_id}
    storage_path        TEXT            NULL,   -- NULL hasta que el archivo se suba a Storage

    -- -------------------------------------------------------------------------
    -- Contraseña ZIP — CAMPO TEMPORAL Y SENSIBLE
    -- -------------------------------------------------------------------------
    -- El Agente 1 guarda aquí la contraseña encontrada en el correo.
    -- Se usa para descomprimir y se borra INMEDIATAMENTE después.
    -- Solo accesible vía service_role — authenticated NO tiene GRANT en esta columna.
    password            TEXT            NULL,
    -- TRUE confirma que la contraseña fue usada y eliminada. Auditoría de seguridad.
    password_eliminado  BOOLEAN         NOT NULL DEFAULT FALSE,

    -- -------------------------------------------------------------------------
    -- Estado en el pipeline del Agente 1
    -- -------------------------------------------------------------------------
    estado              estado_adjunto  NOT NULL DEFAULT 'pendiente',
    -- Razón del error si estado = 'error' o 'ilegible'
    motivo_error        TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_adjunto_nombre CHECK (TRIM(nombre_archivo) <> ''),

    -- La contraseña solo puede estar si el password no fue eliminado aún
    CONSTRAINT ck_adjunto_password CHECK (
        NOT (password IS NOT NULL AND password_eliminado = TRUE)
    ),

    -- Un archivo no puede ser su propio padre
    CONSTRAINT ck_adjunto_no_autoreferencia CHECK (
        adjunto_padre_id IS NULL OR adjunto_padre_id <> id
    )
);

COMMENT ON TABLE adjunto IS
    'Archivos adjuntos de los correos. Los ZIPs descomprimidos tienen adjunto_padre_id. '
    'El campo password es TEMPORAL y SENSIBLE — solo accesible vía service_role.';

COMMENT ON COLUMN adjunto.adjunto_padre_id  IS 'FK al ZIP origen. NULL para archivos directos del correo.';
COMMENT ON COLUMN adjunto.storage_path      IS 'Ruta en Supabase Storage: /tramites/{tramite_id}/correos/{correo_id}/{adjunto_id}.';
COMMENT ON COLUMN adjunto.password          IS 'Contraseña ZIP TEMPORAL. Solo service_role. Debe ser NULL después del procesamiento.';
COMMENT ON COLUMN adjunto.password_eliminado IS 'Confirma que la contraseña fue eliminada. Inmutable una vez en TRUE.';


-- =============================================================================
-- SECCIÓN 5: TABLA documento — resultado OCR + clasificación (Agente 3)
-- =============================================================================
-- Representa el resultado del procesamiento de un adjunto:
--   - Qué tipo de documento es (clasificación)
--   - Qué texto contiene (OCR)
--   - Qué datos estructurados se extrajeron (JSONB)
--   - Si es válido para el trámite (validación del Agente 5)
--
-- Un adjunto genera un documento por tramite al que está vinculado.
-- =============================================================================

CREATE TABLE documento (
    id                      UUID                        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Adjunto origen — el archivo físico procesado
    adjunto_id              UUID                        NOT NULL REFERENCES adjunto(id),
    -- Trámite al que pertenece esta validación del documento
    tramite_id              UUID                        NOT NULL REFERENCES tramite(id),

    -- -------------------------------------------------------------------------
    -- Clasificación (Agente 3)
    -- -------------------------------------------------------------------------
    tipo_documento          tipo_documento              NOT NULL DEFAULT 'otro',
    -- Confianza del modelo en la clasificación del tipo (0-1)
    confianza_clasificacion NUMERIC(4, 3)               NULL CHECK (confianza_clasificacion BETWEEN 0 AND 1),

    -- -------------------------------------------------------------------------
    -- OCR (Agente 3 — Phi-3/Mistral en RunPod, Google Vision como fallback)
    -- -------------------------------------------------------------------------
    -- Texto completo extraído por OCR. Almacenado en DB para consultas directas
    -- y para construcción de chunks RAG. Documentos de seguros raramente superan 20KB.
    texto_ocr               TEXT                        NULL,
    -- Confianza del OCR (0-1). Bajo 0.70 → Agente 3 intenta con modelo alternativo.
    confianza_ocr           NUMERIC(4, 3)               NULL CHECK (confianza_ocr BETWEEN 0 AND 1),
    -- Modelo que realizó el OCR exitosamente
    modelo_ocr              TEXT                        NULL,   -- 'phi3', 'mistral', 'google_vision'
    -- Número de intentos de OCR (para auditoría y optimización de costos)
    intentos_ocr            SMALLINT                    NOT NULL DEFAULT 0,

    -- -------------------------------------------------------------------------
    -- Datos estructurados extraídos (Agente 3)
    -- -------------------------------------------------------------------------
    -- Campos clave extraídos del documento según su tipo. Estructura varía:
    --
    --   tipo_documento = 'ine':
    --     { "nombre": "...", "curp": "...", "fecha_nacimiento": "...",
    --       "fecha_vencimiento": "...", "clave_elector": "..." }
    --
    --   tipo_documento = 'solicitud_alta':
    --     { "contratante": "...", "rfc": "...", "suma_asegurada": 500000,
    --       "inicio_vigencia": "...", "tipo_cobertura": "amplia" }
    --
    --   tipo_documento = 'tarjeta_circulacion':
    --     { "vin": "...", "placas": "...", "marca": "...", "modelo": "...", "anio": 2023 }
    datos_extraidos         JSONB                       NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Vigencia del documento (Agente 3 extrae, Agente 5 valida)
    -- -------------------------------------------------------------------------
    -- Fecha de vencimiento si el documento expira (INE, comprobante domicilio, etc.)
    vigente_hasta           DATE                        NULL,

    -- -------------------------------------------------------------------------
    -- Validación (Agente 5)
    -- -------------------------------------------------------------------------
    estado_validacion       estado_validacion_documento NOT NULL DEFAULT 'pendiente_validacion',
    -- Por qué el documento es inválido o ilegible — texto para el analista y el RAG
    motivo_invalidez        TEXT                        NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at              TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Un adjunto no puede tener dos documentos del mismo tipo en el mismo trámite
    CONSTRAINT uq_documento_adjunto_tramite UNIQUE (adjunto_id, tramite_id),

    -- motivo_invalidez solo aplica cuando el estado lo justifica
    CONSTRAINT ck_documento_motivo CHECK (
        motivo_invalidez IS NULL
        OR estado_validacion IN ('invalido', 'ilegible', 'vencido', 'duplicado')
    ),

    -- vigente_hasta solo tiene sentido para documentos válidos o que expiraron
    CONSTRAINT ck_documento_vigencia CHECK (
        vigente_hasta IS NULL
        OR tipo_documento IN (
            'ine', 'pasaporte', 'comprobante_domicilio',
            'carta_medica', 'poder_notarial', 'estado_cuenta'
        )
    )
);

COMMENT ON TABLE documento IS
    'Resultado del procesamiento OCR + clasificación del Agente 3 sobre un adjunto. '
    'Incluye el texto OCR completo (para RAG), datos estructurados extraídos, '
    'y el resultado de validación del Agente 5.';

COMMENT ON COLUMN documento.texto_ocr           IS 'Texto completo extraído por OCR. Alimenta el RAG y la validación del Agente 5.';
COMMENT ON COLUMN documento.datos_extraidos     IS 'Campos clave estructurados según tipo_documento. El Agente 3 los escribe, el Agente 4 los lee.';
COMMENT ON COLUMN documento.confianza_ocr       IS 'Confianza OCR (0-1). < 0.70 activa fallback a modelo alternativo o Google Vision.';
COMMENT ON COLUMN documento.vigente_hasta       IS 'Fecha de vencimiento del documento. El Agente 5 la compara con fecha_recepcion del trámite.';
COMMENT ON COLUMN documento.estado_validacion   IS 'Resultado del Agente 5. Determina si el trámite pasa a completo o pendiente_documentos.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- correo
CREATE INDEX idx_correo_thread
    ON correo (thread_id)
    WHERE thread_id IS NOT NULL;

COMMENT ON INDEX idx_correo_thread IS
    'Agrupa correos del mismo hilo de conversación Gmail.';

CREATE INDEX idx_correo_tipo_estado
    ON correo (tipo, estado);

CREATE INDEX idx_correo_fecha
    ON correo (fecha_correo DESC);

CREATE INDEX idx_correo_de_email
    ON correo (de_email);

COMMENT ON INDEX idx_correo_de_email IS
    'El Agente 4 busca el remitente aquí en el cascade de identificación.';

CREATE INDEX idx_correo_analista
    ON correo (analista_id)
    WHERE analista_id IS NOT NULL;

-- Para detectar correos salientes pendientes de envío (dashboard del analista)
CREATE INDEX idx_correo_borradores
    ON correo (analista_id, estado)
    WHERE tipo = 'saliente' AND estado IN ('borrador', 'en_revision', 'aprobado');

-- correo_tramite
CREATE INDEX idx_correo_tramite_tramite
    ON correo_tramite (tramite_id);

CREATE INDEX idx_correo_tramite_correo
    ON correo_tramite (correo_id);

-- Para encontrar el correo origen de un trámite
CREATE INDEX idx_correo_tramite_origen
    ON correo_tramite (tramite_id)
    WHERE es_origen = TRUE;

-- adjunto
CREATE INDEX idx_adjunto_correo
    ON adjunto (correo_id);

CREATE INDEX idx_adjunto_padre
    ON adjunto (adjunto_padre_id)
    WHERE adjunto_padre_id IS NOT NULL;

CREATE INDEX idx_adjunto_estado
    ON adjunto (estado)
    WHERE estado IN ('pendiente', 'procesando');

COMMENT ON INDEX idx_adjunto_estado IS
    'El Agente 1 consulta adjuntos pendientes de procesar.';

-- Para auditoría de seguridad: adjuntos con password sin eliminar
CREATE INDEX idx_adjunto_password_pendiente
    ON adjunto (correo_id)
    WHERE password IS NOT NULL AND password_eliminado = FALSE;

COMMENT ON INDEX idx_adjunto_password_pendiente IS
    'Auditoría: adjuntos con contraseña ZIP sin eliminar. Debe estar vacío en operación normal.';

-- documento
CREATE INDEX idx_documento_tramite
    ON documento (tramite_id);

CREATE INDEX idx_documento_adjunto
    ON documento (adjunto_id);

CREATE INDEX idx_documento_tipo_validacion
    ON documento (tramite_id, tipo_documento, estado_validacion);

COMMENT ON INDEX idx_documento_tipo_validacion IS
    'El Agente 5 consulta documentos de un trámite por tipo y estado de validación.';

-- Para el RAG: búsqueda de texto en documentos
CREATE INDEX idx_documento_texto_ocr
    ON documento USING gin (to_tsvector('spanish', COALESCE(texto_ocr, '')));

COMMENT ON INDEX idx_documento_texto_ocr IS
    'Búsqueda full-text en texto OCR en español. Alimenta el RAG de pólizas.';

-- Para el RAG: búsqueda en datos extraídos (JSONB)
CREATE INDEX idx_documento_datos
    ON documento USING gin (datos_extraidos);

CREATE INDEX idx_documento_vencidos
    ON documento (vigente_hasta)
    WHERE vigente_hasta IS NOT NULL AND estado_validacion = 'pendiente_validacion';

COMMENT ON INDEX idx_documento_vencidos IS
    'El Agente 5 detecta documentos próximos a vencer antes de validar.';


-- =============================================================================
-- SECCIÓN 7: TRIGGERS — updated_at
-- =============================================================================
-- set_updated_at() ya existe desde migración 20260522000000.

CREATE TRIGGER trg_correo_updated_at
    BEFORE UPDATE ON correo
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_adjunto_updated_at
    BEFORE UPDATE ON adjunto
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_documento_updated_at
    BEFORE UPDATE ON documento
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 8: TRIGGER — Protección de password_eliminado (inmutable en TRUE)
-- =============================================================================
-- Una vez que password_eliminado = TRUE, no puede volver a FALSE.
-- La contraseña eliminada no puede restaurarse.
-- =============================================================================

CREATE OR REPLACE FUNCTION proteger_password_eliminado()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.password_eliminado = TRUE AND NEW.password_eliminado = FALSE THEN
        RAISE EXCEPTION
            'No se puede revertir password_eliminado a FALSE. '
            'Una vez eliminada la contraseña ZIP, el campo es inmutable.';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION proteger_password_eliminado() IS
    'Impide revertir password_eliminado de TRUE a FALSE. '
    'Garantiza que la eliminación de contraseñas ZIP sea irreversible.';

CREATE TRIGGER trg_adjunto_proteger_password
    BEFORE UPDATE OF password_eliminado ON adjunto
    FOR EACH ROW
    EXECUTE FUNCTION proteger_password_eliminado();


-- =============================================================================
-- SECCIÓN 9: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--   correo y adjunto: visibilidad heredada de los trámites vinculados.
--   documento: misma visibilidad que su trámite.
--   correo_tramite: visible si el usuario puede ver el trámite o el correo.
--
-- El campo adjunto.password NUNCA es visible para authenticated:
--   Se usa GRANT a nivel de columna para excluirlo del acceso estándar.
--   Solo service_role (los agentes IA) pueden leer y escribir ese campo.
-- =============================================================================

ALTER TABLE correo          ENABLE ROW LEVEL SECURITY;
ALTER TABLE correo_tramite  ENABLE ROW LEVEL SECURITY;
ALTER TABLE adjunto         ENABLE ROW LEVEL SECURITY;
ALTER TABLE documento       ENABLE ROW LEVEL SECURITY;


-- Función auxiliar reutilizable: ¿puede el usuario actual ver este trámite?
-- Evita repetir la lógica de visibilidad en cada policy.
CREATE OR REPLACE FUNCTION puede_ver_tramite(p_tramite_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT EXISTS (
        SELECT 1 FROM tramite t
        WHERE t.id = p_tramite_id
          AND (
            auth_rol() IN ('director_general', 'director_ops')
            OR (auth_rol() = 'gerente'
                AND (t.gerente_id = auth.uid()
                     OR (t.ramo IS NOT NULL AND t.ramo::text = auth_ramo())))
            OR (auth_rol() = 'analista' AND t.analista_id = auth.uid())
          )
    )
$$;

COMMENT ON FUNCTION puede_ver_tramite(UUID) IS
    'Verifica si el usuario autenticado puede ver un trámite dado. '
    'Centraliza la lógica de visibilidad para usarla en policies de tablas secundarias.';


-- -----------------------------------------------------------------------------
-- POLICIES: correo
-- Un correo es visible si el usuario puede ver AL MENOS UNO de sus trámites
-- vinculados, o si es un correo saliente del propio analista.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_correo_select_director
    ON correo FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_correo_select_via_tramite
    ON correo FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('gerente', 'analista')
        AND EXISTS (
            SELECT 1 FROM correo_tramite ct
            WHERE ct.correo_id = id
              AND puede_ver_tramite(ct.tramite_id)
        )
    );

-- Un analista puede ver sus propios correos salientes aunque no tengan trámite aún
CREATE POLICY pol_correo_select_propio_saliente
    ON correo FOR SELECT TO authenticated
    USING (
        tipo = 'saliente'
        AND analista_id = auth.uid()
    );

-- INSERT: analistas, gerentes y directores pueden crear borradores
CREATE POLICY pol_correo_insert
    ON correo FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- UPDATE: directores actualizan cualquiera; analistas solo sus borradores
CREATE POLICY pol_correo_update_director
    ON correo FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_correo_update_analista
    ON correo FOR UPDATE TO authenticated
    USING (tipo = 'saliente' AND analista_id = auth.uid() AND estado IN ('borrador', 'en_revision'))
    WITH CHECK (tipo = 'saliente' AND analista_id = auth.uid());


-- -----------------------------------------------------------------------------
-- POLICIES: correo_tramite
-- -----------------------------------------------------------------------------

CREATE POLICY pol_correo_tramite_select
    ON correo_tramite FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR puede_ver_tramite(tramite_id)
    );

CREATE POLICY pol_correo_tramite_insert
    ON correo_tramite FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- DELETE: solo directores (corrección de vínculos incorrectos)
CREATE POLICY pol_correo_tramite_delete
    ON correo_tramite FOR DELETE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));


-- -----------------------------------------------------------------------------
-- POLICIES: adjunto
-- Visibilidad via el correo padre (que hereda de los trámites).
-- NUNCA exponer adjunto.password a authenticated.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_adjunto_select_director
    ON adjunto FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_adjunto_select_via_correo
    ON adjunto FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('gerente', 'analista')
        AND EXISTS (
            SELECT 1 FROM correo_tramite ct
            WHERE ct.correo_id = correo_id
              AND puede_ver_tramite(ct.tramite_id)
        )
    );

-- INSERT/UPDATE: solo Agentes IA via service_role + directores para correcciones
CREATE POLICY pol_adjunto_insert
    ON adjunto FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_adjunto_update
    ON adjunto FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));


-- -----------------------------------------------------------------------------
-- POLICIES: documento
-- -----------------------------------------------------------------------------

CREATE POLICY pol_documento_select_director
    ON documento FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_documento_select_via_tramite
    ON documento FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('gerente', 'analista')
        AND puede_ver_tramite(tramite_id)
    );

-- Analistas pueden actualizar el estado de validación manualmente (override del Agente 5)
CREATE POLICY pol_documento_update_validacion
    ON documento FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
        AND puede_ver_tramite(tramite_id)
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- INSERT: solo Agente 3 via service_role + directores para carga manual
CREATE POLICY pol_documento_insert
    ON documento FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));


-- =============================================================================
-- SECCIÓN 10: GRANTS — con exclusión de columna 'password' en adjunto
-- =============================================================================
-- PostgreSQL permite GRANTs a nivel de columna.
-- authenticated puede ver TODAS las columnas de adjunto EXCEPTO 'password'.
-- Solo service_role (los agentes IA) tiene acceso a adjunto.password.
-- =============================================================================

GRANT SELECT, INSERT ON TABLE correo         TO authenticated;
GRANT UPDATE (estado, cuerpo_html, cuerpo_texto, fecha_envio, datos_agente2, updated_at)
    ON TABLE correo TO authenticated;

GRANT SELECT, INSERT, DELETE ON TABLE correo_tramite TO authenticated;

-- adjunto: GRANT por columna — excluye 'password' explícitamente
GRANT SELECT (
    id, correo_id, adjunto_padre_id, nombre_archivo, tipo_mime,
    tamanio_bytes, storage_path, password_eliminado, estado,
    motivo_error, created_at, updated_at
) ON TABLE adjunto TO authenticated;

GRANT UPDATE (
    estado, storage_path, motivo_error, password_eliminado, updated_at
) ON TABLE adjunto TO authenticated;

-- 'password' y el INSERT completo (que incluye password) solo via service_role
-- No se hace GRANT de INSERT a authenticated para adjunto —
-- los adjuntos los crea el Agente 1 via service_role.

GRANT SELECT ON TABLE documento TO authenticated;
GRANT UPDATE (
    tipo_documento, estado_validacion, motivo_invalidez,
    confianza_clasificacion, updated_at
) ON TABLE documento TO authenticated;
-- INSERT de documentos solo via service_role (Agente 3)

GRANT EXECUTE ON FUNCTION puede_ver_tramite(UUID) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000004_modulo_05_correos_adjuntos.sql
-- =============================================================================

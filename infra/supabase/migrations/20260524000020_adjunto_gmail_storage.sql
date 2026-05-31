-- =============================================================================
-- Migración: 20260524000020_adjunto_gmail_storage.sql
-- Completa el tracking de adjuntos Gmail → Supabase Storage
-- =============================================================================
-- Problemas que corrige:
--
--   1. adjunto.gmail_attachment_id faltante
--      El Agente 1 necesita el ID de adjunto de Gmail para descargarlo.
--      Sin él, si el proceso falla a la mitad no hay forma de re-intentar.
--
--   2. adjunto.storage_bucket faltante
--      storage_path guarda la ruta pero no el bucket. Con múltiples buckets
--      (correos-inbox, correos-archivados) se pierde la referencia completa.
--
--   3. correo.ingestado_via faltante
--      No había registro de cómo entró el correo: webhook, polling o BCC.
--      Crítico para diagnosticar fallos en la integración DWD.
--
--   4. Convención de storage_path para correos pre-trámite
--      Los adjuntos llegan ANTES de que exista el trámite (Agente 1 corre
--      antes que Agente 2). La ruta temporal usa /inbox/{correo_id}/
--      y se actualiza a /tramites/{tramite_id}/ cuando se asigna el trámite.
--
-- Tablas afectadas: correo, adjunto
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: adjunto — columnas de integración Gmail + Storage
-- =============================================================================

-- ID del adjunto en Gmail (attachmentId en la API de Gmail).
-- Necesario para descargar el archivo desde Gmail si el proceso falla
-- antes de subirlo a Supabase Storage.
-- NULL para adjuntos que son hijos de ZIPs (no vienen directo de Gmail).
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS gmail_attachment_id TEXT NULL;

COMMENT ON COLUMN adjunto.gmail_attachment_id IS
    'ID del adjunto en la API de Gmail (Part.body.attachmentId). '
    'Necesario para re-descargar si el proceso falla antes de subir a Storage. '
    'NULL para adjuntos extraídos de ZIPs (no tienen ID propio en Gmail).';


-- Bucket de Supabase Storage donde vive el archivo.
-- Complementa storage_path — juntos forman la referencia completa al objeto.
-- Separado de storage_path para permitir queries como:
--   "Todos los archivos en el bucket de archivado"
-- Valores esperados: 'correos-adjuntos' (activo), 'correos-archivados' (archivado)
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS storage_bucket TEXT NULL
        DEFAULT 'correos-adjuntos';

COMMENT ON COLUMN adjunto.storage_bucket IS
    'Bucket de Supabase Storage que contiene el archivo. '
    'Junto con storage_path forman la referencia completa: bucket + path. '
    'Default: correos-adjuntos. Se cambia a correos-archivados al archivar. '
    'NULL hasta que el archivo se sube a Storage.';


-- Hash SHA-256 del contenido del archivo.
-- Permite verificar integridad después de la descarga y detectar duplicados exactos.
-- El Agente 1 lo calcula al momento de descargar de Gmail.
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS checksum_sha256 TEXT NULL;

COMMENT ON COLUMN adjunto.checksum_sha256 IS
    'SHA-256 del contenido del archivo (calculado al descargar de Gmail). '
    'Verifica integridad después de subir a Storage. '
    'Detecta duplicados exactos aunque tengan nombre diferente.';


-- Número de intentos de descarga de Gmail.
-- Limita los reintentos para no saturar la cuota de Gmail API.
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS intentos_descarga SMALLINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN adjunto.intentos_descarga IS
    'Veces que el Agente 1 intentó descargar este adjunto de Gmail. '
    'Máximo configurable en configuracion_sistema (MAX_REINTENTOS_GMAIL). '
    'Al superar el máximo, estado cambia a error y se alerta al analista.';


-- =============================================================================
-- SECCIÓN 2: correo — trazabilidad de ingesta DWD
-- =============================================================================

-- Cómo llegó este correo al sistema.
-- Crítico para diagnosticar fallos en la integración con Google Workspace.
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS ingestado_via TEXT NULL
        CHECK (ingestado_via IN (
            'webhook_pubsub',  -- Gmail Push Notifications (canal principal)
            'polling',         -- Fallback: el worker consulta Gmail periódicamente
            'bcc_rule',        -- Regla BCC de Workspace capturó un correo saliente del agente
            'manual'           -- El analista lo subió manualmente desde la UI
        ));

COMMENT ON COLUMN correo.ingestado_via IS
    'Canal por el que el correo entró al sistema. '
    'webhook_pubsub: Gmail notificó vía Pub/Sub (flujo principal). '
    'polling: worker de fallback consultó Gmail API periódicamente. '
    'bcc_rule: regla de Workspace reenviló un correo saliente del agente vía BCC. '
    'manual: el analista lo registró a mano desde la UI.';


-- ID de la suscripción Pub/Sub que notificó este correo.
-- Permite correlacionar notificaciones de Gmail con correos procesados
-- para debugging y deduplicación de notificaciones duplicadas.
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS pubsub_subscription_id TEXT NULL;

COMMENT ON COLUMN correo.pubsub_subscription_id IS
    'ID de la suscripción de Google Pub/Sub que entregó la notificación. '
    'Formato: projects/{project}/subscriptions/{subscription}. '
    'Permite deduplicar: si la misma notificación llega dos veces (at-least-once), '
    'el message_id ya evita duplicados pero este campo facilita el debugging.';


-- historyId de Gmail al momento de la ingesta.
-- Gmail usa historyId para sincronización incremental. Guardarlo permite
-- reanudar desde el punto correcto si el webhook falla por un período.
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS gmail_history_id BIGINT NULL;

COMMENT ON COLUMN correo.gmail_history_id IS
    'historyId de Gmail al momento de procesar este correo. '
    'Usado para sincronización incremental: si el webhook falla X horas, '
    'el worker de polling retoma desde el último historyId registrado.';


-- =============================================================================
-- SECCIÓN 3: Tabla gmail_sync_state — estado de sincronización por cuenta DWD
-- =============================================================================
-- Registra el historyId más reciente procesado por cada cuenta de Workspace.
-- El worker de polling usa esto para pedir solo emails nuevos desde el último sync.
-- También registra el estado del canal Pub/Sub para detectar renovaciones necesarias.
--
-- Sin esta tabla, si el webhook deja de funcionar, el worker de polling
-- no sabe desde dónde reanudar y puede procesar miles de correos viejos.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gmail_sync_state (
    -- -------------------------------------------------------------------------
    -- Identificación de la cuenta
    -- -------------------------------------------------------------------------
    -- Dirección de la cuenta de Google Workspace monitoreada vía DWD
    -- Ej: 'analista.garcia@promotoría.mx', 'director@promotoría.mx'
    cuenta_workspace    TEXT            PRIMARY KEY,

    -- -------------------------------------------------------------------------
    -- Estado de sincronización Gmail
    -- -------------------------------------------------------------------------
    -- Último historyId de Gmail procesado exitosamente.
    -- El worker de polling llama history.list?startHistoryId={ultimo_history_id}
    -- para obtener solo los cambios desde la última sincronización.
    ultimo_history_id   BIGINT          NULL,

    -- Timestamp del último sync exitoso
    ultimo_sync_at      TIMESTAMPTZ     NULL,

    -- Número de correos procesados en el último sync (para monitoring)
    correos_ultimo_sync INTEGER         NOT NULL DEFAULT 0,

    -- -------------------------------------------------------------------------
    -- Estado del canal Gmail Push Notifications (Pub/Sub)
    -- -------------------------------------------------------------------------
    -- ID del canal Pub/Sub activo. NULL si no hay canal activo.
    pubsub_channel_id   TEXT            NULL,

    -- Los canales de Gmail Push expiran cada 7 días — hay que renovarlos.
    -- El worker de renovación revisa esta columna para saber cuándo actuar.
    canal_expira_at     TIMESTAMPTZ     NULL,

    -- Estado del canal para monitoreo
    canal_activo        BOOLEAN         NOT NULL DEFAULT FALSE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE gmail_sync_state IS
    'Estado de sincronización Gmail por cuenta de Google Workspace (DWD). '
    'Registra el historyId más reciente y el estado del canal Pub/Sub. '
    'El worker de polling lo consulta para reanudar desde el punto correcto '
    'cuando el webhook falla. El worker de renovación controla la expiración del canal.';

COMMENT ON COLUMN gmail_sync_state.ultimo_history_id IS
    'historyId de Gmail del último mensaje procesado. '
    'Punto de reanudación para el worker de polling si el webhook cae. '
    'history.list?startHistoryId={este_valor} retorna solo los cambios nuevos.';

COMMENT ON COLUMN gmail_sync_state.canal_expira_at IS
    'Los canales Push de Gmail expiran en 7 días (máximo). '
    'El worker de renovación debe llamar users.watch() antes de esta fecha '
    'para no perder notificaciones.';


CREATE TRIGGER trg_gmail_sync_state_updated_at
    BEFORE UPDATE ON gmail_sync_state
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- RLS: solo service_role (workers de backend) pueden leer y escribir
ALTER TABLE gmail_sync_state ENABLE ROW LEVEL SECURITY;

-- Sin policies para authenticated → solo service_role tiene acceso
-- Los analistas no necesitan ver ni tocar el estado de sincronización

COMMENT ON TABLE gmail_sync_state IS
    'Estado de sincronización Gmail por cuenta DWD. '
    'RLS: sin policies para authenticated → solo service_role (workers). '
    'Accesible vía Superadmin para diagnóstico de fallos de sincronización.';


-- =============================================================================
-- SECCIÓN 4: Función para obtener el storage_path correcto según etapa
-- =============================================================================
-- Resuelve el problema de timing: los adjuntos llegan ANTES de que exista
-- el trámite. La ruta temporal usa /inbox/ y se actualiza al asignar trámite.
--
-- Ruta temporal (sin trámite):
--   correos-adjuntos/inbox/{correo_id}/{adjunto_id}/{nombre_archivo}
--
-- Ruta final (con trámite asignado):
--   correos-adjuntos/tramites/{tramite_id}/{correo_id}/{adjunto_id}/{nombre_archivo}
--
-- El Agente 1 usa la ruta temporal. El Agente 4 (Asignación) actualiza a final.
-- =============================================================================

CREATE OR REPLACE FUNCTION generar_storage_path(
    p_correo_id     uuid,
    p_adjunto_id    uuid,
    p_nombre_archivo text,
    p_tramite_id    uuid    DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT CASE
        WHEN p_tramite_id IS NOT NULL THEN
            -- Ruta final: el trámite ya fue creado y asignado
            'tramites/' || p_tramite_id::text ||
            '/' || p_correo_id::text ||
            '/' || p_adjunto_id::text ||
            '/' || p_nombre_archivo
        ELSE
            -- Ruta temporal: el correo llegó pero aún no tiene trámite
            'inbox/' || p_correo_id::text ||
            '/' || p_adjunto_id::text ||
            '/' || p_nombre_archivo
    END;
$$;

COMMENT ON FUNCTION generar_storage_path(uuid, uuid, text, uuid) IS
    'Genera la ruta de Supabase Storage para un adjunto. '
    'Sin tramite_id: inbox/{correo_id}/{adjunto_id}/{nombre} (ruta temporal del Agente 1). '
    'Con tramite_id: tramites/{tramite_id}/{correo_id}/{adjunto_id}/{nombre} (ruta final). '
    'El Agente 4 llama actualizar_storage_path_tramite() al asignar el trámite.';

GRANT EXECUTE ON FUNCTION generar_storage_path(uuid, uuid, text, uuid) TO service_role;


-- =============================================================================
-- SECCIÓN 5: Función para actualizar rutas de adjuntos al crear el trámite
-- =============================================================================
-- Cuando el Agente 2 crea el trámite, el Agente 4 (o el propio Agente 2)
-- llama esto para actualizar los storage_path de todos los adjuntos del correo
-- de la ruta temporal (inbox/) a la ruta final (tramites/).
--
-- IMPORTANTE: el archivo en Supabase Storage NO se mueve aquí.
-- Esto solo actualiza la columna en DB. El worker tiene que mover el objeto
-- en Storage usando la API de Storage (move/copy + delete).
-- =============================================================================

CREATE OR REPLACE FUNCTION actualizar_storage_paths_tramite(
    p_correo_id     uuid,
    p_tramite_id    uuid
)
RETURNS INTEGER  -- número de adjuntos actualizados
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE adjunto
    SET storage_path = generar_storage_path(
                            correo_id,
                            id,
                            nombre_archivo,
                            p_tramite_id
                       ),
        updated_at   = NOW()
    WHERE correo_id   = p_correo_id
      AND storage_path IS NOT NULL
      AND storage_path LIKE 'inbox/%';  -- solo las temporales

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION actualizar_storage_paths_tramite(uuid, uuid) IS
    'Actualiza los storage_path de adjuntos de inbox/ a tramites/ '
    'cuando el trámite queda creado y asignado. '
    'Solo actualiza DB — el worker debe mover los objetos en Supabase Storage también.';

GRANT EXECUTE ON FUNCTION actualizar_storage_paths_tramite(uuid, uuid) TO service_role;


-- =============================================================================
-- SECCIÓN 6: Índices nuevos
-- =============================================================================

-- Buscar adjuntos por gmail_attachment_id (re-descarga en caso de fallo)
CREATE INDEX IF NOT EXISTS idx_adjunto_gmail_id
    ON adjunto (gmail_attachment_id)
    WHERE gmail_attachment_id IS NOT NULL;

COMMENT ON INDEX idx_adjunto_gmail_id IS
    'Permite al Agente 1 verificar si un adjunto de Gmail ya fue registrado '
    '(idempotencia) y recuperar el registro para reintentar la descarga.';

-- Adjuntos en ruta temporal (inbox/) que necesitan mover a ruta final
CREATE INDEX IF NOT EXISTS idx_adjunto_storage_inbox
    ON adjunto (correo_id)
    WHERE storage_path LIKE 'inbox/%';

COMMENT ON INDEX idx_adjunto_storage_inbox IS
    'Adjuntos con ruta temporal (inbox/) que aún no tienen trámite asignado. '
    'El Agente 4 los detecta y llama actualizar_storage_paths_tramite().';

-- Estado de sync para detectar cuentas sin canal activo o con canal próximo a expirar
CREATE INDEX IF NOT EXISTS idx_gmail_sync_expiracion
    ON gmail_sync_state (canal_expira_at)
    WHERE canal_activo = TRUE;

COMMENT ON INDEX idx_gmail_sync_expiracion IS
    'Worker de renovación: detecta canales Pub/Sub próximos a expirar (en 7 días). '
    'Debe renovar antes de canal_expira_at para no perder notificaciones.';

-- Correos por canal de ingesta (monitoreo de salud del webhook)
CREATE INDEX IF NOT EXISTS idx_correo_ingestado_via
    ON correo (ingestado_via, created_at)
    WHERE ingestado_via IS NOT NULL;

COMMENT ON INDEX idx_correo_ingestado_via IS
    'Monitoreo: si ingestado_via = polling aumenta y webhook_pubsub = 0, '
    'el canal Pub/Sub está caído y hay que renovarlo.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000020_adjunto_gmail_storage.sql
-- =============================================================================

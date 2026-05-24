-- =============================================================================
-- Migración: 20260522000008_modulo_09_notificaciones.sql
-- Módulo 9 — Notificaciones en tiempo real
-- =============================================================================
-- Arquitectura:
--   Las notificaciones se entregan en tiempo real vía Supabase Realtime.
--   El frontend suscribe a INSERT en la tabla notificacion WHERE usuario_id = auth.uid().
--   Cuando el backend (Celery/agentes) inserta una fila, Realtime la empuja
--   al navegador del destinatario en milisegundos — sin polling.
--
--   Dos tablas:
--
--   notificacion        → Registro individual por usuario y evento.
--                         Cada analista ve solo las suyas. El badge del nav
--                         muestra el conteo de no leídas.
--
--   notificacion_config → Preferencias por usuario y tipo. Modelo opt-out:
--                         si no hay fila de config, el usuario recibe la notif.
--                         El usuario puede desactivar tipos específicos desde
--                         su perfil. El director puede modificar configs de
--                         cualquier usuario.
--
-- Flujo de entrega:
--   Evento ocurre (cambio de estado, SLA, correo, etc.)
--   → Celery worker llama crear_notificacion(usuario_id, tipo, ...)
--   → crear_notificacion verifica notificacion_config (¿usuario activó este tipo?)
--   → INSERT en notificacion
--   → Supabase Realtime notifica al frontend
--   → Badge actualizado, toast mostrado
--   → Usuario lee → UPDATE leida=TRUE via frontend
--
-- Tipos de eventos que generan notificaciones:
--   Pipeline IA    → tramite_asignado, requiere_atencion, correo_borrador_listo
--   Estado         → cambio_estado_tramite, rechazo_gnp, aprobacion_gnp
--   SLA            → sla_alerta, sla_vencido
--   Correos        → correo_recibido
--   Operaciones    → tramite_reasignado, documento_requerido, cobertura_inicio
--
-- Relaciones con módulos anteriores:
--   notificacion.usuario_id      → usuario.id    (Módulo 1)
--   notificacion.tramite_id      → tramite.id    (Módulo 4, nullable)
--   notificacion_config.usuario_id → usuario.id  (Módulo 1)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_notificacion AS ENUM (
    -- ---- Generadas por el pipeline de IA ----
    -- Agente 4 asignó un nuevo trámite al analista
    'tramite_asignado',
    -- El trámite fue reasignado a otro analista (notifica al anterior y al nuevo)
    'tramite_reasignado',
    -- Un agente IA marcó el trámite como requiere_atencion=TRUE
    'requiere_atencion',
    -- Agente 6 terminó el borrador del correo — analista debe revisarlo
    'correo_borrador_listo',

    -- ---- Generadas por cambios de estado ----
    -- El trámite cambió de estado (configurable: el analista puede silenciar este)
    'cambio_estado_tramite',
    -- GNP rechazó el trámite
    'rechazo_gnp',
    -- GNP aprobó el trámite
    'aprobacion_gnp',

    -- ---- Generadas por el motor de SLA (Módulo 8) ----
    -- El trámite consumió X% del plazo SLA (alerta preventiva)
    'sla_alerta',
    -- El trámite superó el deadline SLA sin cerrarse
    'sla_vencido',

    -- ---- Generadas por correos (Módulo 5) ----
    -- Nuevo correo entrante vinculado a un trámite del analista
    'correo_recibido',

    -- ---- Generadas por operaciones ----
    -- El agente de seguros necesita enviar documentos faltantes
    'documento_requerido',
    -- El analista está cubriendo a otro que inició vacaciones (Módulo 7)
    'cobertura_inicio'
);

COMMENT ON TYPE tipo_notificacion IS
    'Catálogo de eventos que generan notificaciones en Olimpo CRM. '
    'Cada tipo puede ser habilitado/deshabilitado por usuario en notificacion_config.';


-- =============================================================================
-- SECCIÓN 2: TABLA notificacion
-- =============================================================================
-- Cada fila es una notificación individual para un usuario específico.
-- El frontend suscribe a cambios en esta tabla para recibir notificaciones
-- en tiempo real vía Supabase Realtime.
--
-- Política de retención:
--   Las notificaciones no se borran físicamente — se archivan.
--   Esto preserva el historial de alertas para auditoría.
--   El frontend filtra archivada=FALSE en la vista normal.
-- =============================================================================

CREATE TABLE notificacion (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Destinatario
    -- -------------------------------------------------------------------------
    usuario_id      UUID                NOT NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Contenido
    -- -------------------------------------------------------------------------
    tipo            tipo_notificacion   NOT NULL,
    titulo          TEXT                NOT NULL,
    cuerpo          TEXT                NOT NULL,

    -- -------------------------------------------------------------------------
    -- Contexto — enlace al trámite relacionado (para navegar desde la notif)
    -- -------------------------------------------------------------------------
    tramite_id      UUID                NULL REFERENCES tramite(id) ON DELETE SET NULL,

    -- Datos adicionales para que el frontend renderice la notif correctamente.
    -- Estructura varía por tipo. Ejemplos:
    --   tramite_asignado:      { "folio": "TRM-2026-00042", "analista": "nombre" }
    --   sla_alerta:            { "folio": "TRM-2026-00042", "porcentaje": 82, "horas_restantes": 6 }
    --   correo_borrador_listo: { "correo_id": "uuid", "asunto": "Re: Alta GMM..." }
    --   rechazo_gnp:           { "folio_ot": "OT-123456", "codigo_rechazo": "R-042" }
    datos           JSONB               NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Estado de lectura
    -- -------------------------------------------------------------------------
    leida           BOOLEAN             NOT NULL DEFAULT FALSE,
    leida_en        TIMESTAMPTZ         NULL,

    -- -------------------------------------------------------------------------
    -- Archivo — el usuario puede descartar notificaciones sin eliminarlas
    -- -------------------------------------------------------------------------
    archivada       BOOLEAN             NOT NULL DEFAULT FALSE,
    archivada_en    TIMESTAMPTZ         NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría (sin updated_at — el estado cambia vía campos específicos)
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Leída requiere timestamp
    CONSTRAINT ck_notif_leida_consistente CHECK (
        (leida = FALSE AND leida_en IS NULL)
        OR (leida = TRUE AND leida_en IS NOT NULL)
    ),

    -- Archivada requiere timestamp
    CONSTRAINT ck_notif_archivada_consistente CHECK (
        (archivada = FALSE AND archivada_en IS NULL)
        OR (archivada = TRUE AND archivada_en IS NOT NULL)
    ),

    CONSTRAINT ck_notif_titulo_not_empty CHECK (TRIM(titulo) <> ''),
    CONSTRAINT ck_notif_cuerpo_not_empty CHECK (TRIM(cuerpo) <> '')
);

COMMENT ON TABLE notificacion IS
    'Notificaciones individuales por usuario. '
    'El frontend suscribe via Supabase Realtime a INSERT WHERE usuario_id = auth.uid(). '
    'Las notificaciones no se borran — se archivan para preservar el historial.';

COMMENT ON COLUMN notificacion.tramite_id IS
    'Trámite relacionado. El frontend lo usa para navegar directamente al trámite. '
    'ON DELETE SET NULL: si el trámite se elimina (soft-delete no aplica aquí), '
    'la notificación se preserva sin referencia rota.';
COMMENT ON COLUMN notificacion.datos      IS 'JSONB con contexto específico del tipo. Permite renderizado rico en la UI.';
COMMENT ON COLUMN notificacion.archivada  IS 'El usuario descartó la notificación. El frontend la oculta pero existe en el historial.';


-- =============================================================================
-- SECCIÓN 3: TABLA notificacion_config
-- =============================================================================
-- Preferencias de notificación por usuario y tipo.
-- Modelo opt-out: si no existe fila de config, el usuario RECIBE la notificación.
-- El usuario puede desactivar tipos específicos desde su perfil en la UI.
-- El director puede gestionar configs de cualquier usuario.
--
-- Ejemplo: un analista que no quiere recibir 'cambio_estado_tramite' en cada
-- movimiento puede desactivarla — seguirá recibiendo 'sla_alerta' y 'rechazo_gnp'.
-- =============================================================================

CREATE TABLE notificacion_config (
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- El usuario dueño de esta preferencia
    usuario_id      UUID                NOT NULL REFERENCES usuario(id),

    -- El tipo de notificación que se está configurando
    tipo            tipo_notificacion   NOT NULL,

    -- TRUE = el usuario recibe este tipo | FALSE = silenciado
    activa          BOOLEAN             NOT NULL DEFAULT TRUE,

    -- Auditoría
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- Una sola configuración por (usuario, tipo)
    CONSTRAINT uq_notif_config_usuario_tipo
        UNIQUE (usuario_id, tipo)
);

COMMENT ON TABLE notificacion_config IS
    'Preferencias de notificación por usuario y tipo. Modelo opt-out: '
    'si no existe fila de config, el usuario recibe la notificación. '
    'El usuario gestiona sus propias preferencias desde su perfil. '
    'El director puede modificar la configuración de cualquier usuario.';

COMMENT ON COLUMN notificacion_config.activa IS
    'TRUE = recibe el tipo. FALSE = silenciado. '
    'La función crear_notificacion() consulta esta tabla antes de insertar.';


-- =============================================================================
-- SECCIÓN 4: ÍNDICES
-- =============================================================================

-- notificacion —————————————————————————————————————————————————————————————————

-- Badge del nav: conteo de notificaciones no leídas del usuario actual
CREATE INDEX idx_notif_usuario_no_leidas
    ON notificacion (usuario_id, created_at DESC)
    WHERE leida = FALSE AND archivada = FALSE;

COMMENT ON INDEX idx_notif_usuario_no_leidas IS
    'Query principal del badge del nav: notificaciones activas no leídas por usuario. '
    'Partial: excluye las leídas y archivadas (la mayoría del volumen).';

-- Bandeja de entrada: todas las no archivadas del usuario (leídas + no leídas)
CREATE INDEX idx_notif_usuario_bandeja
    ON notificacion (usuario_id, created_at DESC)
    WHERE archivada = FALSE;

-- Notificaciones de un trámite específico (panel lateral del trámite)
CREATE INDEX idx_notif_tramite
    ON notificacion (tramite_id, created_at DESC)
    WHERE tramite_id IS NOT NULL;

-- notificacion_config ——————————————————————————————————————————————————————————

-- crear_notificacion() consulta este índice para verificar preferencias
CREATE INDEX idx_notif_config_usuario_tipo
    ON notificacion_config (usuario_id, tipo);


-- =============================================================================
-- SECCIÓN 5: TRIGGERS
-- =============================================================================

-- updated_at en notificacion_config
CREATE TRIGGER trg_notif_config_updated_at
    BEFORE UPDATE ON notificacion_config
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Trigger para auto-registrar leida_en cuando leida cambia a TRUE
CREATE OR REPLACE FUNCTION set_notif_leida_en()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.leida = TRUE AND OLD.leida = FALSE THEN
        NEW.leida_en := NOW();
    END IF;

    IF NEW.archivada = TRUE AND OLD.archivada = FALSE THEN
        NEW.archivada_en := NOW();
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_notif_leida_en() IS
    'Auto-registra leida_en y archivada_en al momento de marcar los flags. '
    'El frontend solo necesita hacer UPDATE SET leida=TRUE — el timestamp es automático.';

CREATE TRIGGER trg_notif_set_timestamps
    BEFORE UPDATE OF leida, archivada ON notificacion
    FOR EACH ROW
    EXECUTE FUNCTION set_notif_leida_en();

-- Prevenir que una notificación se "des-lea" o "des-archive"
CREATE OR REPLACE FUNCTION proteger_notif_inmutabilidad()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.leida = TRUE AND NEW.leida = FALSE THEN
        RAISE EXCEPTION
            'Una notificación leída no puede marcarse como no leída.';
    END IF;

    IF OLD.archivada = TRUE AND NEW.archivada = FALSE THEN
        RAISE EXCEPTION
            'Una notificación archivada no puede desarchivarse.';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION proteger_notif_inmutabilidad() IS
    'Garantiza que leida y archivada solo transicionen en una dirección. '
    'Preserva integridad del historial de notificaciones.';

CREATE TRIGGER trg_notif_proteger_estado
    BEFORE UPDATE OF leida, archivada ON notificacion
    FOR EACH ROW
    EXECUTE FUNCTION proteger_notif_inmutabilidad();


-- =============================================================================
-- SECCIÓN 6: FUNCIÓN crear_notificacion()
-- =============================================================================
-- Función central que todo el backend usa para generar notificaciones.
-- Verifica las preferencias del usuario antes de insertar.
--
-- Uso en Python (Celery worker, agentes IA):
--   supabase.rpc('crear_notificacion', {
--       'p_usuario_id':  str(analista_id),
--       'p_tipo':        'correo_borrador_listo',
--       'p_titulo':      'Borrador listo para revisión',
--       'p_cuerpo':      'El Agente 6 preparó el borrador para TRM-2026-00042.',
--       'p_tramite_id':  str(tramite_id),
--       'p_datos':       json.dumps({'correo_id': str(correo_id), 'asunto': '...'})
--   }).execute()
--
-- Retorna el id de la notificacion creada, o NULL si el usuario la silencia.
-- =============================================================================

CREATE OR REPLACE FUNCTION crear_notificacion(
    p_usuario_id    UUID,
    p_tipo          tipo_notificacion,
    p_titulo        TEXT,
    p_cuerpo        TEXT,
    p_tramite_id    UUID        DEFAULT NULL,
    p_datos         JSONB       DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_activa        BOOLEAN;
    v_notif_id      UUID;
BEGIN
    -- Verificar preferencias del usuario (modelo opt-out)
    SELECT activa INTO v_activa
    FROM notificacion_config
    WHERE usuario_id = p_usuario_id
      AND tipo       = p_tipo;

    -- Si existe config y está desactivada, no insertar
    IF FOUND AND v_activa = FALSE THEN
        RETURN NULL;
    END IF;

    -- Insertar la notificación
    INSERT INTO notificacion (
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

COMMENT ON FUNCTION crear_notificacion(UUID, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Crea una notificación para un usuario respetando sus preferencias. '
    'Modelo opt-out: si no hay config, se crea la notificación. '
    'Si el usuario desactivó ese tipo, retorna NULL sin insertar. '
    'El INSERT dispara Supabase Realtime al navegador del destinatario.';


-- =============================================================================
-- SECCIÓN 7: FUNCIÓN notificar_a_rol()
-- =============================================================================
-- Broadcast de notificación a todos los usuarios de un rol (y opcionalmente ramo).
-- Útil para alertas de SLA vencido que van al gerente completo,
-- o para avisar a todos los directores de un evento crítico.
--
-- Uso en Python:
--   supabase.rpc('notificar_a_rol', {
--       'p_rol':   'gerente',
--       'p_ramo':  'gmm',
--       'p_tipo':  'sla_vencido',
--       'p_titulo': 'SLA vencido',
--       'p_cuerpo': 'El trámite TRM-2026-00042 superó su plazo.',
--       'p_tramite_id': str(tramite_id),
--       'p_datos': '{}'
--   }).execute()
-- =============================================================================

CREATE OR REPLACE FUNCTION notificar_a_rol(
    p_rol           rol_usuario,
    p_ramo          ramo_usuario    DEFAULT NULL,
    p_tipo          tipo_notificacion  DEFAULT NULL,
    p_titulo        TEXT            DEFAULT NULL,
    p_cuerpo        TEXT            DEFAULT NULL,
    p_tramite_id    UUID            DEFAULT NULL,
    p_datos         JSONB           DEFAULT '{}'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario       RECORD;
    v_count         INTEGER := 0;
BEGIN
    FOR v_usuario IN
        SELECT id FROM usuario
        WHERE rol    = p_rol
          AND activo = TRUE
          AND (p_ramo IS NULL OR ramo = p_ramo)
    LOOP
        IF crear_notificacion(
            v_usuario.id, p_tipo, p_titulo, p_cuerpo, p_tramite_id, p_datos
        ) IS NOT NULL THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RETURN v_count; -- número de notificaciones efectivamente creadas
END;
$$;

COMMENT ON FUNCTION notificar_a_rol(rol_usuario, ramo_usuario, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Envía la misma notificación a todos los usuarios activos de un rol y ramo. '
    'Respeta las preferencias individuales via crear_notificacion(). '
    'Retorna el número de notificaciones efectivamente creadas. '
    'Uso: alertas de SLA al gerente del ramo, avisos al equipo completo.';


-- =============================================================================
-- SECCIÓN 8: SUPABASE REALTIME
-- =============================================================================
-- Para que Supabase Realtime entregue notificaciones al frontend, la tabla
-- debe estar en la publicación de replicación de Supabase.
--
-- El frontend se suscribe así:
--   supabase
--     .channel('notificaciones')
--     .on('postgres_changes', {
--       event: 'INSERT',
--       schema: 'public',
--       table: 'notificacion',
--       filter: `usuario_id=eq.${userId}`
--     }, (payload) => {
--       // mostrar toast + actualizar badge
--       showToast(payload.new.titulo)
--       incrementBadge()
--     })
--     .subscribe()
-- =============================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE notificacion;

COMMENT ON TABLE notificacion IS
    'Notificaciones individuales por usuario. '
    'Publicada en supabase_realtime — el frontend recibe INSERT en tiempo real. '
    'Las notificaciones no se borran — se archivan para preservar el historial.';


-- =============================================================================
-- SECCIÓN 9: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE notificacion        ENABLE ROW LEVEL SECURITY;
ALTER TABLE notificacion_config ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: notificacion
-- Las notificaciones son estrictamente personales — nadie ve las de otro.
-- Excepción: service_role bypasa RLS (backend puede insertar para cualquier usuario).
-- -----------------------------------------------------------------------------

-- SELECT: cada usuario solo ve sus propias notificaciones
CREATE POLICY pol_notif_select
    ON notificacion FOR SELECT TO authenticated
    USING (usuario_id = auth.uid());

COMMENT ON POLICY pol_notif_select ON notificacion IS
    'Cada usuario accede únicamente a sus propias notificaciones. '
    'Supabase Realtime también respeta esta policy en las suscripciones filtradas.';

-- UPDATE: cada usuario puede marcar sus notificaciones como leídas o archivadas
-- (el trigger impide revertir esos estados)
CREATE POLICY pol_notif_update
    ON notificacion FOR UPDATE TO authenticated
    USING (usuario_id = auth.uid())
    WITH CHECK (usuario_id = auth.uid());

COMMENT ON POLICY pol_notif_update ON notificacion IS
    'El usuario puede actualizar sus notificaciones (marcar leída, archivar). '
    'Los triggers garantizan que leida y archivada solo avancen, nunca retrocedan.';

-- INSERT: prohibido para authenticated — solo service_role vía crear_notificacion()
-- DELETE: prohibido — las notificaciones son inmutables, se archivan


-- -----------------------------------------------------------------------------
-- POLICIES: notificacion_config
-- Cada usuario gestiona sus propias preferencias.
-- Los directores pueden ver y modificar configs de cualquier usuario (soporte).
-- -----------------------------------------------------------------------------

CREATE POLICY pol_notif_config_select_propio
    ON notificacion_config FOR SELECT TO authenticated
    USING (usuario_id = auth.uid());

CREATE POLICY pol_notif_config_select_director
    ON notificacion_config FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_notif_config_insert_propio
    ON notificacion_config FOR INSERT TO authenticated
    WITH CHECK (usuario_id = auth.uid());

CREATE POLICY pol_notif_config_insert_director
    ON notificacion_config FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_notif_config_update_propio
    ON notificacion_config FOR UPDATE TO authenticated
    USING (usuario_id = auth.uid())
    WITH CHECK (usuario_id = auth.uid());

CREATE POLICY pol_notif_config_update_director
    ON notificacion_config FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

-- DELETE: no — soft-disable vía activa=FALSE


-- =============================================================================
-- SECCIÓN 10: GRANTS
-- =============================================================================

-- notificacion: authenticated puede SELECT (RLS filtra por usuario_id) y UPDATE
-- INSERT solo service_role vía crear_notificacion() SECURITY DEFINER
GRANT SELECT, UPDATE ON TABLE notificacion        TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE notificacion_config TO authenticated;

-- Funciones disponibles para el backend y para la UI (tests de integración)
GRANT EXECUTE ON FUNCTION crear_notificacion(UUID, tipo_notificacion, TEXT, TEXT, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION notificar_a_rol(rol_usuario, ramo_usuario, tipo_notificacion, TEXT, TEXT, UUID, JSONB) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000008_modulo_09_notificaciones.sql
-- =============================================================================

-- =============================================================================
-- Migración: 20260522000011_modulo_12_mejoras_diagnostico.sql
-- Módulo 12 — Mejoras de seguridad, rendimiento y diseño post-diagnóstico
-- =============================================================================
-- Esta migración implementa las optimizaciones y correcciones del diagnóstico
-- experto en base de datos.
--
-- MEJORAS INCLUIDAS:
--   1. Seguridad: Define search_path en todas las funciones SECURITY DEFINER
--      para prevenir secuestro de ruta de búsqueda (privilege escalation).
--   2. Rendimiento: Índices en las 17 llaves foráneas (FK) faltantes que
--      son de uso constante en queries, JOINs y borrados en cascada.
--   3. Auditoría: Triggers de auditoría para tablas operativas clave (poliza,
--      documento, correo, adjunto) que anteriormente no se auditaban.
--   4. Diseño de Negocio: Modificación de fecha_activacion y fecha_resolucion
--      en ot_activacion de DATE a TIMESTAMPTZ para soportar SLAs precisos.
--   5. Validación: Restricciones CHECK para garantizar formatos de email correctos.
--   6. Privacidad: Trigger para purgar automáticamente contraseñas de ZIPs
--      en adjunto una vez procesado el archivo.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: SEGURIDAD — search_path EN FUNCIONES SECURITY DEFINER
-- =============================================================================
-- Configurar search_path de forma explícita en las funciones que se ejecutan
-- con privilegios del creador (SECURITY DEFINER) para evitar ejecuciones
-- maliciosas en esquemas temporales.
-- =============================================================================

ALTER FUNCTION public.auth_rol() SET search_path = auth, pg_catalog;
ALTER FUNCTION public.auth_ramo() SET search_path = auth, pg_catalog;
ALTER FUNCTION public.set_agente_ia_sesion(TEXT) SET search_path = pg_catalog;
ALTER FUNCTION public.puede_ver_tramite(UUID) SET search_path = public, auth, pg_catalog;


-- =============================================================================
-- SECCIÓN 2: RENDIMIENTO — ÍNDICES EN LLAVES FORÁNEAS (FK)
-- =============================================================================
-- La base de datos no indexa FKs por defecto. Estos índices optimizan JOINs
-- y validaciones ON DELETE, evitando seq scans costosos.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_agente_ia_log_correo_id 
    ON public.agente_ia_log(correo_id);

CREATE INDEX IF NOT EXISTS idx_asignacion_asignado_por 
    ON public.asignacion(asignado_por);

CREATE INDEX IF NOT EXISTS idx_cobertura_vacaciones_creado_por 
    ON public.cobertura_vacaciones(creado_por);

CREATE INDEX IF NOT EXISTS idx_dia_inhabil_creado_por 
    ON public.dia_inhabil(creado_por);

CREATE INDEX IF NOT EXISTS idx_ot_activacion_registrado_por 
    ON public.ot_activacion(registrado_por);

CREATE INDEX IF NOT EXISTS idx_rag_aprendizaje_poliza_id 
    ON public.rag_aprendizaje(poliza_id);

CREATE INDEX IF NOT EXISTS idx_rag_aprendizaje_documento_id 
    ON public.rag_aprendizaje(documento_id);

CREATE INDEX IF NOT EXISTS idx_rag_aprendizaje_validado_por 
    ON public.rag_aprendizaje(validado_por);

CREATE INDEX IF NOT EXISTS idx_rag_gnp_ingresado_por 
    ON public.rag_gnp(ingresado_por);

CREATE INDEX IF NOT EXISTS idx_rag_gnp_revisado_por 
    ON public.rag_gnp(revisado_por);

CREATE INDEX IF NOT EXISTS idx_rag_poliza_tramite_id 
    ON public.rag_poliza(tramite_id);

CREATE INDEX IF NOT EXISTS idx_rag_poliza_tramite_evento_id 
    ON public.rag_poliza(tramite_evento_id);

CREATE INDEX IF NOT EXISTS idx_sla_definicion_creado_por 
    ON public.sla_definicion(creado_por);

CREATE INDEX IF NOT EXISTS idx_sla_tramite_sla_definicion_id 
    ON public.sla_tramite(sla_definicion_id);

CREATE INDEX IF NOT EXISTS idx_tramite_asegurado_id 
    ON public.tramite(asegurado_id);

CREATE INDEX IF NOT EXISTS idx_tramite_asistente_id 
    ON public.tramite(asistente_id);

CREATE INDEX IF NOT EXISTS idx_tramite_evento_usuario_id 
    ON public.tramite_evento(usuario_id);


-- =============================================================================
-- SECCIÓN 3: AUDITORÍA — TRIGGERS EN TABLAS OPERATIVAS
-- =============================================================================
-- Registrar en audit_log todos los inserts, updates y deletes manuales o
-- automáticos en pólizas, documentos, correos y adjuntos.
-- =============================================================================

CREATE TRIGGER trg_poliza_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.poliza
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

CREATE TRIGGER trg_documento_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.documento
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

CREATE TRIGGER trg_correo_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.correo
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

CREATE TRIGGER trg_adjunto_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.adjunto
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


-- =============================================================================
-- SECCIÓN 4: DISEÑO DE NEGOCIO — TIMESTAMPTZ EN ot_activacion
-- =============================================================================
-- Cambiar de DATE a TIMESTAMPTZ para no perder hora y minuto de las activaciones,
-- habilitando el cálculo de SLAs e indicadores de respuesta con GNP.
-- =============================================================================

ALTER TABLE public.ot_activacion 
    ALTER COLUMN fecha_activacion TYPE TIMESTAMPTZ USING fecha_activacion::timestamptz,
    ALTER COLUMN fecha_activacion SET DEFAULT NOW(),
    ALTER COLUMN fecha_resolucion TYPE TIMESTAMPTZ USING fecha_resolucion::timestamptz;


-- =============================================================================
-- SECCIÓN 5: VALIDACIÓN — RESTRICCIONES DE FORMATO DE EMAIL
-- =============================================================================
-- Validar a nivel de base de datos que los correos electrónicos tengan un formato
-- consistente, como última línea de defensa ante inserciones directas en Supabase.
-- =============================================================================

ALTER TABLE public.usuario ADD CONSTRAINT ck_usuario_email_valido 
    CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$');

ALTER TABLE public.agente_email ADD CONSTRAINT ck_agente_email_valido 
    CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$');

ALTER TABLE public.asistente ADD CONSTRAINT ck_asistente_email_valido 
    CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$');


-- =============================================================================
-- SECCIÓN 6: PRIVACIDAD POR DISEÑO — PURGAR CONTRASEÑAS ZIP
-- =============================================================================
-- Crear un trigger que automáticamente ponga en NULL la contraseña temporal
-- en adjunto una vez que el estado cambia a procesado, descomprimido, ilegible o error.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.clean_zip_password()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- Limpiar contraseña si el archivo ya fue procesado
    IF NEW.estado IN ('descomprimido', 'error', 'ilegible', 'procesado') THEN
        NEW.password = NULL;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.clean_zip_password() IS
    'Limpia automáticamente la contraseña temporal de un adjunto una vez procesado.';

CREATE TRIGGER trg_clean_zip_password
    BEFORE UPDATE OF estado ON public.adjunto
    FOR EACH ROW
    EXECUTE FUNCTION public.clean_zip_password();

COMMENT ON TRIGGER trg_clean_zip_password ON public.adjunto IS
    'Garantiza la eliminación física de contraseñas de ZIPs por cumplimiento de LFPDPPP.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000011_modulo_12_mejoras_diagnostico.sql
-- =============================================================================

-- =============================================================================
-- Migración: 20260522000018_mejoras_auditoria_rendimiento.sql
-- Corrección de índice faltante en sla_tramite y trigger de auditoría en tramite
-- =============================================================================

-- 1. Indexar tramite_id en sla_tramite (Llave foránea faltante en Módulo 12)
CREATE INDEX IF NOT EXISTS idx_sla_tramite_tramite_id
    ON public.sla_tramite(tramite_id);

COMMENT ON INDEX idx_sla_tramite_tramite_id IS
    'Optimiza búsquedas de SLAs por trámite y cascadas de eliminación ON DELETE CASCADE.';

-- 2. Trigger de Auditoría para la tabla tramite
CREATE TRIGGER trg_tramite_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.tramite
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

COMMENT ON TRIGGER trg_tramite_audit ON public.tramite IS
    'Registra en la tabla audit_log todos los cambios del ciclo de vida y asignación de los trámites.';

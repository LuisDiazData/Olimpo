-- =============================================================================
-- 20260616000002_hardening_vista_sla_y_campana.sql
--
-- 1. sla_tramite_vista se creó sin security_invoker, por lo que se ejecuta con
--    los privilegios del owner y SALTA el RLS de las tablas base (tramite,
--    sla_tramite). Ahora que el frontend la consume con el cliente RLS del
--    usuario, forzamos security_invoker para que respete las políticas por rol.
--
-- 2. La tabla campana tiene columna updated_at pero ningún trigger que la
--    mantenga; queda congelada en el valor de inserción. Reutilizamos
--    set_updated_at() (definida en el módulo 00).
-- =============================================================================

ALTER VIEW sla_tramite_vista SET (security_invoker = on);

DROP TRIGGER IF EXISTS trg_campana_updated_at ON campana;
CREATE TRIGGER trg_campana_updated_at
    BEFORE UPDATE ON campana
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- =============================================================================
-- FIN DE MIGRACIÓN: 20260616000002_hardening_vista_sla_y_campana.sql
-- =============================================================================

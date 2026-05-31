-- =============================================================================
-- Migración: 20260529000028_tenant_licencias.sql
-- Agrega campos de gestión de licencias a la tabla tenant
-- =============================================================================
-- Contexto:
--   El panel Superadmin (admin.olimpo.mx) necesita gestionar el ciclo de vida
--   de las licencias de cada promotoría: tipo de plan, fechas de vigencia y
--   estado actual. Esto permite bloquear acceso por vencimiento, renovar
--   licencias y distinguir promotorías en periodo de prueba.
-- =============================================================================

ALTER TABLE tenant
    ADD COLUMN tipo_plan                 TEXT    NOT NULL DEFAULT 'basico'
        CONSTRAINT ck_tipo_plan
            CHECK (tipo_plan IN ('basico', 'profesional', 'enterprise')),

    ADD COLUMN fecha_inicio_licencia     DATE    NULL,

    ADD COLUMN fecha_vencimiento_licencia DATE   NULL,

    ADD COLUMN estado_licencia           TEXT    NOT NULL DEFAULT 'prueba'
        CONSTRAINT ck_estado_licencia
            CHECK (estado_licencia IN ('activa', 'prueba', 'suspendida', 'expirada'));

COMMENT ON COLUMN tenant.tipo_plan IS
    'Plan contratado: basico, profesional o enterprise.';

COMMENT ON COLUMN tenant.fecha_inicio_licencia IS
    'Fecha en que inició la licencia vigente. NULL si aún no se ha formalizado.';

COMMENT ON COLUMN tenant.fecha_vencimiento_licencia IS
    'Fecha en que vence la licencia. NULL en periodos de prueba sin fecha límite.';

COMMENT ON COLUMN tenant.estado_licencia IS
    'Estado actual: prueba (recién dado de alta), activa (pago confirmado), '
    'suspendida (bloqueada por Superadmin), expirada (vencida sin renovar).';


-- =============================================================================
-- ÍNDICE: búsquedas por vencimiento para el dashboard de alertas
-- =============================================================================

CREATE INDEX idx_tenant_vencimiento
    ON tenant (fecha_vencimiento_licencia)
    WHERE estado_licencia IN ('activa', 'prueba');

COMMENT ON INDEX idx_tenant_vencimiento IS
    'Soporte para la consulta "venciendo en N días" del dashboard del Superadmin. '
    'Índice parcial sobre estados vigentes para mantenerlo pequeño.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260529000028_tenant_licencias.sql
-- =============================================================================

-- =============================================================================
-- Migración: 20260531000000_ramos_adicionales_usuario.sql
-- Módulo: Gestión de múltiples ramos por usuario
-- =============================================================================
--
-- Contexto:
--   Un gerente o analista puede pertenecer a varios ramos de seguros.
--   Ejemplo: un analista de Vida y GMM procesa trámites de ambos ramos.
--
-- Cambio:
--   Agregar columna ramos_adicionales: ramo_usuario[] (array de ramos).
--   El ramo "principal" (usuario.ramo) se mantiene por compatibilidad —
--   para no cambiar todas las queries existentes en RLS y dashboards.
--
--   - Un gerente/analista SIEMPRE tiene un ramo principal (ramo, NOT NULL).
--   - Además puede tener ramos_adicionales opcionales para extender acceso.
--   - Un director_general o director_ops tiene ramo=NULL y ramos_adicionales=NULL.
--
-- Nota de diseño:
--   No se elimina la restricción ck_ramo_segun_rol. El ramo principal sigue
--   siendo obligatorio para gerente/analista y prohibido para directores.
--   Los ramos_adicionales son纯粹的 información extendida; no afectan RLS ni
--   la lógica de asignación (que sigue usando ramo como columna principal).
-- =============================================================================

-- 1. Agregar columna ramos_adicionales como arreglo de ramo_usuario
ALTER TABLE usuario
ADD COLUMN ramos_adicionales ramo_usuario[]
DEFAULT NULL;

COMMENT ON COLUMN usuario.ramos_adicionales IS
    'Ramos adicionales del usuario. Un analista o gerente con ramos_adicionales '
    'puede ver y procesar trámites de esos ramos además del ramo principal. '
    'NULL para directores (que ven todos los ramos sin necesidad de esta columna).';

-- 2. Índice GIN para búsquedas eficientes en el array
CREATE INDEX idx_usuario_ramos_adicionales
    ON usuario USING GIN (ramos_adicionales);

COMMENT ON INDEX idx_usuario_ramos_adicionales IS
    'Índice GIN para consultas que buscan usuarios por ramos_adicionales. '
    'Útil en dashboards y asignación masiva.';

-- 3. Constraint: si ramos_adicionales tiene valores, deben ser distintos al ramo principal
ALTER TABLE usuario
ADD CONSTRAINT ck_ramos_adicionales_distintos
CHECK (
    ramos_adicionales IS NULL
    OR NOT (ramo = ANY(ramos_adicionales))
);

COMMENT ON CONSTRAINT ck_ramos_adicionales_distintos ON usuario IS
    'Un ramo no puede aparecer simultáneamente como ramo principal y en ramos_adicionales. '
    'El ramo principal ya cubre ese ramo.';

-- 4. Grant para authenticated (ya tiene SELECT, UPDATE;ramos_adicionales hereda)
GRANT USAGE ON TYPE ramo_usuario TO authenticated;
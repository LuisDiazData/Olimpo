-- =============================================================================
-- Migración: 20260614000001_modulo_14_bi_comercial.sql
-- Módulo 14 — BI Comercial, Metas y Comisiones
-- =============================================================================

-- Agregar columnas financieras a la tabla poliza
ALTER TABLE poliza 
    ADD COLUMN IF NOT EXISTS prima_neta NUMERIC(12, 2) NULL,
    ADD COLUMN IF NOT EXISTS moneda TEXT DEFAULT 'MXN',
    ADD COLUMN IF NOT EXISTS porcentaje_comision NUMERIC(5, 2) NULL,
    ADD COLUMN IF NOT EXISTS monto_comision NUMERIC(12, 2) NULL;

COMMENT ON COLUMN poliza.prima_neta IS 'Prima neta sin IVA.';
COMMENT ON COLUMN poliza.moneda IS 'Moneda de la prima (ej. MXN, USD).';
COMMENT ON COLUMN poliza.porcentaje_comision IS 'Porcentaje de comisión para el agente.';
COMMENT ON COLUMN poliza.monto_comision IS 'Monto calculado de comisión.';

-- Función RPC para el Dashboard de BI
CREATE OR REPLACE FUNCTION get_bi_dashboard_stats(p_mes INT, p_anio INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    resultado JSONB;
BEGIN
    SELECT jsonb_build_object(
        'totales_por_moneda', (
            SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                    'moneda', moneda,
                    'prima_neta_total', total_prima,
                    'comision_total', total_comision,
                    'cantidad_polizas', conteo
                )
            ), '[]'::jsonb)
            FROM (
                SELECT moneda, 
                       SUM(prima_neta) as total_prima, 
                       SUM(monto_comision) as total_comision,
                       COUNT(id) as conteo
                FROM poliza
                WHERE estado = 'activa'
                  AND EXTRACT(MONTH FROM created_at) = p_mes
                  AND EXTRACT(YEAR FROM created_at) = p_anio
                GROUP BY moneda
            ) t
        ),
        'top_agentes', (
            SELECT COALESCE(jsonb_agg(row_to_json(ta)), '[]'::jsonb)
            FROM (
                SELECT a.nombre, SUM(p.prima_neta) as total_prima
                FROM poliza p
                JOIN agente a ON p.agente_id = a.id
                WHERE p.estado = 'activa' AND p.moneda = 'MXN'
                  AND EXTRACT(MONTH FROM p.created_at) = p_mes
                  AND EXTRACT(YEAR FROM p.created_at) = p_anio
                GROUP BY a.nombre
                ORDER BY total_prima DESC NULLS LAST
                LIMIT 5
            ) ta
        ),
        'top_analistas', (
            SELECT COALESCE(jsonb_agg(row_to_json(ta)), '[]'::jsonb)
            FROM (
                SELECT u.nombre, COUNT(p.id) as cantidad_polizas, SUM(p.prima_neta) as total_prima
                FROM poliza p
                JOIN usuario u ON p.analista_id = u.id
                WHERE p.estado = 'activa' AND p.moneda = 'MXN'
                  AND EXTRACT(MONTH FROM p.created_at) = p_mes
                  AND EXTRACT(YEAR FROM p.created_at) = p_anio
                GROUP BY u.nombre
                ORDER BY total_prima DESC NULLS LAST
                LIMIT 5
            ) ta
        )
    ) INTO resultado;

    RETURN resultado;
END;
$$;

-- Permisos RPC solo para directores y gerentes
REVOKE EXECUTE ON FUNCTION get_bi_dashboard_stats(INT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION get_bi_dashboard_stats(INT, INT) TO authenticated;

-- (Opcional) Trigger para auto-calcular el monto de comisión
CREATE OR REPLACE FUNCTION calc_monto_comision()
RETURNS trigger AS $$
BEGIN
    IF NEW.prima_neta IS NOT NULL AND NEW.porcentaje_comision IS NOT NULL THEN
        NEW.monto_comision := (NEW.prima_neta * NEW.porcentaje_comision) / 100.0;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_calc_monto_comision ON poliza;
CREATE TRIGGER trg_calc_monto_comision
    BEFORE INSERT OR UPDATE OF prima_neta, porcentaje_comision ON poliza
    FOR EACH ROW
    EXECUTE FUNCTION calc_monto_comision();

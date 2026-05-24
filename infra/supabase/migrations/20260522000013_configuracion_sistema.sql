-- =============================================================================
-- Migración: 20260522000013_configuracion_sistema.sql
-- Tabla configuracion_sistema — umbrales de IA y parámetros configurables
-- =============================================================================
-- Propósito:
--   Almacenar todos los parámetros operativos del CRM que hoy viven como
--   variables de entorno hardcodeadas (ver CLAUDE.md: CONFIDENCE_AGENTE,
--   CONFIDENCE_DOCUMENTO, etc.). Estos valores deben ser modificables desde
--   la UI del Superadmin o del director sin necesidad de un redeploy.
--
-- Regla de negocio crítica (CLAUDE.md):
--   "No hay SLAs ni umbrales hardcodeados. Todos deben poder modificarse
--   desde el Superadmin o desde la UI del director sin tocar código."
--
-- Diseño de la tabla:
--   - Clave única por (clave, aplica_ramo): permite umbrales globales y
--     también umbrales distintos por ramo (ej: umbral de confianza más alto
--     para gmm que para autos).
--   - tipo_valor permite a la capa de aplicación castear correctamente.
--   - editable_por controla quién puede cambiar cada parámetro:
--     'superadmin' = solo desde admin.olimpo.mx con service_role
--     'director'   = también desde la UI del director_general/director_ops
--
-- Funciones de consulta:
--   get_config(clave)             → valor global (aplica_ramo IS NULL)
--   get_config_ramo(clave, ramo)  → valor por ramo, con fallback a global
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TABLA configuracion_sistema
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.configuracion_sistema (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Clave del parámetro
    -- -------------------------------------------------------------------------
    -- Nombre canónico del parámetro, en SCREAMING_SNAKE_CASE.
    -- Ejemplos: 'CONFIDENCE_AGENTE', 'TIMEOUT_PASSWORD_HORAS'
    clave           TEXT            NOT NULL,
    CONSTRAINT ck_config_clave_not_empty CHECK (TRIM(clave) <> ''),

    -- -------------------------------------------------------------------------
    -- Valor (siempre TEXT — la app lo castea según tipo_valor)
    -- -------------------------------------------------------------------------
    valor           TEXT            NOT NULL,
    CONSTRAINT ck_config_valor_not_empty CHECK (TRIM(valor) <> ''),

    -- Tipo del valor para que la capa de aplicación sepa cómo castearlo
    tipo_valor      TEXT            NOT NULL
                    CHECK (tipo_valor IN ('float', 'integer', 'boolean', 'text', 'json')),

    -- -------------------------------------------------------------------------
    -- Metadatos descriptivos
    -- -------------------------------------------------------------------------
    descripcion     TEXT            NOT NULL,
    CONSTRAINT ck_config_descripcion_not_empty CHECK (TRIM(descripcion) <> ''),

    -- Agrupación lógica para la UI del director/superadmin
    -- Ejemplos: 'ia_umbrales', 'ia_timeouts', 'seguridad', 'general'
    grupo           TEXT            NOT NULL DEFAULT 'general',

    -- -------------------------------------------------------------------------
    -- Control de acceso para edición
    -- -------------------------------------------------------------------------
    -- 'superadmin' → solo editable desde admin.olimpo.mx (service_role)
    -- 'director'   → editable desde la UI del director_general o director_ops
    editable_por    TEXT            NOT NULL DEFAULT 'director'
                    CHECK (editable_por IN ('superadmin', 'director')),

    -- -------------------------------------------------------------------------
    -- Scope por ramo (para umbrales específicos por línea de negocio)
    -- -------------------------------------------------------------------------
    -- NULL = parámetro global (aplica a todos los ramos)
    -- NOT NULL = override para ese ramo específico
    aplica_ramo     ramo_usuario    NULL,

    -- -------------------------------------------------------------------------
    -- Estado
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría Olimpo
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- La clave es única dentro de cada scope (global o por ramo).
    -- Esto permite tener CONFIDENCE_AGENTE global = 0.75
    -- y CONFIDENCE_AGENTE para ramo='gmm' = 0.80 sin conflicto.
    CONSTRAINT uq_config_clave_ramo UNIQUE (clave, aplica_ramo)
);

COMMENT ON TABLE public.configuracion_sistema IS
    'Parámetros operativos del CRM configurables sin redeploy. '
    'Incluye umbrales de IA, timeouts y otros parámetros del CLAUDE.md. '
    'Accesible via get_config() y get_config_ramo(). '
    'editable_por controla si el director puede modificarlo o solo el superadmin.';

COMMENT ON COLUMN public.configuracion_sistema.clave IS
    'Nombre canónico del parámetro en SCREAMING_SNAKE_CASE. '
    'Ej: CONFIDENCE_AGENTE, TIMEOUT_PASSWORD_HORAS. '
    'Único por (clave, aplica_ramo).';
COMMENT ON COLUMN public.configuracion_sistema.valor IS
    'Valor como TEXT. La aplicación lo castea usando tipo_valor.';
COMMENT ON COLUMN public.configuracion_sistema.tipo_valor IS
    'Tipo del valor: float | integer | boolean | text | json. '
    'Permite al cliente Python/TypeScript castearlo correctamente.';
COMMENT ON COLUMN public.configuracion_sistema.grupo IS
    'Agrupación lógica para la UI. Ej: ia_umbrales, ia_timeouts, seguridad.';
COMMENT ON COLUMN public.configuracion_sistema.editable_por IS
    'superadmin = solo desde admin.olimpo.mx. '
    'director = también desde la UI del director_general o director_ops.';
COMMENT ON COLUMN public.configuracion_sistema.aplica_ramo IS
    'NULL = parámetro global. NOT NULL = override para ese ramo específico. '
    'get_config_ramo() usa el override si existe, si no cae al global.';


-- =============================================================================
-- SECCIÓN 2: TRIGGER updated_at
-- =============================================================================

CREATE TRIGGER trg_configuracion_sistema_updated_at
    BEFORE UPDATE ON public.configuracion_sistema
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- SECCIÓN 3: TRIGGER DE AUDITORÍA
-- =============================================================================
-- audit_table_change() ya existe desde migración 20260522000009.
-- Se registra cada cambio de configuración: quién lo hizo y qué valor tenía antes.

CREATE TRIGGER trg_configuracion_sistema_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.configuracion_sistema
    FOR EACH ROW
    EXECUTE FUNCTION public.audit_table_change();

COMMENT ON TRIGGER trg_configuracion_sistema_audit ON public.configuracion_sistema IS
    'Registra en audit_log cada cambio de configuración. '
    'Permite responder: "¿Quién bajó el umbral de confianza del agente y cuándo?"';


-- =============================================================================
-- SECCIÓN 4: FUNCIÓN get_config()
-- =============================================================================
-- Devuelve el valor del parámetro GLOBAL (aplica_ramo IS NULL).
-- Retorna NULL si no existe o si activo = FALSE.
-- Los agentes IA la llaman al inicio de cada ejecución para leer sus umbrales.

CREATE OR REPLACE FUNCTION public.get_config(p_clave TEXT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT valor
    FROM public.configuracion_sistema
    WHERE clave       = p_clave
      AND aplica_ramo IS NULL
      AND activo      = TRUE
    LIMIT 1;
$$;

COMMENT ON FUNCTION public.get_config(TEXT) IS
    'Devuelve el valor global del parámetro de configuración (aplica_ramo IS NULL). '
    'Retorna NULL si la clave no existe o está inactiva. '
    'Los agentes IA la usan para leer umbrales: get_config(''CONFIDENCE_AGENTE'')';


-- =============================================================================
-- SECCIÓN 5: FUNCIÓN get_config_ramo()
-- =============================================================================
-- Devuelve el valor del parámetro con fallback:
--   1. Busca primero por (clave, ramo)  → override específico del ramo
--   2. Si no existe, cae al global       → (clave, NULL)
--   3. Si tampoco existe, retorna NULL
-- Esta estrategia permite que la mayoría de parámetros sean globales
-- y solo se configuren overrides donde el ramo lo justifique.

CREATE OR REPLACE FUNCTION public.get_config_ramo(
    p_clave TEXT,
    p_ramo  ramo_usuario DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_valor TEXT;
BEGIN
    -- Paso 1: buscar override específico del ramo (si se proveyó ramo)
    IF p_ramo IS NOT NULL THEN
        SELECT valor INTO v_valor
        FROM public.configuracion_sistema
        WHERE clave      = p_clave
          AND aplica_ramo = p_ramo
          AND activo      = TRUE
        LIMIT 1;

        IF FOUND THEN
            RETURN v_valor;
        END IF;
    END IF;

    -- Paso 2: fallback al valor global (aplica_ramo IS NULL)
    SELECT valor INTO v_valor
    FROM public.configuracion_sistema
    WHERE clave       = p_clave
      AND aplica_ramo IS NULL
      AND activo      = TRUE
    LIMIT 1;

    RETURN v_valor;  -- NULL si no existe en ningún scope
END;
$$;

COMMENT ON FUNCTION public.get_config_ramo(TEXT, ramo_usuario) IS
    'Devuelve el valor del parámetro con fallback: override por ramo primero, '
    'luego valor global. Si p_ramo es NULL, equivale a get_config(). '
    'Uso: get_config_ramo(''CONFIDENCE_AGENTE'', ''gmm'') '
    '→ retorna el umbral de gmm si existe, sino el global.';


-- =============================================================================
-- SECCIÓN 6: DATOS INICIALES
-- =============================================================================
-- Equivalentes a las variables de entorno definidas en CLAUDE.md.
-- Se usan ON CONFLICT DO UPDATE para que la migración sea idempotente:
-- si ya existen (por re-ejecución), se actualizan sin error.

INSERT INTO public.configuracion_sistema
    (clave, valor, tipo_valor, descripcion, grupo, editable_por, aplica_ramo)
VALUES
    -- Umbrales de confianza del Agente 4 (identificación de agente CUA)
    (
        'CONFIDENCE_AGENTE',
        '0.75',
        'float',
        'Umbral mínimo de confianza (0-1) para que el Agente 4 acepte la '
        'identificación de un agente de seguros en la cascada CUA. '
        'Por debajo de este umbral se marca requiere_atencion = TRUE.',
        'ia_umbrales',
        'director',
        NULL
    ),

    -- Umbral de confianza del Agente 3 (clasificación de documentos)
    (
        'CONFIDENCE_DOCUMENTO',
        '0.70',
        'float',
        'Umbral mínimo de confianza (0-1) para que el Agente 3 acepte la '
        'clasificación del tipo de documento (INE, solicitud_alta, etc.). '
        'Por debajo de este umbral el documento se clasifica como "otro".',
        'ia_umbrales',
        'director',
        NULL
    ),

    -- Umbral de confianza del Agente 4 (vinculación trámite-póliza)
    (
        'CONFIDENCE_VINCULACION',
        '0.85',
        'float',
        'Umbral mínimo de confianza (0-1) para vincular automáticamente un '
        'trámite con una póliza existente. Mayor que CONFIDENCE_AGENTE '
        'porque una vinculación incorrecta puede contaminar el RAG de pólizas.',
        'ia_umbrales',
        'director',
        NULL
    ),

    -- Umbral de fuzzy matching para nombres de agentes
    (
        'FUZZY_MATCH_NOMBRE',
        '0.85',
        'float',
        'Score mínimo de similitud fuzzy (0-1) para considerar que dos nombres '
        'corresponden al mismo agente de seguros. Usado por el Agente 4 en la '
        'cascada CUA cuando no hay match exacto por CUA o email.',
        'ia_umbrales',
        'director',
        NULL
    ),

    -- Tiempo máximo de retención de contraseñas ZIP
    (
        'TIMEOUT_PASSWORD_HORAS',
        '24',
        'integer',
        'Número de horas máximo que una contraseña ZIP puede permanecer en '
        'adjunto.password sin ser procesada. El Agente 1 debe eliminarla '
        'antes de este plazo. Pasado el timeout, se considera un incidente '
        'de seguridad y se alerta al director_ops.',
        'seguridad',
        'superadmin',
        NULL
    ),

    -- Timeout del pipeline de agentes IA por trámite
    (
        'PIPELINE_TIMEOUT_MINUTOS',
        '30',
        'integer',
        'Tiempo máximo en minutos que el pipeline completo de agentes (1 al 6) '
        'puede tardar en procesar un trámite antes de considerarse atascado. '
        'Al superar este timeout, el trámite se marca requiere_atencion = TRUE '
        'y se registra en pipeline_reintento.',
        'ia_timeouts',
        'director',
        NULL
    )

ON CONFLICT (clave, aplica_ramo) DO UPDATE
    SET
        valor        = EXCLUDED.valor,
        descripcion  = EXCLUDED.descripcion,
        tipo_valor   = EXCLUDED.tipo_valor,
        grupo        = EXCLUDED.grupo,
        editable_por = EXCLUDED.editable_por,
        activo       = TRUE,
        updated_at   = NOW();


-- =============================================================================
-- SECCIÓN 7: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--   SELECT: todos los authenticated (los agentes IA vía service_role ya tienen
--     acceso total, pero los usuarios humanos también necesitan leer la config
--     para mostrar valores en la UI del director).
--   INSERT/UPDATE: solo director_general y director_ops para parámetros
--     marcados editable_por='director'. Los parámetros editable_por='superadmin'
--     solo son modificables vía service_role (admin.olimpo.mx).
--   DELETE: nadie — soft-delete vía activo = FALSE.

ALTER TABLE public.configuracion_sistema ENABLE ROW LEVEL SECURITY;

-- SELECT: todos los autenticados pueden leer la configuración
CREATE POLICY pol_config_select
    ON public.configuracion_sistema
    FOR SELECT
    TO authenticated
    USING (activo = TRUE);

COMMENT ON POLICY pol_config_select ON public.configuracion_sistema IS
    'Todos los usuarios autenticados pueden leer parámetros activos. '
    'Los agentes IA (service_role) bypasan RLS y leen sin restricción.';

-- INSERT: solo directores, y solo parámetros que les corresponde gestionar
CREATE POLICY pol_config_insert_director
    ON public.configuracion_sistema
    FOR INSERT
    TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        AND editable_por = 'director'
    );

COMMENT ON POLICY pol_config_insert_director ON public.configuracion_sistema IS
    'Directores solo pueden crear parámetros con editable_por = ''director''. '
    'Los parámetros editable_por = ''superadmin'' solo se crean desde admin.olimpo.mx.';

-- UPDATE: solo directores, y solo parámetros que les corresponde gestionar
CREATE POLICY pol_config_update_director
    ON public.configuracion_sistema
    FOR UPDATE
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        AND editable_por = 'director'
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        AND editable_por = 'director'
    );

COMMENT ON POLICY pol_config_update_director ON public.configuracion_sistema IS
    'Directores pueden modificar el valor y estado de parámetros que les pertenecen. '
    'No pueden cambiar editable_por de director a superadmin (evadir control).';


-- =============================================================================
-- SECCIÓN 8: GRANTS
-- =============================================================================

GRANT SELECT ON TABLE public.configuracion_sistema TO authenticated;
GRANT INSERT, UPDATE ON TABLE public.configuracion_sistema TO authenticated;

-- Las funciones de consulta deben ser accesibles por el frontend y los agentes IA
GRANT EXECUTE ON FUNCTION public.get_config(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_config_ramo(TEXT, ramo_usuario) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000013_configuracion_sistema.sql
-- =============================================================================

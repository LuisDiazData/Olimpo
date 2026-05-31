-- =============================================================================
-- Migración: 20260524000026_cierre_gaps_pipeline.sql
-- Cierre de gaps del pipeline de ingesta de correos
-- =============================================================================
--
-- GAP 1 → correo.eml_storage_path / eml_storage_bucket
--   El correo entrante se archiva "tal cual" en Supabase Storage para:
--   • Cumplimiento / auditoría regulatoria (CONDUSEF, GNP requieren retención)
--   • Replay del pipeline si el procesamiento falla parcialmente
--   • Forensía de disputas con el agente sobre el contenido original
--   El cuerpo sigue en correo.cuerpo_texto/html (consulta rápida en DB).
--   El archivo raw en Storage es el archivado oficial, inmutable y comprobable.
--
--   Ruta convenida: correos-inbox/{YYYY}/{MM}/{correo_id}/raw.eml
--   Función generar_eml_storage_path() genera esta ruta de forma determinista.
--
-- GAP 2 → buscar_o_crear_asegurado()
--   Cuando el Agente 4 extrae "Luis González" de los documentos OCR'ados,
--   sin RFC ni CURP no hay unicidad en DB. El sistema podría crear duplicados
--   si el mismo asegurado llega en trámites distintos antes de ser enriquecido.
--
--   La función implementa una cascada de resolución de 4 pasos:
--     1. RFC (UNIQUE en DB) → match exacto, enriquece y retorna
--     2. CURP (UNIQUE en DB) → match exacto, enriquece y retorna
--     3. Nombre fuzzy (pg_trgm, ya habilitado) → si un solo candidato, retorna;
--        si múltiples, marca requiere_atencion = TRUE y retorna candidatos
--     4. No encontrado → INSERT (con manejo de race condition via EXCEPTION)
--
--   Retorna JSONB con: asegurado_id, accion, requiere_atencion, candidatos[]
--   El Agente 4 lee requiere_atencion y lo propaga al trámite si es TRUE.
--
-- GAP 3 → configuracion_sistema: FUZZY_MATCH_ASEGURADO
--   Umbral de similitud separado del de agentes (FUZZY_MATCH_NOMBRE = 0.85).
--   Los asegurados tienen nombres más variados (nombre + apellido, empresa, etc.)
--   y el umbral óptimo puede diferir. Configurable por director desde la UI.
--
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: correo — archivado del email raw en Supabase Storage
-- =============================================================================

-- Ruta del archivo .eml completo en Supabase Storage.
-- Lo escribe el Agente 1 (service_role) al ingestar el correo.
-- NULL hasta que el Agente 1 sube el archivo (puede tardar segundos en escritura async).
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS eml_storage_path TEXT NULL;

COMMENT ON COLUMN correo.eml_storage_path IS
    'Ruta del archivo .eml completo en Supabase Storage. '
    'Formato: {YYYY}/{MM}/{correo_id}/raw.eml (sin el nombre del bucket). '
    'NULL hasta que el Agente 1 finaliza la subida. '
    'Usar generar_eml_storage_path() para construir el valor correcto.';


-- Bucket donde vive el archivo .eml.
-- Separado de la ruta para poder mover a archivado sin cambiar la ruta.
-- Valores: 'correos-inbox' (activo), 'correos-archivados' (archivado)
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS eml_storage_bucket TEXT NULL
        DEFAULT 'correos-inbox'
        CHECK (eml_storage_bucket IN ('correos-inbox', 'correos-archivados'));

COMMENT ON COLUMN correo.eml_storage_bucket IS
    'Bucket de Supabase Storage que contiene el .eml. '
    'correos-inbox: correos activos en procesamiento. '
    'correos-archivados: correos cerrados, movidos para retención regulatoria. '
    'Junto con eml_storage_path forman la referencia completa al objeto.';


-- Índice parcial para detectar correos sin archivo subido (monitoreo / alertas)
CREATE INDEX IF NOT EXISTS idx_correo_sin_eml_storage
    ON correo (id, created_at)
    WHERE tipo = 'entrante'
      AND eml_storage_path IS NULL
      AND estado NOT IN ('recibido');  -- recibido es pre-subida; más allá debe tener path

COMMENT ON INDEX idx_correo_sin_eml_storage IS
    'Monitoreo: correos ya procesados que aún no tienen el .eml archivado. '
    'En operación normal debe estar vacío. Si el Agente 1 falla al subir, '
    'aparece aquí y el worker de reintentos lo detecta.';


-- Índice para recuperar ruta por correo_id (el Agente 6 necesita el .eml
-- al construir las respuestas con forward correcto de headers)
CREATE INDEX IF NOT EXISTS idx_correo_eml_path
    ON correo (correo_id)
    WHERE eml_storage_path IS NOT NULL;

-- ^^^ self-referencing path index — usar por id directamente es O(1) via PK,
--     pero este índice cubre la columna en el plan para queries con WHERE eml_storage_path IS NOT NULL

-- Función determinista para generar la ruta del .eml
-- Determinista = dado el mismo correo_id + fecha, siempre devuelve el mismo path.
-- El Agente 1 llama esto ANTES de subir el archivo para construir el destino.
CREATE OR REPLACE FUNCTION generar_eml_storage_path(
    p_correo_id         uuid,
    p_fecha_correo      timestamptz
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT
        to_char(p_fecha_correo AT TIME ZONE 'UTC', 'YYYY/MM')
        || '/' || p_correo_id::text
        || '/raw.eml'
$$;

COMMENT ON FUNCTION generar_eml_storage_path(uuid, timestamptz) IS
    'Genera la ruta del .eml en Supabase Storage de forma determinista. '
    'Formato: YYYY/MM/{correo_id}/raw.eml (sin el bucket — se guarda por separado). '
    'El Agente 1 llama esto antes de subir el archivo para saber el destino. '
    'Ejemplo: "2026/05/550e8400-e29b-41d4-a716-446655440000/raw.eml"';

GRANT EXECUTE ON FUNCTION generar_eml_storage_path(uuid, timestamptz) TO service_role;
-- No GRANT a authenticated: la ruta la construye solo el Agente 1 (service_role)


-- GRANT UPDATE del nuevo campo — solo service_role (los agentes IA)
-- authenticated no puede modificar el path de Storage directamente
-- (el UPDATE GRANT existente en correo no incluye eml_storage_path)

-- Nota: los correos salientes nunca tienen eml_storage_path (no se archivan en inbox)
-- El CHECK de tipo ya no es necesario en DB — se maneja en el Agente 1 en código


-- =============================================================================
-- SECCIÓN 2: FUZZY_MATCH_ASEGURADO — umbral configurable
-- =============================================================================
-- Umbral separado del de agentes porque los asegurados:
--   • Pueden ser personas morales (razón social larga y variada)
--   • Mezclan nombres propios con apellidos compuestos
--   • El OCR puede tener errores de mayúsculas/acentos
--   Un umbral ligeramente más bajo que el de agentes (0.80 vs 0.85) reduce
--   falsos negativos (duplicados) a costa de más candidatos por revisar.
-- =============================================================================

INSERT INTO configuracion_sistema (
    clave,
    valor,
    tipo_valor,
    descripcion,
    grupo,
    editable_por,
    aplica_ramo
)
VALUES (
    'FUZZY_MATCH_ASEGURADO',
    '0.80',
    'float',
    'Score mínimo de similitud pg_trgm (0-1) para considerar que un nombre '
    'extraído de documentos OCR corresponde a un asegurado ya registrado. '
    'Por debajo del umbral → se crea nuevo asegurado. '
    'Si múltiples candidatos superan el umbral → requiere_atencion = TRUE en el trámite. '
    'Recomendado: 0.80–0.85. Subir reduce duplicados pero aumenta escalaciones manuales.',
    'ia_umbrales',
    'director',
    NULL
)
ON CONFLICT (clave, aplica_ramo) DO NOTHING;


-- =============================================================================
-- SECCIÓN 3: FUNCIÓN buscar_o_crear_asegurado()
-- =============================================================================
-- Usada por el Agente 4 y el endpoint POST /asegurados/buscar-o-crear.
-- Implementa la cascada de resolución de identidad para asegurados.
--
-- Parámetros:
--   p_nombre            — nombre del asegurado extraído de documentos (obligatorio)
--   p_rfc               — RFC extraído (opcional; se normaliza a mayúsculas)
--   p_curp              — CURP extraída (opcional; se normaliza a mayúsculas)
--   p_tipo              — tipo_persona si se conoce (opcional)
--   p_fecha_nacimiento  — fecha de nacimiento si se conoce (opcional)
--   p_datos_adicionales — JSONB con datos adicionales del Agente 3 (opcional)
--   p_similitud_minima  — override del umbral (NULL = lee FUZZY_MATCH_ASEGURADO)
--
-- Retorna JSONB:
--   {
--     "asegurado_id":     "uuid" | null,
--     "accion":           "encontrado_por_rfc"
--                       | "encontrado_por_curp"
--                       | "encontrado_por_nombre"
--                       | "encontrado_por_rfc_race_condition"
--                       | "ambiguo"
--                       | "creado",
--     "requiere_atencion": true | false,
--     "candidatos": [    -- solo cuando accion = "ambiguo"
--       {"id": "...", "nombre": "...", "rfc": "...", "curp": "...", "similitud": 0.91}
--     ]
--   }
--
-- Cuando requiere_atencion = TRUE:
--   El Agente 4 debe actualizar tramite.requiere_atencion = TRUE y agregar
--   un tramite_evento con descripción de los candidatos para que el analista decida.
--
-- Seguridad:
--   SECURITY DEFINER — puede escribir en asegurado aunque el cliente sea authenticated.
--   El RLS de asegurado permite SELECT a todos los roles autenticados pero INSERT
--   solo via service_role. Este función actúa como la interfaz autorizada.
-- =============================================================================

CREATE OR REPLACE FUNCTION buscar_o_crear_asegurado(
    p_nombre            TEXT,
    p_rfc               TEXT            DEFAULT NULL,
    p_curp              TEXT            DEFAULT NULL,
    p_tipo              tipo_persona    DEFAULT NULL,
    p_fecha_nacimiento  DATE            DEFAULT NULL,
    p_datos_adicionales JSONB           DEFAULT '{}',
    p_similitud_minima  NUMERIC         DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_asegurado_id  UUID;
    v_candidatos    JSONB;
    v_count         INTEGER;
    v_umbral        NUMERIC;
    v_rfc_norm      TEXT;
    v_curp_norm     TEXT;
    v_nombre_norm   TEXT;
BEGIN
    -- -------------------------------------------------------------------------
    -- Normalizar inputs
    -- -------------------------------------------------------------------------
    v_nombre_norm := TRIM(p_nombre);
    v_rfc_norm    := NULLIF(UPPER(TRIM(COALESCE(p_rfc,  ''))), '');
    v_curp_norm   := NULLIF(UPPER(TRIM(COALESCE(p_curp, ''))), '');

    IF v_nombre_norm IS NULL OR v_nombre_norm = '' THEN
        RAISE EXCEPTION 'p_nombre no puede estar vacío'
            USING ERRCODE = 'check_violation';
    END IF;

    -- -------------------------------------------------------------------------
    -- Leer umbral de configuracion_sistema si no se provee como argumento
    -- -------------------------------------------------------------------------
    IF p_similitud_minima IS NULL THEN
        SELECT valor::NUMERIC
        INTO v_umbral
        FROM configuracion_sistema
        WHERE clave = 'FUZZY_MATCH_ASEGURADO'
          AND aplica_ramo IS NULL;

        v_umbral := COALESCE(v_umbral, 0.80);
    ELSE
        v_umbral := p_similitud_minima;
    END IF;

    -- =========================================================================
    -- PASO 1: Match exacto por RFC
    -- El RFC es el identificador fiscal oficial — único en toda la DB.
    -- =========================================================================
    IF v_rfc_norm IS NOT NULL THEN
        SELECT id INTO v_asegurado_id
        FROM asegurado
        WHERE rfc    = v_rfc_norm
          AND activo = TRUE;

        IF v_asegurado_id IS NOT NULL THEN
            -- Enriquecer con datos que antes faltaban (COALESCE preserva lo existente)
            UPDATE asegurado
            SET
                curp              = COALESCE(curp,             v_curp_norm),
                tipo              = COALESCE(tipo,             p_tipo),
                fecha_nacimiento  = COALESCE(fecha_nacimiento, p_fecha_nacimiento),
                datos_adicionales = datos_adicionales
                                    || COALESCE(p_datos_adicionales, '{}'),
                updated_at        = NOW()
            WHERE id = v_asegurado_id;

            RETURN jsonb_build_object(
                'asegurado_id',      v_asegurado_id,
                'accion',            'encontrado_por_rfc',
                'requiere_atencion', FALSE,
                'candidatos',        '[]'::jsonb
            );
        END IF;
    END IF;

    -- =========================================================================
    -- PASO 2: Match exacto por CURP
    -- La CURP es única para personas físicas — si la tenemos, es concluyente.
    -- =========================================================================
    IF v_curp_norm IS NOT NULL THEN
        SELECT id INTO v_asegurado_id
        FROM asegurado
        WHERE curp   = v_curp_norm
          AND activo = TRUE;

        IF v_asegurado_id IS NOT NULL THEN
            UPDATE asegurado
            SET
                rfc               = COALESCE(rfc,              v_rfc_norm),
                tipo              = COALESCE(tipo,             p_tipo),
                fecha_nacimiento  = COALESCE(fecha_nacimiento, p_fecha_nacimiento),
                datos_adicionales = datos_adicionales
                                    || COALESCE(p_datos_adicionales, '{}'),
                updated_at        = NOW()
            WHERE id = v_asegurado_id;

            RETURN jsonb_build_object(
                'asegurado_id',      v_asegurado_id,
                'accion',            'encontrado_por_curp',
                'requiere_atencion', FALSE,
                'candidatos',        '[]'::jsonb
            );
        END IF;
    END IF;

    -- =========================================================================
    -- PASO 3: Búsqueda fuzzy por nombre via pg_trgm
    -- Solo cuando RFC y CURP no dieron match — son los identificadores fuertes.
    -- El índice GIN en asegurado.nombre (gin_trgm_ops) hace esto eficiente.
    -- =========================================================================
    SELECT jsonb_agg(
        jsonb_build_object(
            'id',        id,
            'nombre',    nombre,
            'rfc',       rfc,
            'curp',      curp,
            'similitud', ROUND(similitud::numeric, 3)
        )
        ORDER BY similitud DESC
    )
    INTO v_candidatos
    FROM (
        SELECT
            id,
            nombre,
            rfc,
            curp,
            similarity(LOWER(nombre), LOWER(v_nombre_norm)) AS similitud
        FROM asegurado
        WHERE activo  = TRUE
          AND similarity(LOWER(nombre), LOWER(v_nombre_norm)) >= v_umbral
        ORDER BY similarity(LOWER(nombre), LOWER(v_nombre_norm)) DESC
        LIMIT 5
    ) candidatos_fuzzy;

    v_candidatos := COALESCE(v_candidatos, '[]'::jsonb);
    v_count      := jsonb_array_length(v_candidatos);

    -- Un único candidato por encima del umbral → match inequívoco
    IF v_count = 1 THEN
        v_asegurado_id := (v_candidatos -> 0 ->> 'id')::UUID;

        UPDATE asegurado
        SET
            rfc               = COALESCE(rfc,              v_rfc_norm),
            curp              = COALESCE(curp,             v_curp_norm),
            tipo              = COALESCE(tipo,             p_tipo),
            fecha_nacimiento  = COALESCE(fecha_nacimiento, p_fecha_nacimiento),
            datos_adicionales = datos_adicionales
                                || COALESCE(p_datos_adicionales, '{}'),
            updated_at        = NOW()
        WHERE id = v_asegurado_id;

        RETURN jsonb_build_object(
            'asegurado_id',      v_asegurado_id,
            'accion',            'encontrado_por_nombre',
            'requiere_atencion', FALSE,
            'candidatos',        v_candidatos
        );
    END IF;

    -- Múltiples candidatos → identidad ambigua, el analista debe decidir
    IF v_count > 1 THEN
        RETURN jsonb_build_object(
            'asegurado_id',      NULL,
            'accion',            'ambiguo',
            'requiere_atencion', TRUE,
            'candidatos',        v_candidatos
        );
    END IF;

    -- =========================================================================
    -- PASO 4: No encontrado → crear nuevo registro de asegurado
    -- Maneja race conditions: si dos transacciones concurrentes intentan crear
    -- el mismo RFC/CURP, la segunda captura la unique_violation y hace lookup.
    -- =========================================================================
    BEGIN
        INSERT INTO asegurado (
            nombre,
            rfc,
            curp,
            tipo,
            fecha_nacimiento,
            datos_adicionales
        ) VALUES (
            v_nombre_norm,
            v_rfc_norm,
            v_curp_norm,
            p_tipo,
            p_fecha_nacimiento,
            COALESCE(p_datos_adicionales, '{}')
        )
        RETURNING id INTO v_asegurado_id;

    EXCEPTION
        WHEN unique_violation THEN
            -- Race condition: otro proceso insertó el mismo RFC/CURP en paralelo.
            -- Reintentar lookup por los identificadores únicos.
            v_asegurado_id := NULL;

            IF v_rfc_norm IS NOT NULL THEN
                SELECT id INTO v_asegurado_id
                FROM asegurado WHERE rfc = v_rfc_norm AND activo = TRUE;
            END IF;

            IF v_asegurado_id IS NULL AND v_curp_norm IS NOT NULL THEN
                SELECT id INTO v_asegurado_id
                FROM asegurado WHERE curp = v_curp_norm AND activo = TRUE;
            END IF;

            IF v_asegurado_id IS NOT NULL THEN
                RETURN jsonb_build_object(
                    'asegurado_id',      v_asegurado_id,
                    'accion',            'encontrado_por_rfc_race_condition',
                    'requiere_atencion', FALSE,
                    'candidatos',        '[]'::jsonb
                );
            END IF;

            -- Si el lookup post-error tampoco encontró nada, es un error real
            RAISE EXCEPTION 'unique_violation sin RFC ni CURP recuperable: nombre=%, rfc=%, curp=%',
                v_nombre_norm, v_rfc_norm, v_curp_norm;
    END;

    RETURN jsonb_build_object(
        'asegurado_id',      v_asegurado_id,
        'accion',            'creado',
        'requiere_atencion', FALSE,
        'candidatos',        '[]'::jsonb
    );
END;
$$;

COMMENT ON FUNCTION buscar_o_crear_asegurado(TEXT, TEXT, TEXT, tipo_persona, DATE, JSONB, NUMERIC) IS
    'Resolución de identidad de asegurados para el Agente 4. '
    'Cascada: RFC exacto → CURP exacto → fuzzy por nombre (pg_trgm) → crear nuevo. '
    'Cuando requiere_atencion = TRUE el Agente 4 propaga el flag al trámite y '
    'agrega un tramite_evento con los candidatos para revisión humana. '
    'Maneja race conditions con EXCEPTION WHEN unique_violation.';

-- Ambos roles lo necesitan: service_role (Agente 4), authenticated (endpoint FastAPI)
GRANT EXECUTE ON FUNCTION buscar_o_crear_asegurado(TEXT, TEXT, TEXT, tipo_persona, DATE, JSONB, NUMERIC)
    TO authenticated, service_role;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000026_cierre_gaps_pipeline.sql
-- =============================================================================

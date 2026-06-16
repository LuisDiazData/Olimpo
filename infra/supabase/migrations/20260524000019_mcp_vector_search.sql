-- =============================================================================
-- Migración: 20260524000019_mcp_vector_search.sql
-- Funciones SQL para búsqueda vectorial — consumidas por el servidor MCP
-- =============================================================================
-- Estas funciones son el contrato entre el MCP server y la base de datos.
-- El MCP las llama via supabase.rpc() con el service_role key.
--
-- Diseño de seguridad:
--   - SECURITY DEFINER: corren con los privilegios del owner (postgres/service),
--     no con los del llamador. Esto permite que el MCP use una conexión anon
--     si fuera necesario, sin exponer datos a usuarios no autorizados.
--   - SET search_path = public, pg_catalog: previene inyección de search_path.
--   - Los agentes MCP usan service_role directamente — SECURITY DEFINER es
--     principalmente para documentar la intención de acceso.
--
-- Funciones incluidas:
--   1. buscar_rag_gnp          — conocimiento estático de GNP (Agente 5)
--   2. buscar_rag_poliza        — historial de pólizas (Agente 5)
--   3. buscar_rag_aprendizaje   — rechazos históricos (Agente 5)
--   4. buscar_agente_fuzzy      — búsqueda por nombre aproximado (Agente 4)
--   5. obtener_config_agentes   — todos los umbrales de IA en un solo fetch
-- =============================================================================


-- =============================================================================
-- FUNCIÓN 1: buscar_rag_gnp
-- Búsqueda semántica en la base de conocimiento de GNP.
-- El Agente 5 la llama para obtener requisitos y criterios antes de validar.
--
-- Parámetros:
--   p_embedding        — vector generado por text-embedding-3-small (1536 dims)
--   p_ramo             — filtrar por ramo ANTES del vector search (performance)
--   p_tipo_tramite     — filtrar por tipo de trámite
--   p_tipo_documento   — filtrar por tipo de documento
--   p_limite           — máximo de resultados (default 5)
--   p_umbral_similitud — similitud mínima coseno (default 0.65)
--
-- Returns: tabla con id, contenido, metadatos, similitud
-- =============================================================================

CREATE OR REPLACE FUNCTION buscar_rag_gnp(
    p_embedding         vector(1536),
    p_ramo              text    DEFAULT NULL,
    p_tipo_tramite      text    DEFAULT NULL,
    p_tipo_documento    text    DEFAULT NULL,
    p_limite            integer DEFAULT 5,
    p_umbral_similitud  float   DEFAULT 0.65
)
RETURNS TABLE (
    id              uuid,
    contenido       text,
    tipo_fuente     text,
    titulo_fuente   text,
    ramo            text,
    tipo_tramite    text,
    tipo_documento  text,
    tags            text[],
    similitud       float
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT
        r.id,
        r.contenido,
        r.tipo_fuente::text,
        r.titulo_fuente,
        r.ramo::text,
        r.tipo_tramite::text,
        r.tipo_documento::text,
        r.tags,
        (1 - (r.embedding <=> p_embedding))::float AS similitud
    FROM rag_gnp r
    WHERE r.vigente = TRUE
      AND r.embedding IS NOT NULL
      AND (p_ramo IS NULL OR r.ramo::text = p_ramo)
      AND (p_tipo_tramite IS NULL OR r.tipo_tramite::text = p_tipo_tramite)
      AND (p_tipo_documento IS NULL OR r.tipo_documento::text = p_tipo_documento)
      AND (1 - (r.embedding <=> p_embedding)) >= p_umbral_similitud
    ORDER BY r.embedding <=> p_embedding
    LIMIT p_limite;
$$;

COMMENT ON FUNCTION buscar_rag_gnp(vector, text, text, text, integer, float) IS
    'Búsqueda semántica en el conocimiento de GNP. '
    'Pre-filtra por ramo/tipo/documento antes del vector search para máxima precisión. '
    'Llamada por el Agente 5 (Validación) vía el MCP server.';

GRANT EXECUTE ON FUNCTION buscar_rag_gnp(vector, text, text, text, integer, float)
    TO authenticated, service_role;


-- =============================================================================
-- FUNCIÓN 2: buscar_rag_poliza
-- Búsqueda semántica en el historial de pólizas procesadas.
-- El Agente 5 la llama para obtener contexto histórico de una póliza/agente.
--
-- Parámetros:
--   p_embedding   — vector de búsqueda
--   p_poliza_id   — filtrar por póliza específica (opcional)
--   p_agente_cua  — filtrar por CUA del agente (opcional)
--   p_ramo        — filtrar por ramo (opcional)
--   p_tipo_chunk  — filtrar por tipo de evento (opcional)
--   p_limite      — máximo de resultados (default 5)
--   p_umbral      — similitud mínima (default 0.60 — historial puede ser menos preciso)
-- =============================================================================

CREATE OR REPLACE FUNCTION buscar_rag_poliza(
    p_embedding     vector(1536),
    p_poliza_id     uuid    DEFAULT NULL,
    p_agente_cua    text    DEFAULT NULL,
    p_ramo          text    DEFAULT NULL,
    p_tipo_chunk    text    DEFAULT NULL,
    p_limite        integer DEFAULT 5,
    p_umbral        float   DEFAULT 0.60
)
RETURNS TABLE (
    id              uuid,
    contenido       text,
    tramite_id      uuid,
    poliza_id       uuid,
    tipo_chunk      text,
    ramo            text,
    agente_cua      text,
    similitud       float,
    created_at      timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT
        r.id,
        r.contenido,
        r.tramite_id,
        r.poliza_id,
        r.tipo_chunk::text,
        r.ramo::text,
        r.agente_cua,
        (1 - (r.embedding <=> p_embedding))::float AS similitud,
        r.created_at
    FROM rag_poliza r
    WHERE r.embedding IS NOT NULL
      AND (p_poliza_id IS NULL OR r.poliza_id = p_poliza_id)
      AND (p_agente_cua IS NULL OR r.agente_cua = p_agente_cua)
      AND (p_ramo IS NULL OR r.ramo::text = p_ramo)
      AND (p_tipo_chunk IS NULL OR r.tipo_chunk::text = p_tipo_chunk)
      AND (1 - (r.embedding <=> p_embedding)) >= p_umbral
    ORDER BY r.embedding <=> p_embedding
    LIMIT p_limite;
$$;

COMMENT ON FUNCTION buscar_rag_poliza(vector, uuid, text, text, text, integer, float) IS
    'Búsqueda semántica en el historial de pólizas. '
    'Contexto dinámico que crece con cada trámite procesado. '
    'Pre-filtrar por poliza_id o agente_cua para mayor precisión.';

GRANT EXECUTE ON FUNCTION buscar_rag_poliza(vector, uuid, text, text, text, integer, float)
    TO authenticated, service_role;


-- =============================================================================
-- FUNCIÓN 3: buscar_rag_aprendizaje
-- Búsqueda en la memoria de rechazos de GNP.
-- El Agente 5 la llama ANTES de validar para anticipar rechazos conocidos.
-- Solo retorna aprendizajes validados y no descartados para evitar ruido.
-- =============================================================================

CREATE OR REPLACE FUNCTION buscar_rag_aprendizaje(
    p_embedding         vector(1536),
    p_ramo              text    DEFAULT NULL,
    p_tipo_tramite      text    DEFAULT NULL,
    p_tipo_documento    text    DEFAULT NULL,
    p_solo_resueltos    boolean DEFAULT FALSE,
    p_limite            integer DEFAULT 5,
    p_umbral            float   DEFAULT 0.65
)
RETURNS TABLE (
    id                  uuid,
    contenido           text,
    ramo                text,
    tipo_tramite        text,
    tipo_documento      text,
    motivo_rechazo      text,
    correccion_aplicada text,
    resuelto            boolean,
    similitud           float
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT
        r.id,
        r.contenido,
        r.ramo::text,
        r.tipo_tramite::text,
        r.tipo_documento::text,
        r.motivo_rechazo,
        r.correccion_aplicada,
        r.resuelto,
        (1 - (r.embedding <=> p_embedding))::float AS similitud
    FROM rag_aprendizaje r
    WHERE r.embedding IS NOT NULL
      AND r.aprendizaje_validado = TRUE
      AND r.descartado = FALSE
      AND (p_ramo IS NULL OR r.ramo::text = p_ramo)
      AND (p_tipo_tramite IS NULL OR r.tipo_tramite::text = p_tipo_tramite)
      AND (p_tipo_documento IS NULL OR r.tipo_documento::text = p_tipo_documento)
      AND (NOT p_solo_resueltos OR r.resuelto = TRUE)
      AND (1 - (r.embedding <=> p_embedding)) >= p_umbral
    ORDER BY r.embedding <=> p_embedding
    LIMIT p_limite;
$$;

COMMENT ON FUNCTION buscar_rag_aprendizaje(vector, text, text, text, boolean, integer, float) IS
    'Búsqueda en rechazos históricos de GNP. Solo retorna aprendizajes validados. '
    'El Agente 5 llama esto primero para anticipar rechazos antes de validar documentos.';

GRANT EXECUTE ON FUNCTION buscar_rag_aprendizaje(vector, text, text, text, boolean, integer, float)
    TO authenticated, service_role;


-- =============================================================================
-- FUNCIÓN 4: buscar_agente_fuzzy
-- Búsqueda aproximada de agentes de seguros por nombre.
-- El Agente 4 la usa para CUA cascade: si el CUA exacto falla, busca por nombre.
-- Usa pg_trgm (índice GIN ya creado en migraciones anteriores).
-- =============================================================================

CREATE OR REPLACE FUNCTION buscar_agente_fuzzy(
    p_nombre        text,
    p_ramo          text    DEFAULT NULL,
    p_activo        boolean DEFAULT TRUE,
    p_limite        integer DEFAULT 5,
    p_umbral_trgm   float   DEFAULT 0.30
)
RETURNS TABLE (
    id              uuid,
    nombre          text,
    cua             text,
    email           text,
    ramo            text,
    similitud_trgm  float
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT
        a.id,
        a.nombre,
        a.cua,
        (SELECT email FROM agente_email ae WHERE ae.agente_id = a.id AND ae.preferente = TRUE LIMIT 1) AS email,
        NULL::text AS ramo,
        similarity(a.nombre, p_nombre) AS similitud_trgm
    FROM agente a
    WHERE a.activo = p_activo
      AND similarity(a.nombre, p_nombre) >= p_umbral_trgm
    ORDER BY similarity(a.nombre, p_nombre) DESC
    LIMIT p_limite;
$$;

COMMENT ON FUNCTION buscar_agente_fuzzy(text, text, boolean, integer, float) IS
    'Búsqueda por nombre aproximado de agentes de seguros usando pg_trgm. '
    'El Agente 4 la usa en la cascada CUA cuando el match exacto falla. '
    'Requiere índice GIN en agente.nombre (creado en módulo 02).';

GRANT EXECUTE ON FUNCTION buscar_agente_fuzzy(text, text, boolean, integer, float)
    TO authenticated, service_role;


-- =============================================================================
-- FUNCIÓN 5: obtener_config_agentes
-- Retorna todos los parámetros de configuración necesarios para los agentes IA.
-- El MCP llama esto una vez al inicio de cada pipeline para cachear los valores.
-- Evita múltiples round-trips a la DB por parámetro individual.
-- =============================================================================

CREATE OR REPLACE FUNCTION obtener_config_agentes()
RETURNS TABLE (
    clave       text,
    valor       text,
    tipo_valor  text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT
        c.clave,
        c.valor,
        c.tipo_valor
    FROM configuracion_sistema c
    WHERE c.clave IN (
        'CONFIDENCE_AGENTE',
        'CONFIDENCE_DOCUMENTO',
        'CONFIDENCE_VINCULACION',
        'FUZZY_MATCH_NOMBRE',
        'TIMEOUT_PASSWORD_HORAS',
        'UMBRAL_SIMILITUD_RAG_GNP',
        'UMBRAL_SIMILITUD_RAG_POLIZA',
        'UMBRAL_SIMILITUD_RAG_APRENDIZAJE',
        'MAX_RESULTADOS_RAG',
        'MAX_REINTENTOS_PIPELINE'
    )
    ORDER BY c.clave;
$$;

COMMENT ON FUNCTION obtener_config_agentes() IS
    'Retorna todos los parámetros de IA relevantes en un solo fetch. '
    'El MCP server la llama al inicio del pipeline para evitar round-trips adicionales.';

GRANT EXECUTE ON FUNCTION obtener_config_agentes()
    TO authenticated, service_role;


-- =============================================================================
-- FUNCIÓN 6: cambiar_estado_tramite
-- Transición de la máquina de estados del trámite con validación de secuencia.
-- Registra automáticamente el evento en tramite_evento.
-- Solo el MCP (via service_role) puede llamar esta función.
-- =============================================================================

CREATE OR REPLACE FUNCTION cambiar_estado_tramite(
    p_tramite_id        uuid,
    p_estado_nuevo      estado_tramite,
    p_descripcion       text        DEFAULT 'Cambio de estado vía agente IA',
    p_agente_ia_nombre  text        DEFAULT NULL,  -- 'agente_1'..'agente_6' si actor es IA
    p_usuario_id        uuid        DEFAULT NULL,  -- UUID si actor es humano (analista)
    p_datos             jsonb       DEFAULT '{}'
)
RETURNS TABLE (
    ok              boolean,
    estado_anterior text,
    estado_nuevo    text,
    evento_id       uuid,
    error_msg       text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_tramite       tramite%ROWTYPE;
    v_evento_id     uuid;
    v_error         text;
BEGIN
    -- Leer estado actual con lock para prevenir condiciones de carrera
    SELECT * INTO v_tramite
    FROM tramite
    WHERE id = p_tramite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::text, NULL::text, NULL::uuid,
                            'Trámite no encontrado: ' || p_tramite_id::text;
        RETURN;
    END IF;

    -- Validar transiciones permitidas por la máquina de estados
    v_error := NULL;
    CASE v_tramite.estado
        WHEN 'recibido' THEN
            IF p_estado_nuevo NOT IN ('validando', 'rechazado') THEN
                v_error := 'Desde recibido solo se puede ir a: validando, rechazado';
            END IF;
        WHEN 'validando' THEN
            IF p_estado_nuevo NOT IN ('pendiente_documentos', 'completo', 'rechazado') THEN
                v_error := 'Desde validando solo se puede ir a: pendiente_documentos, completo, rechazado';
            END IF;
        WHEN 'pendiente_documentos' THEN
            IF p_estado_nuevo NOT IN ('validando', 'completo', 'rechazado') THEN
                v_error := 'Desde pendiente_documentos solo se puede ir a: validando, completo, rechazado';
            END IF;
        WHEN 'completo' THEN
            IF p_estado_nuevo NOT IN ('turnado_gnp', 'pendiente_documentos', 'rechazado') THEN
                v_error := 'Desde completo solo se puede ir a: turnado_gnp, pendiente_documentos, rechazado';
            END IF;
        WHEN 'turnado_gnp' THEN
            IF p_estado_nuevo NOT IN ('en_proceso_gnp', 'rechazado') THEN
                v_error := 'Desde turnado_gnp solo se puede ir a: en_proceso_gnp, rechazado';
            END IF;
        WHEN 'en_proceso_gnp' THEN
            IF p_estado_nuevo NOT IN ('activado', 'rechazado') THEN
                v_error := 'Desde en_proceso_gnp solo se puede ir a: activado, rechazado';
            END IF;
        WHEN 'activado' THEN
            IF p_estado_nuevo NOT IN ('aprobado', 'activado', 'rechazado') THEN
                v_error := 'Desde activado solo se puede ir a: aprobado, activado (endosos), rechazado';
            END IF;
        WHEN 'aprobado' THEN
            v_error := 'El trámite ya está aprobado — estado final';
        WHEN 'rechazado' THEN
            v_error := 'El trámite ya está rechazado — estado final';
        ELSE
            v_error := 'Estado actual desconocido: ' || v_tramite.estado::text;
    END CASE;

    IF v_error IS NOT NULL THEN
        RETURN QUERY SELECT FALSE,
                            v_tramite.estado::text,
                            p_estado_nuevo::text,
                            NULL::uuid,
                            v_error;
        RETURN;
    END IF;

    -- Ejecutar la transición
    UPDATE tramite
    SET estado           = p_estado_nuevo,
        ultima_actividad = NOW(),
        updated_at       = NOW()
    WHERE id = p_tramite_id;

    -- Registrar evento en el historial inmutable usando columnas reales de tramite_evento
    INSERT INTO tramite_evento (
        tramite_id, tipo_evento, estado_anterior, estado_nuevo,
        descripcion, agente_ia_nombre, usuario_id, datos
    )
    VALUES (
        p_tramite_id,
        'cambio_estado',
        v_tramite.estado,
        p_estado_nuevo,
        p_descripcion,
        p_agente_ia_nombre,
        p_usuario_id,
        p_datos
    )
    RETURNING id INTO v_evento_id;

    RETURN QUERY SELECT TRUE,
                        v_tramite.estado::text,
                        p_estado_nuevo::text,
                        v_evento_id,
                        NULL::text;
END;
$$;

COMMENT ON FUNCTION cambiar_estado_tramite(uuid, estado_tramite, text, text, uuid, jsonb) IS
    'Transición segura de la máquina de estados del trámite. '
    'Valida la secuencia, actualiza tramite con SELECT FOR UPDATE, registra tramite_evento. '
    'Llamada exclusivamente por el MCP server vía service_role.';

GRANT EXECUTE ON FUNCTION cambiar_estado_tramite(uuid, estado_tramite, text, text, uuid, jsonb)
    TO service_role;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000019_mcp_vector_search.sql
-- =============================================================================

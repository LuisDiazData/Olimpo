-- =============================================================================
-- Migración: 20260522000009_modulo_10_auditoria.sql
-- Módulo 10 — Auditoría completa: cambios en tablas y ejecución de agentes IA
-- =============================================================================
-- Dos tablas con responsabilidades distintas:
--
--   audit_log      → Registro inmutable de QUIÉN cambió QUÉ y CUÁNDO en las
--                    tablas críticas del CRM. Captura el estado antes y después
--                    (diff completo en JSONB). Alimentado por un trigger genérico
--                    que se adjunta a cualquier tabla.
--
--   agente_ia_log  → Registro de cada ejecución de los 6 agentes IA. Lleva
--                    métricas de rendimiento (tokens, costo, duración), el trace
--                    de Langfuse para correlación, y el resultado estructurado.
--                    El backend lo escribe — no hay trigger.
--
-- Tablas auditadas por audit_log (trigger adjuntado en esta migración):
--   usuario            — altas, bajas, cambios de rol/ramo/firma
--   agente             — cambios en el catálogo de agentes
--   asignacion         — cambios en reglas de enrutamiento agente→analista
--   sla_definicion     — cambios en parámetros de SLA (qué director lo cambió)
--   dia_inhabil        — cambios en el calendario de días no laborables
--   notificacion_config — cambios en preferencias de notificación
--
-- Tablas NO auditadas por audit_log (tienen su propio mecanismo):
--   tramite_evento     — append-only por diseño: ya es el historial inmutable
--   notificacion       — volumen muy alto, baja relevancia de auditoría
--   rag_poliza         — append-only por diseño
--   agente_ia_log      — logs de IA, no tiene sentido auditarse a sí mismo
--
-- Regla de seguridad crítica:
--   audit_log y agente_ia_log son append-only para authenticated.
--   Solo service_role puede escribir en ellos (triggers y agentes IA).
--   Nadie puede modificar ni borrar registros de auditoría.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE estado_agente_ia AS ENUM (
    'iniciado',     -- el agente arrancó, está procesando
    'completado',   -- terminó sin errores
    'fallido'       -- terminó con error — ver columna error
);

COMMENT ON TYPE estado_agente_ia IS
    'Estado de ejecución de un agente IA. '
    'Iniciado → en proceso. Completado → éxito. Fallido → error con detalle en .error.';


-- =============================================================================
-- SECCIÓN 2: TABLA audit_log
-- =============================================================================
-- Registro inmutable de cambios en tablas críticas del CRM.
-- Cada fila captura UNA operación (INSERT / UPDATE / DELETE) sobre UNA fila
-- de UNA tabla, con el estado completo antes y después.
--
-- APPEND-ONLY: ningún usuario autenticado puede modificar ni eliminar registros.
-- Solo service_role via el trigger audit_table_change() puede insertar.
--
-- Columnas sensibles excluidas:
--   adjunto.password — el trigger la elimina del JSONB antes de persistir.
-- =============================================================================

CREATE TABLE audit_log (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- QUÉ cambió
    -- -------------------------------------------------------------------------
    -- Nombre de la tabla afectada (TG_TABLE_NAME en el trigger)
    tabla           TEXT            NOT NULL,
    -- PK del registro afectado (siempre UUID en este sistema, guardado como TEXT)
    registro_id     TEXT            NOT NULL,
    -- Tipo de operación
    operacion       TEXT            NOT NULL
                    CHECK (operacion IN ('INSERT', 'UPDATE', 'DELETE')),

    -- Estado completo de la fila ANTES del cambio (NULL para INSERT)
    antes           JSONB           NULL,
    -- Estado completo de la fila DESPUÉS del cambio (NULL para DELETE)
    despues         JSONB           NULL,

    -- -------------------------------------------------------------------------
    -- QUIÉN hizo el cambio
    -- -------------------------------------------------------------------------
    -- Usuario humano que ejecutó la operación (NULL si fue un agente IA)
    usuario_id      UUID            NULL REFERENCES usuario(id),
    -- Agente IA que ejecutó la operación (NULL si fue un humano)
    -- Valores: 'agente_1' a 'agente_6', o nombre del proceso de sistema
    agente_ia_nombre TEXT           NULL,

    -- -------------------------------------------------------------------------
    -- CUÁNDO — sin updated_at porque es inmutable
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_audit_operacion_consistente CHECK (
        (operacion = 'INSERT' AND antes IS NULL     AND despues IS NOT NULL)
        OR (operacion = 'UPDATE' AND antes IS NOT NULL AND despues IS NOT NULL)
        OR (operacion = 'DELETE' AND antes IS NOT NULL AND despues IS NULL)
    )
);

COMMENT ON TABLE audit_log IS
    'Registro inmutable de cambios en tablas críticas del CRM. '
    'Append-only: ningún usuario autenticado puede modificar ni eliminar filas. '
    'El trigger audit_table_change() lo alimenta automáticamente.';

COMMENT ON COLUMN audit_log.tabla        IS 'Nombre de la tabla PostgreSQL afectada (ej: "tramite", "usuario").';
COMMENT ON COLUMN audit_log.registro_id  IS 'UUID del registro afectado, guardado como TEXT para universalidad.';
COMMENT ON COLUMN audit_log.antes        IS 'Estado completo de la fila ANTES del cambio. NULL para INSERT. Columnas sensibles excluidas.';
COMMENT ON COLUMN audit_log.despues      IS 'Estado completo de la fila DESPUÉS del cambio. NULL para DELETE. Columnas sensibles excluidas.';
COMMENT ON COLUMN audit_log.usuario_id   IS 'Actor humano. NULL si el cambio fue hecho por un agente IA o proceso del sistema.';
COMMENT ON COLUMN audit_log.agente_ia_nombre IS 'Actor IA. NULL si fue un humano. Lee de app.agente_ia_actual (mismo patrón que tramite_evento).';


-- =============================================================================
-- SECCIÓN 3: TABLA agente_ia_log
-- =============================================================================
-- Registro de cada ejecución de los 6 agentes IA.
-- El backend (Celery workers) lo escribe directamente con service_role.
--
-- Flujo de escritura en Python:
--   # Al arrancar el agente:
--   log = supabase.table('agente_ia_log').insert({
--       'agente_nombre': 'agente_5',
--       'tramite_id': str(tramite_id),
--       'estado': 'iniciado',
--       'langfuse_trace_id': langfuse.trace().id
--   }).execute().data[0]
--
--   # Al terminar (éxito):
--   supabase.table('agente_ia_log').update({
--       'estado': 'completado',
--       'fin': datetime.utcnow().isoformat(),
--       'duracion_ms': elapsed_ms,
--       'tokens_entrada': usage.prompt_tokens,
--       'tokens_salida': usage.completion_tokens,
--       'costo_usd': cost,
--       'modelo_llm': 'claude-sonnet-4-6',
--       'resultado': {'docs_validos': 3, 'docs_faltantes': ['carta_medica']}
--   }).eq('id', log['id']).execute()
--
--   # Al terminar (error):
--   supabase.table('agente_ia_log').update({
--       'estado': 'fallido',
--       'fin': datetime.utcnow().isoformat(),
--       'duracion_ms': elapsed_ms,
--       'error': str(exception)
--   }).eq('id', log['id']).execute()
-- =============================================================================

CREATE TABLE agente_ia_log (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                  UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Qué agente corrió y sobre qué
    -- -------------------------------------------------------------------------
    -- Nombre canónico: 'agente_1' a 'agente_6'
    agente_nombre       TEXT                NOT NULL
                        CHECK (agente_nombre IN (
                            'agente_1', 'agente_2', 'agente_3',
                            'agente_4', 'agente_5', 'agente_6'
                        )),

    -- Trámite procesado (NULL solo si el agente no tiene trámite aún — ej: Agente 1 al inicio)
    tramite_id          UUID                NULL REFERENCES tramite(id),

    -- Correo que disparó la ejecución (Agentes 1 y 2 siempre lo tienen)
    correo_id           UUID                NULL REFERENCES correo(id),

    -- -------------------------------------------------------------------------
    -- Estado y tiempos
    -- -------------------------------------------------------------------------
    estado              estado_agente_ia    NOT NULL DEFAULT 'iniciado',
    inicio              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    fin                 TIMESTAMPTZ         NULL,
    -- Calculado por el backend: (fin - inicio) en milisegundos
    duracion_ms         INTEGER             NULL CHECK (duracion_ms >= 0),

    -- -------------------------------------------------------------------------
    -- Reintento — Celery puede reintentar tareas fallidas
    -- -------------------------------------------------------------------------
    intento             SMALLINT            NOT NULL DEFAULT 1
                        CHECK (intento >= 1),

    -- -------------------------------------------------------------------------
    -- Trazabilidad con Langfuse
    -- -------------------------------------------------------------------------
    -- ID del trace en Langfuse — permite cruzar este log con el dashboard de LLM
    langfuse_trace_id   TEXT                NULL,

    -- -------------------------------------------------------------------------
    -- Métricas de LLM (pueden ser NULL si el agente no llamó LLMs directamente)
    -- -------------------------------------------------------------------------
    -- Modelo principal usado (puede haber llamadas a múltiples modelos por agente)
    modelo_llm          TEXT                NULL,
    tokens_entrada      INTEGER             NULL CHECK (tokens_entrada >= 0),
    tokens_salida       INTEGER             NULL CHECK (tokens_salida >= 0),
    -- Costo calculado por LiteLLM — hasta 6 decimales (fracciones de centavo)
    costo_usd           NUMERIC(10, 6)      NULL CHECK (costo_usd >= 0),

    -- -------------------------------------------------------------------------
    -- Resultado estructurado y error
    -- -------------------------------------------------------------------------
    -- Resumen del output del agente. Estructura varía por agente:
    --   agente_1: { adjuntos: 3, zips: 1, archivos_extraidos: 5 }
    --   agente_2: { confianza_agente: 0.92, tipo_tramite: 'alta', ramo: 'gmm' }
    --   agente_3: { documentos_ocr: ['INE', 'solicitud'], ilegibles: [] }
    --   agente_4: { metodo_id: 'cua_directo', confianza: 0.97, analista_asignado: 'uuid' }
    --   agente_5: { docs_validos: 3, docs_faltantes: ['carta_medica'], chunks_rag_usados: 5 }
    --   agente_6: { correo_id: 'uuid', palabras: 245, revisado: false }
    resultado           JSONB               NULL DEFAULT '{}',

    -- Mensaje de error completo si estado='fallido' (traceback de Python)
    error               TEXT                NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS de consistencia
    -- -------------------------------------------------------------------------

    -- Si terminó, debe tener fin y duración
    CONSTRAINT ck_agente_log_fin_consistente CHECK (
        estado = 'iniciado'
        OR (fin IS NOT NULL AND duracion_ms IS NOT NULL)
    ),

    -- Error solo en estado fallido
    CONSTRAINT ck_agente_log_error_consistente CHECK (
        error IS NULL OR estado = 'fallido'
    ),

    -- Tokens y costo solo si hay modelo
    CONSTRAINT ck_agente_log_tokens_consistente CHECK (
        modelo_llm IS NOT NULL
        OR (tokens_entrada IS NULL AND tokens_salida IS NULL AND costo_usd IS NULL)
    )
);

COMMENT ON TABLE agente_ia_log IS
    'Log de ejecución de los 6 agentes IA. Escrito directamente por el backend con service_role. '
    'Vinculado a Langfuse via langfuse_trace_id para correlación de trazas LLM. '
    'Permite medir rendimiento, detectar cuellos de botella y calcular costos por trámite.';

COMMENT ON COLUMN agente_ia_log.langfuse_trace_id IS
    'ID del trace en Langfuse. Permite ver todas las llamadas LLM de esta ejecución '
    'en el dashboard de Langfuse con un solo clic desde la UI del Superadmin.';
COMMENT ON COLUMN agente_ia_log.costo_usd IS
    'Costo en USD calculado por LiteLLM router. '
    'Permite al Superadmin ver el costo por trámite y por agente.';
COMMENT ON COLUMN agente_ia_log.intento IS
    'Número de intento. Celery puede reintentar tareas fallidas — '
    'cada intento genera una nueva fila con intento = intento_anterior + 1.';


-- =============================================================================
-- SECCIÓN 4: ÍNDICES
-- =============================================================================

-- audit_log ———————————————————————————————————————————————————————————————————

-- Buscar todos los cambios en un registro específico (timeline de auditoría)
CREATE INDEX idx_audit_registro
    ON audit_log (tabla, registro_id, created_at DESC);

COMMENT ON INDEX idx_audit_registro IS
    'Historial de cambios de un registro específico: tabla + id, ordenado por tiempo.';

-- Buscar todas las acciones de un usuario (¿qué hizo este analista hoy?)
CREATE INDEX idx_audit_usuario
    ON audit_log (usuario_id, created_at DESC)
    WHERE usuario_id IS NOT NULL;

-- Buscar acciones de un agente IA (debugging del pipeline)
CREATE INDEX idx_audit_agente_ia
    ON audit_log (agente_ia_nombre, created_at DESC)
    WHERE agente_ia_nombre IS NOT NULL;

-- Buscar cambios en una tabla entera (¿quién modificó sla_definicion esta semana?)
CREATE INDEX idx_audit_tabla_fecha
    ON audit_log (tabla, created_at DESC);

-- agente_ia_log ———————————————————————————————————————————————————————————————

-- Dashboard del Superadmin: ejecuciones recientes por agente
CREATE INDEX idx_agente_log_agente_inicio
    ON agente_ia_log (agente_nombre, inicio DESC);

-- Timeline de un trámite: qué agentes procesaron este trámite y cuándo
CREATE INDEX idx_agente_log_tramite
    ON agente_ia_log (tramite_id, inicio DESC)
    WHERE tramite_id IS NOT NULL;

-- Detectar ejecuciones fallidas recientes (alertas de salud del pipeline)
CREATE INDEX idx_agente_log_fallidos
    ON agente_ia_log (agente_nombre, inicio DESC)
    WHERE estado = 'fallido';

COMMENT ON INDEX idx_agente_log_fallidos IS
    'Monitoreo de salud: ejecuciones fallidas por agente. '
    'El Superadmin usa este índice en la vista de "Agent Health" (Fase 7 del roadmap).';

-- Costo acumulado por período (para reportes de gasto en LLMs)
CREATE INDEX idx_agente_log_costo
    ON agente_ia_log (inicio DESC)
    WHERE costo_usd IS NOT NULL;

-- Correlación con Langfuse
CREATE INDEX idx_agente_log_langfuse
    ON agente_ia_log (langfuse_trace_id)
    WHERE langfuse_trace_id IS NOT NULL;


-- =============================================================================
-- SECCIÓN 5: TRIGGERS — updated_at en agente_ia_log
-- =============================================================================

CREATE TRIGGER trg_agente_ia_log_updated_at
    BEFORE UPDATE ON agente_ia_log
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 6: FUNCIÓN audit_table_change() — trigger genérico de auditoría
-- =============================================================================
-- Función que cualquier tabla puede usar creando su propio trigger:
--
--   CREATE TRIGGER trg_<tabla>_audit
--       AFTER INSERT OR UPDATE OR DELETE ON <tabla>
--       FOR EACH ROW
--       EXECUTE FUNCTION audit_table_change();
--
-- Lee el actor de dos fuentes (mismo patrón que tramite_evento en Módulo 4):
--   - auth.uid()                         → usuario humano
--   - app.agente_ia_actual (set_config)  → agente IA corriendo con service_role
--
-- Columnas sensibles excluidas del JSONB guardado:
--   - adjunto.password → eliminada del antes/despues para no persistir passwords
-- =============================================================================

CREATE OR REPLACE FUNCTION audit_table_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_antes         JSONB;
    v_despues       JSONB;
    v_registro_id   TEXT;
    v_usuario_id    UUID;
    v_agente_ia     TEXT;
BEGIN
    -- Capturar actor
    v_usuario_id := auth.uid();
    v_agente_ia  := NULLIF(current_setting('app.agente_ia_actual', TRUE), '');

    -- Capturar estado antes y después según la operación
    CASE TG_OP
        WHEN 'INSERT' THEN
            v_antes       := NULL;
            v_despues     := row_to_json(NEW)::JSONB;
            v_registro_id := v_despues ->> 'id';

        WHEN 'UPDATE' THEN
            v_antes       := row_to_json(OLD)::JSONB;
            v_despues     := row_to_json(NEW)::JSONB;
            v_registro_id := v_despues ->> 'id';

        WHEN 'DELETE' THEN
            v_antes       := row_to_json(OLD)::JSONB;
            v_despues     := NULL;
            v_registro_id := v_antes ->> 'id';
    END CASE;

    -- Eliminar columnas sensibles antes de persistir
    IF TG_TABLE_NAME = 'adjunto' THEN
        v_antes   := v_antes   - 'password';
        v_despues := v_despues - 'password';
    END IF;

    INSERT INTO audit_log (
        tabla,
        registro_id,
        operacion,
        antes,
        despues,
        usuario_id,
        agente_ia_nombre
    ) VALUES (
        TG_TABLE_NAME,
        v_registro_id,
        TG_OP,
        v_antes,
        v_despues,
        v_usuario_id,
        v_agente_ia
    );

    RETURN COALESCE(NEW, OLD);
END;
$$;

COMMENT ON FUNCTION audit_table_change() IS
    'Trigger genérico de auditoría. Se adjunta a cualquier tabla con: '
    'CREATE TRIGGER trg_<tabla>_audit AFTER INSERT OR UPDATE OR DELETE ON <tabla> '
    'FOR EACH ROW EXECUTE FUNCTION audit_table_change(). '
    'Excluye adjunto.password del JSONB capturado. '
    'Lee el actor de auth.uid() o app.agente_ia_actual (mismo patrón que tramite_evento).';


-- =============================================================================
-- SECCIÓN 7: ADJUNTAR TRIGGERS DE AUDITORÍA A TABLAS CRÍTICAS
-- =============================================================================
-- Se auditan las tablas donde un cambio no autorizado o accidental sería
-- difícil de detectar sin un registro explícito.
--
-- NO se auditan:
--   tramite        → tramite_evento ya es el historial inmutable del trámite
--   tramite_evento → append-only, inmutable por diseño
--   notificacion   → volumen muy alto, bajo valor de auditoría
--   rag_poliza     → append-only por diseño
--   agente_ia_log  → no tiene sentido auditarse a sí mismo
--   audit_log      → idem
-- =============================================================================

-- Cambios en cuentas de usuario (altas, bajas, cambios de rol)
CREATE TRIGGER trg_usuario_audit
    AFTER INSERT OR UPDATE OR DELETE ON usuario
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_usuario_audit ON usuario IS
    'Audita todo cambio en cuentas de usuario: alta, baja, cambio de rol, ramo, firma.';

-- Cambios en el catálogo de agentes de seguros
CREATE TRIGGER trg_agente_audit
    AFTER INSERT OR UPDATE OR DELETE ON agente
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

-- Cambios en reglas de enrutamiento agente→analista (Módulo 7)
CREATE TRIGGER trg_asignacion_audit
    AFTER INSERT OR UPDATE OR DELETE ON asignacion
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_asignacion_audit ON asignacion IS
    'Audita cambios en reglas de asignación. Permite responder: '
    '"¿Quién reasignó los trámites del agente X del analista A al analista B?"';

-- Cambios en definiciones de SLA — quién los modifica y cuándo (Módulo 8)
CREATE TRIGGER trg_sla_def_audit
    AFTER INSERT OR UPDATE OR DELETE ON sla_definicion
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_sla_def_audit ON sla_definicion IS
    'Audita cambios en parámetros de SLA. Permite responder: '
    '"¿El director cambió el plazo de Alta GMM de 5 a 3 días? ¿Cuándo y quién?"';

-- Cambios en el calendario de días inhábiles (Módulo 8)
CREATE TRIGGER trg_dia_inhabil_audit
    AFTER INSERT OR UPDATE OR DELETE ON dia_inhabil
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

-- Cambios en preferencias de notificación de usuarios (Módulo 9)
CREATE TRIGGER trg_notif_config_audit
    AFTER INSERT OR UPDATE ON notificacion_config
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

-- Cambios en cobertura de vacaciones (Módulo 7)
CREATE TRIGGER trg_cobertura_audit
    AFTER INSERT OR UPDATE OR DELETE ON cobertura_vacaciones
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_cobertura_audit ON cobertura_vacaciones IS
    'Audita coberturas de vacaciones. Permite responder: '
    '"¿Quién cubrió al analista X durante su ausencia en enero?"';


-- =============================================================================
-- SECCIÓN 8: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE audit_log      ENABLE ROW LEVEL SECURITY;
ALTER TABLE agente_ia_log  ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: audit_log
--
-- Principio: el audit_log es una herramienta de control, no de trabajo diario.
--   Directores  → ven TODO (supervisión completa)
--   Gerentes    → ven acciones de usuarios de su ramo + registros de su ramo
--   Analistas   → solo sus propias acciones en el sistema
-- -----------------------------------------------------------------------------

CREATE POLICY pol_audit_select_director
    ON audit_log FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_audit_select_director ON audit_log IS
    'Directores ven el log de auditoría completo sin restricción.';

CREATE POLICY pol_audit_select_gerente
    ON audit_log FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (
            -- Sus propias acciones
            usuario_id = auth.uid()
            -- Acciones de analistas o usuarios de su mismo ramo
            OR EXISTS (
                SELECT 1 FROM usuario u
                WHERE u.id = audit_log.usuario_id
                  AND u.ramo::text = auth_ramo()
            )
            -- Cambios en trámites que puede ver (via puede_ver_tramite del Módulo 5)
            OR (
                tabla = 'tramite'
                AND puede_ver_tramite(registro_id::UUID)
            )
        )
    );

COMMENT ON POLICY pol_audit_select_gerente ON audit_log IS
    'Gerente ve sus propias acciones, las de analistas de su ramo, '
    'y los cambios en trámites de su ramo.';

CREATE POLICY pol_audit_select_analista
    ON audit_log FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND usuario_id = auth.uid()
    );

COMMENT ON POLICY pol_audit_select_analista ON audit_log IS
    'Analista solo ve sus propias acciones registradas en el audit_log.';

-- INSERT / UPDATE / DELETE: prohibido para authenticated
-- Solo service_role via el trigger audit_table_change() SECURITY DEFINER puede insertar.


-- -----------------------------------------------------------------------------
-- POLICIES: agente_ia_log
--
-- El log de agentes IA es más técnico pero es útil para analistas y gerentes
-- para entender por qué el sistema tomó ciertas decisiones.
--   Directores  → todo
--   Gerentes    → ejecuciones de trámites de su ramo
--   Analistas   → ejecuciones de sus trámites asignados
-- -----------------------------------------------------------------------------

CREATE POLICY pol_agente_log_select_director
    ON agente_ia_log FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

CREATE POLICY pol_agente_log_select_gerente
    ON agente_ia_log FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (
            tramite_id IS NULL  -- ejecuciones sin trámite asignado (inicio del pipeline)
            OR puede_ver_tramite(tramite_id)
        )
    );

CREATE POLICY pol_agente_log_select_analista
    ON agente_ia_log FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND (
            tramite_id IS NOT NULL
            AND puede_ver_tramite(tramite_id)
        )
    );

COMMENT ON POLICY pol_agente_log_select_analista ON agente_ia_log IS
    'Analista ve los logs de los agentes IA que procesaron sus trámites. '
    'Permite entender por qué el sistema tomó decisiones específicas.';

-- INSERT: service_role (agentes IA) — authenticated no puede insertar directamente
-- UPDATE: service_role (para actualizar estado, fin, resultado)
-- DELETE: nadie


-- =============================================================================
-- SECCIÓN 9: GRANTS
-- =============================================================================

-- audit_log: solo lectura para authenticated — escritura solo por trigger (service_role)
GRANT SELECT ON TABLE audit_log     TO authenticated;

-- agente_ia_log: lectura para authenticated; escritura solo para service_role
GRANT SELECT ON TABLE agente_ia_log TO authenticated;

-- La función de auditoría no necesita GRANT a authenticated — es llamada
-- por triggers (SECURITY DEFINER) que corren como el owner, no como el usuario.


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000009_modulo_10_auditoria.sql
-- =============================================================================

-- =============================================================================
-- Migración: 20260522000002_modulo_03_polizas.sql
-- Módulo 3 — Pólizas y Asegurados del CRM Olimpo
-- =============================================================================
-- Filosofía de diseño:
--   Los registros de póliza y asegurado se construyen INCREMENTALMENTE a través
--   del Agente 4 (IA de asignación) conforme procesa documentos de cada trámite.
--   Por esto:
--     - Los únicos campos obligatorios son los que el agente SIEMPRE puede extraer
--     - Los datos específicos por ramo van en datos_ramo (JSONB) — flexible
--     - Los datos del asegurado van creciendo con cada trámite procesado
--     - Nada bloquea la creación de un registro por falta de datos opcionales
--
-- Flujo de creación típico:
--   Agente 4 recibe trámite → identifica número de póliza y agente →
--   crea/actualiza poliza con mínimo de datos →
--   crea/actualiza asegurado con lo extraído del documento →
--   vincula ambos via poliza_asegurado
--
-- Relaciones con módulos anteriores:
--   poliza.agente_id    → agente.id    (Módulo 2)
--   poliza.analista_id  → usuario.id   (Módulo 1)
--
-- Relaciones con módulos futuros:
--   tramite.poliza_id   → poliza.id    (Módulo 4)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_persona AS ENUM (
    'persona_fisica',
    'persona_moral'
);

COMMENT ON TYPE tipo_persona IS
    'Distingue entre persona física y moral. Determina qué documentos solicita GNP '
    'y qué campos del asegurado aplican (CURP solo para física, acta constitutiva para moral).';


CREATE TYPE estado_poliza AS ENUM (
    'en_tramite',   -- en proceso de alta o endoso, aún sin aprobación GNP
    'activa',       -- aprobada y con vigencia activa en GNP
    'vencida',      -- vigencia expirada
    'cancelada'     -- cancelada antes de expirar
);

COMMENT ON TYPE estado_poliza IS
    'Ciclo de vida de una póliza. El estado inicial es en_tramite; '
    'pasa a activa cuando GNP aprueba. El Agente 4 actualiza este campo.';


CREATE TYPE rol_asegurado AS ENUM (
    'titular',              -- contratante / asegurado principal
    'asegurado_adicional',  -- empleados en pyme, dependientes en gmm/vida colectivo
    'beneficiario'          -- beneficiario de indemnización (principalmente vida)
);

COMMENT ON TYPE rol_asegurado IS
    'Rol del asegurado dentro de la póliza. '
    'Una póliza tiene exactamente un titular; puede tener múltiples adicionales y beneficiarios.';


-- =============================================================================
-- SECCIÓN 2: TABLA asegurado
-- =============================================================================
-- Representa a la persona física o moral cubierta por una póliza.
-- Los campos opcionales se llenan conforme el Agente 3 (OCR) extrae
-- datos de documentos como INE, acta de nacimiento, acta constitutiva, etc.
-- =============================================================================

CREATE TABLE asegurado (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identidad — mínimo siempre conocido
    -- -------------------------------------------------------------------------
    -- Nombre completo (persona física) o razón social (persona moral)
    nombre              TEXT            NOT NULL,

    -- Tipo: se llena cuando el Agente 3 clasifica el documento de identidad.
    -- NULL es válido si aún no se ha procesado el documento.
    tipo                tipo_persona    NULL,

    -- -------------------------------------------------------------------------
    -- Datos fiscales / identidad formal
    -- Todos opcionales — se llenan conforme llegan documentos
    -- -------------------------------------------------------------------------
    rfc                 TEXT            NULL,
    -- CURP solo aplica a persona física
    curp                TEXT            NULL,
    -- Fecha de nacimiento — relevante para coberturas de salud y vida
    fecha_nacimiento    DATE            NULL,

    -- -------------------------------------------------------------------------
    -- Datos adicionales flexibles
    -- El Agente 3/4 puede escribir aquí cualquier campo extraído que no
    -- tenga columna propia. Ejemplos:
    --   persona_física:  { "sexo": "F", "estado_civil": "casada" }
    --   persona_moral:   { "giro": "Tecnología", "num_empleados": 50 }
    -- -------------------------------------------------------------------------
    datos_adicionales   JSONB           NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Estado y auditoría
    -- -------------------------------------------------------------------------
    activo              BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_asegurado_nombre CHECK (TRIM(nombre) <> ''),

    -- Formato RFC mexicano si se provee
    CONSTRAINT ck_asegurado_rfc CHECK (
        rfc IS NULL
        OR rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'
    ),

    -- Formato CURP mexicano si se provee (18 caracteres)
    CONSTRAINT ck_asegurado_curp CHECK (
        curp IS NULL
        OR curp ~ '^[A-Z]{4}[0-9]{6}[HM][A-Z]{5}[A-Z0-9]{2}$'
    ),

    -- RFC único si se provee
    CONSTRAINT uq_asegurado_rfc UNIQUE (rfc),

    -- CURP único si se provee
    CONSTRAINT uq_asegurado_curp UNIQUE (curp)
);

COMMENT ON TABLE asegurado IS
    'Personas físicas o morales cubiertas por pólizas. '
    'Los campos se llenan incrementalmente conforme el Agente 3 procesa documentos. '
    'Un asegurado puede estar vinculado a múltiples pólizas (via poliza_asegurado).';

COMMENT ON COLUMN asegurado.tipo              IS 'Persona física o moral. NULL si aún no se ha procesado el documento de identidad.';
COMMENT ON COLUMN asegurado.rfc               IS 'RFC validado con formato mexicano. Único si se provee.';
COMMENT ON COLUMN asegurado.curp              IS 'CURP validado con formato mexicano. Solo aplica a persona física.';
COMMENT ON COLUMN asegurado.fecha_nacimiento  IS 'Relevante para coberturas de salud (GMM) y vida. Se extrae de acta o INE.';
COMMENT ON COLUMN asegurado.datos_adicionales IS 'Bucket JSONB para datos extraídos por el agente IA sin columna propia.';


-- =============================================================================
-- SECCIÓN 3: TABLA poliza
-- =============================================================================
-- Registro central de una póliza de seguros.
-- Se crea con el mínimo de datos conocidos al momento y se enriquece
-- con cada trámite procesado por el Agente 4.
-- =============================================================================

CREATE TABLE poliza (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identificadores — los únicos campos verdaderamente obligatorios
    -- -------------------------------------------------------------------------
    -- Número de póliza asignado por GNP. Siempre conocido desde el primer trámite.
    numero_poliza       TEXT            NOT NULL,
    -- Ramo determinado por el contexto del trámite o documento entrante
    ramo                ramo_usuario    NOT NULL,

    -- -------------------------------------------------------------------------
    -- Relaciones con otras entidades
    -- -------------------------------------------------------------------------
    -- Agente que gestiona esta póliza — identificado por el Agente 4
    agente_id           UUID            NOT NULL REFERENCES agente(id),
    -- Analista asignado — puede quedar NULL hasta que el módulo de asignación
    -- lo determine (via tabla asignacion en módulo futuro)
    analista_id         UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Datos del producto — opcionales, se llenan conforme hay más info
    -- -------------------------------------------------------------------------
    -- Nombre del producto GNP (ej: "GMM Plus", "Vida Entera", "Autos Amplia")
    -- Texto libre — GNP no tiene un catálogo fijo accesible via API
    plan                TEXT            NULL,
    fecha_inicio        DATE            NULL,
    fecha_fin           DATE            NULL,
    estado              estado_poliza   NOT NULL DEFAULT 'en_tramite',

    -- -------------------------------------------------------------------------
    -- Datos flexibles por ramo (JSONB)
    -- Se construye incrementalmente conforme el agente IA procesa documentos.
    -- No hay schema rígido — cada ramo usa los campos que necesita.
    --
    -- Estructura esperada por ramo (documentada, no enforced en DB):
    --
    --   ramo = 'autos':
    --     { "marca": "Toyota", "modelo": "Corolla", "anio": 2023,
    --       "vin": "1HGBH41J...", "placas": "ABC-123", "color": "Blanco" }
    --
    --   ramo = 'pyme':
    --     { "giro": "Tecnología", "num_empleados": 50,
    --       "tipo_cobertura": "flotilla" | "empleados" | "inmuebles" }
    --
    --   ramo = 'vida':
    --     { "tipo_vida": "individual" | "colectivo", "suma_asegurada": 1000000 }
    --
    --   ramo = 'gmm':
    --     { "red_medica": "amplia" | "restringida", "deducible": 5000 }
    -- -------------------------------------------------------------------------
    datos_ramo          JSONB           NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Observaciones internas
    -- -------------------------------------------------------------------------
    notas               TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Estado y auditoría
    -- -------------------------------------------------------------------------
    activo              BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_poliza_numero UNIQUE (numero_poliza),

    CONSTRAINT ck_poliza_vigencia CHECK (
        fecha_inicio IS NULL
        OR fecha_fin IS NULL
        OR fecha_fin >= fecha_inicio
    )
);

COMMENT ON TABLE poliza IS
    'Pólizas de seguros gestionadas por la promotoría. '
    'Se crea con mínimo de datos y se enriquece incrementalmente por el Agente 4 '
    'conforme procesa documentos de cada trámite.';

COMMENT ON COLUMN poliza.numero_poliza   IS 'Número asignado por GNP. Único en toda la instancia.';
COMMENT ON COLUMN poliza.ramo            IS 'Ramo del seguro. Determina la estructura esperada de datos_ramo.';
COMMENT ON COLUMN poliza.agente_id       IS 'Agente responsable identificado por el Agente 4 en el cascade de asignación.';
COMMENT ON COLUMN poliza.analista_id     IS 'Analista asignado. NULL hasta que la tabla asignacion lo determine.';
COMMENT ON COLUMN poliza.plan            IS 'Nombre del producto GNP. Texto libre — se extrae de documentos o email.';
COMMENT ON COLUMN poliza.estado          IS 'Ciclo de vida. El Agente 4 actualiza este campo conforme avanza el trámite.';
COMMENT ON COLUMN poliza.datos_ramo      IS
    'JSONB flexible para datos específicos del ramo. '
    'autos: {marca, modelo, anio, vin, placas, color}. '
    'pyme: {giro, num_empleados, tipo_cobertura}. '
    'vida: {tipo_vida, suma_asegurada}. '
    'gmm: {red_medica, deducible}.';


-- =============================================================================
-- SECCIÓN 4: TABLA poliza_asegurado — junction póliza ↔ asegurado
-- =============================================================================
-- Vincula asegurados a pólizas con su rol dentro de cada una.
-- Permite:
--   - Pólizas simples: un titular (vida individual, autos, gmm individual)
--   - Pólizas colectivas/pyme: titular (empresa) + N adicionales (empleados)
--   - Beneficiarios en vida con parentesco y porcentaje de beneficio
-- =============================================================================

CREATE TABLE poliza_asegurado (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    poliza_id       UUID            NOT NULL REFERENCES poliza(id) ON DELETE CASCADE,
    asegurado_id    UUID            NOT NULL REFERENCES asegurado(id),
    rol             rol_asegurado   NOT NULL DEFAULT 'titular',

    -- Solo para beneficiarios en vida — NULL en cualquier otro rol
    parentesco      TEXT            NULL,   -- ej: "cónyuge", "hijo", "padre"
    -- Porcentaje del beneficio (0-100). La suma de beneficiarios debe ser 100%
    -- pero esto se valida en la capa de aplicación, no en DB.
    porcentaje      NUMERIC(5, 2)   NULL,

    -- Datos adicionales que el agente IA extraiga específicos para este vínculo
    -- Ejemplo pyme: { "puesto": "Gerente", "fecha_ingreso": "2022-01-15" }
    datos_adicionales JSONB         NULL DEFAULT '{}',

    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Un asegurado no puede tener dos roles en la misma póliza
    CONSTRAINT uq_poliza_asegurado UNIQUE (poliza_id, asegurado_id),

    CONSTRAINT ck_porcentaje CHECK (
        porcentaje IS NULL
        OR (porcentaje > 0 AND porcentaje <= 100)
    ),

    -- parentesco y porcentaje solo tienen sentido para beneficiarios
    CONSTRAINT ck_beneficiario_campos CHECK (
        rol = 'beneficiario'
        OR (parentesco IS NULL AND porcentaje IS NULL)
    )
);

COMMENT ON TABLE poliza_asegurado IS
    'Vincula asegurados a pólizas con su rol. Un titular por póliza (enforced por '
    'índice único parcial). Múltiples adicionales y beneficiarios permitidos. '
    'Se construye incrementalmente por el Agente 4.';

COMMENT ON COLUMN poliza_asegurado.rol          IS 'titular: contratante principal. asegurado_adicional: empleados/dependientes. beneficiario: en pólizas de vida.';
COMMENT ON COLUMN poliza_asegurado.parentesco   IS 'Solo para beneficiarios. Ej: cónyuge, hijo, padre. NULL para otros roles.';
COMMENT ON COLUMN poliza_asegurado.porcentaje   IS 'Porcentaje de beneficio. Solo para beneficiarios. La suma debe ser 100% (validado en app).';
COMMENT ON COLUMN poliza_asegurado.datos_adicionales IS 'JSONB para datos extra del vínculo. Ej pyme: {puesto, fecha_ingreso}.';


-- =============================================================================
-- SECCIÓN 5: ÍNDICES
-- =============================================================================

-- asegurado
CREATE INDEX idx_asegurado_nombre
    ON asegurado USING gin (nombre gin_trgm_ops);

COMMENT ON INDEX idx_asegurado_nombre IS
    'Búsqueda fuzzy de asegurado por nombre en la UI y por el Agente 4.';

CREATE INDEX idx_asegurado_tipo
    ON asegurado (tipo)
    WHERE tipo IS NOT NULL;

CREATE INDEX idx_asegurado_activo
    ON asegurado (activo)
    WHERE activo = TRUE;

-- poliza
CREATE INDEX idx_poliza_agente
    ON poliza (agente_id);

CREATE INDEX idx_poliza_analista
    ON poliza (analista_id)
    WHERE analista_id IS NOT NULL;

CREATE INDEX idx_poliza_ramo
    ON poliza (ramo);

CREATE INDEX idx_poliza_estado
    ON poliza (estado);

CREATE INDEX idx_poliza_activa
    ON poliza (activo)
    WHERE activo = TRUE;

-- Búsqueda por número de póliza (ya cubierta por UNIQUE constraint, pero
-- el índice parcial sobre activas acelera el caso más frecuente)
CREATE INDEX idx_poliza_numero_activa
    ON poliza (numero_poliza)
    WHERE activo = TRUE;

-- datos_ramo JSONB — índice GIN para búsquedas dentro del JSON
-- Útil para que el Agente 4 busque pólizas por placa, VIN, etc.
CREATE INDEX idx_poliza_datos_ramo
    ON poliza USING gin (datos_ramo);

COMMENT ON INDEX idx_poliza_datos_ramo IS
    'Búsquedas dentro del JSONB datos_ramo. Permite al Agente 4 buscar '
    'pólizas por placa, VIN, giro de empresa, etc.';

-- poliza_asegurado
CREATE INDEX idx_poliza_asegurado_poliza
    ON poliza_asegurado (poliza_id);

CREATE INDEX idx_poliza_asegurado_asegurado
    ON poliza_asegurado (asegurado_id);

-- Solo UN titular por póliza — índice único parcial
CREATE UNIQUE INDEX uq_poliza_titular
    ON poliza_asegurado (poliza_id)
    WHERE rol = 'titular';

COMMENT ON INDEX uq_poliza_titular IS
    'Garantiza que cada póliza tenga exactamente un asegurado con rol = titular.';


-- =============================================================================
-- SECCIÓN 6: TRIGGERS — updated_at
-- =============================================================================
-- set_updated_at() ya existe desde la migración 20260522000000.

CREATE TRIGGER trg_asegurado_updated_at
    BEFORE UPDATE ON asegurado
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_poliza_updated_at
    BEFORE UPDATE ON poliza
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 7: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--
--   asegurado:
--     Todos los usuarios autenticados pueden leer y crear/editar asegurados.
--     Son datos de referencia compartidos — el Agente 4 (service_role) los crea,
--     pero los analistas también pueden completar datos faltantes.
--
--   poliza:
--     - director_general / director_ops: ven todas las pólizas
--     - gerente: ve pólizas de su ramo
--     - analista: ve pólizas donde es el analista asignado
--     Escritura: todos los roles con acceso pueden crear y editar.
--     El Agente 4 usa service_role (bypasa RLS) para crear pólizas nuevas.
--
--   poliza_asegurado:
--     Misma visibilidad que la póliza a la que pertenece.
-- =============================================================================

ALTER TABLE asegurado          ENABLE ROW LEVEL SECURITY;
ALTER TABLE poliza             ENABLE ROW LEVEL SECURITY;
ALTER TABLE poliza_asegurado   ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: asegurado
-- Datos de referencia — acceso amplio para que analistas puedan completar info
-- -----------------------------------------------------------------------------

CREATE POLICY pol_asegurado_select
    ON asegurado FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_asegurado_select ON asegurado IS
    'Todos los usuarios ven todos los asegurados. Son datos de referencia compartidos.';

CREATE POLICY pol_asegurado_insert
    ON asegurado FOR INSERT TO authenticated
    WITH CHECK (TRUE);

COMMENT ON POLICY pol_asegurado_insert ON asegurado IS
    'Cualquier usuario puede registrar asegurados. El Agente 4 los crea via service_role.';

CREATE POLICY pol_asegurado_update
    ON asegurado FOR UPDATE TO authenticated
    USING (TRUE)
    WITH CHECK (TRUE);

COMMENT ON POLICY pol_asegurado_update ON asegurado IS
    'Cualquier usuario puede enriquecer datos de asegurados (RFC, CURP, fecha_nacimiento).';


-- -----------------------------------------------------------------------------
-- POLICIES: poliza
-- -----------------------------------------------------------------------------

-- Directores ven todo
CREATE POLICY pol_poliza_select_director
    ON poliza FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

-- Gerente ve pólizas de su ramo
CREATE POLICY pol_poliza_select_gerente
    ON poliza FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

-- Analista ve solo las pólizas que tiene asignadas
CREATE POLICY pol_poliza_select_analista
    ON poliza FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    );

-- INSERT: cualquier usuario con acceso puede crear pólizas
-- (el Agente 4 usa service_role que bypasa RLS)
CREATE POLICY pol_poliza_insert
    ON poliza FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- UPDATE: directores y gerentes actualizan cualquier póliza visible;
-- analista solo actualiza sus pólizas asignadas
CREATE POLICY pol_poliza_update_director_gerente
    ON poliza FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR (auth_rol() = 'gerente' AND ramo::text = auth_ramo())
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (auth_rol() = 'gerente' AND ramo::text = auth_ramo())
    );

CREATE POLICY pol_poliza_update_analista
    ON poliza FOR UPDATE TO authenticated
    USING (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    )
    WITH CHECK (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    );

-- DELETE: nadie — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: poliza_asegurado
-- Hereda visibilidad de poliza via subquery
-- -----------------------------------------------------------------------------

CREATE POLICY pol_poliza_asegurado_select
    ON poliza_asegurado FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM poliza p
            WHERE p.id = poliza_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente' AND p.ramo::text = auth_ramo())
                OR (auth_rol() = 'analista' AND p.analista_id = auth.uid())
              )
        )
    );

CREATE POLICY pol_poliza_asegurado_insert
    ON poliza_asegurado FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM poliza p
            WHERE p.id = poliza_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente' AND p.ramo::text = auth_ramo())
                OR (auth_rol() = 'analista' AND p.analista_id = auth.uid())
              )
        )
    );

CREATE POLICY pol_poliza_asegurado_update
    ON poliza_asegurado FOR UPDATE TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM poliza p
            WHERE p.id = poliza_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente' AND p.ramo::text = auth_ramo())
                OR (auth_rol() = 'analista' AND p.analista_id = auth.uid())
              )
        )
    );

-- DELETE en poliza_asegurado: solo directores
-- (puede necesitarse corregir vínculos erróneos del agente IA)
CREATE POLICY pol_poliza_asegurado_delete
    ON poliza_asegurado FOR DELETE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );


-- =============================================================================
-- SECCIÓN 8: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON TABLE asegurado         TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE poliza            TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE poliza_asegurado TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000002_modulo_03_polizas.sql
-- =============================================================================

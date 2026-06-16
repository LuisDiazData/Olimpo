-- =============================================================================
-- Migración: 20260522000001_modulo_02_agentes.sql
-- Módulo 2 — Agentes y Asistentes del CRM Olimpo
-- =============================================================================
-- Contexto:
--   Los agentes son personas físicas o morales afiliadas a la promotoría que
--   venden seguros GNP. Cada agente tiene un CUA (Clave Única del Agente)
--   asignado por GNP. Los asistentes son personas que trabajan a nombre de
--   un agente y pueden enviar correos en su representación.
--
--   El Agente 4 (IA de asignación) hace cascade de identificación buscando
--   el remitente de correos entrantes en agente_email y asistente.email.
--   Por esto, los emails son únicos globalmente entre ambas tablas.
--
-- Permisos de escritura:
--   director_general, director_ops, gerente — pueden crear y editar agentes
--   analista — solo lectura
--
-- Relaciones con otras tablas (módulos futuros):
--   tramite.agente_id        → agente.id
--   poliza.agente_id         → agente.id
--   asignacion.agente_id     → agente.id
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_telefono AS ENUM (
    'celular',
    'oficina',
    'casa',
    'whatsapp',
    'otro'
);

COMMENT ON TYPE tipo_telefono IS
    'Tipo de número telefónico. Usado en agente_telefono.';


-- =============================================================================
-- SECCIÓN 2: TABLA agente
-- =============================================================================

CREATE TABLE agente (
    -- -------------------------------------------------------------------------
    -- Identidad interna — UUID propio, independiente del CUA de GNP
    -- -------------------------------------------------------------------------
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identificadores GNP
    -- -------------------------------------------------------------------------
    -- CUA: Clave Única del Agente, asignada por GNP. Se ingresa al dar de alta.
    -- Es el identificador que aparece en documentos y pólizas de GNP.
    cua                 TEXT            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Datos personales / comerciales
    -- -------------------------------------------------------------------------
    nombre              TEXT            NOT NULL,
    -- Nombre comercial o razón social si opera bajo una denominación diferente
    nombre_comercial    TEXT            NULL,
    -- RFC opcional — se completa cuando se necesita para documentos formales.
    -- Formato válido: personas físicas 13 chars, morales 12 chars.
    rfc                 TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Relación con la promotoría
    -- -------------------------------------------------------------------------
    fecha_afiliacion    DATE            NULL,   -- cuándo se afilió a la agencia
    notas               TEXT            NULL,   -- observaciones internas del equipo

    -- -------------------------------------------------------------------------
    -- Estado — soft-delete: nunca eliminar un agente con historial
    -- -------------------------------------------------------------------------
    activo              BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- CUA único en toda la instancia
    CONSTRAINT uq_agente_cua
        UNIQUE (cua),

    -- RFC único si se provee (dos agentes no pueden tener el mismo RFC)
    CONSTRAINT uq_agente_rfc
        UNIQUE (rfc),

    -- Validación de formato RFC mexicano cuando se provee
    -- Personas físicas: 4 letras + 6 dígitos + 3 alfanuméricos (13 chars)
    -- Personas morales:  3 letras + 6 dígitos + 3 alfanuméricos (12 chars)
    CONSTRAINT ck_agente_rfc_formato CHECK (
        rfc IS NULL
        OR rfc ~ '^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$'
    ),

    -- CUA no puede ser cadena vacía
    CONSTRAINT ck_agente_cua_notempty CHECK (
        TRIM(cua) <> ''
    )
);

COMMENT ON TABLE agente IS
    'Agentes de seguros afiliados a la promotoría. Cada agente tiene un CUA '
    'asignado por GNP que lo identifica en documentos y pólizas.';

COMMENT ON COLUMN agente.id               IS 'UUID interno del CRM — independiente del CUA de GNP.';
COMMENT ON COLUMN agente.cua              IS 'Clave Única del Agente asignada por GNP. Identificador oficial en documentos.';
COMMENT ON COLUMN agente.nombre           IS 'Nombre completo del agente.';
COMMENT ON COLUMN agente.nombre_comercial IS 'Razón social o nombre comercial si difiere del nombre personal.';
COMMENT ON COLUMN agente.rfc              IS 'RFC del agente. Opcional al dar de alta; requerido para documentos formales con GNP.';
COMMENT ON COLUMN agente.fecha_afiliacion IS 'Fecha en que el agente se afilió a la promotoría.';
COMMENT ON COLUMN agente.notas            IS 'Observaciones internas del equipo sobre este agente. No visible para el agente.';
COMMENT ON COLUMN agente.activo           IS 'Soft-delete. Preservar historial de trámites y pólizas aunque el agente ya no opere.';


-- =============================================================================
-- SECCIÓN 3: TABLA agente_telefono — múltiples teléfonos por agente
-- =============================================================================

CREATE TABLE agente_telefono (
    id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    agente_id   UUID            NOT NULL REFERENCES agente(id) ON DELETE CASCADE,
    tipo        tipo_telefono   NOT NULL DEFAULT 'celular',
    numero      TEXT            NOT NULL,
    -- Marca el número principal para mostrar en UI y firmas de correo.
    -- Solo puede haber UN preferente por agente (ver índice parcial abajo).
    preferente  BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_agente_telefono_numero CHECK (TRIM(numero) <> '')
);

COMMENT ON TABLE agente_telefono IS
    'Teléfonos del agente. Un agente puede tener varios; el campo preferente '
    'identifica el número principal para UI y comunicaciones.';

COMMENT ON COLUMN agente_telefono.tipo       IS 'Tipo de teléfono: celular, oficina, casa, whatsapp, otro.';
COMMENT ON COLUMN agente_telefono.preferente IS 'Solo un teléfono por agente puede ser preferente (enforced por índice único parcial).';


-- =============================================================================
-- SECCIÓN 4: TABLA agente_email — múltiples correos por agente
-- =============================================================================
-- CRÍTICO: el Agente 4 (IA) busca el remitente de correos entrantes en esta
-- tabla para identificar al agente. El email debe ser globalmente único entre
-- agente_email y asistente (ver triggers de validación cruzada en Sección 8).
-- =============================================================================

CREATE TABLE agente_email (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    agente_id   UUID        NOT NULL REFERENCES agente(id) ON DELETE CASCADE,
    email       TEXT        NOT NULL,
    -- Marca el correo principal: es el que el Agente 6 usa como "From"
    -- en respuestas y el que aparece en la ficha del agente en la UI.
    -- Solo puede haber UN preferente por agente (ver índice parcial abajo).
    preferente  BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Email único dentro de la tabla agente_email
    -- (unicidad cruzada con asistente se refuerza via trigger)
    CONSTRAINT uq_agente_email_email
        UNIQUE (email),

    CONSTRAINT ck_agente_email_formato CHECK (
        email ~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$'
    )
);

COMMENT ON TABLE agente_email IS
    'Correos electrónicos del agente. Globalmente únicos entre agentes y asistentes '
    'para que el Agente 4 pueda identificar al remitente sin ambigüedad.';

COMMENT ON COLUMN agente_email.email      IS 'Correo del agente. Único en toda la DB (incluyendo asistente.email).';
COMMENT ON COLUMN agente_email.preferente IS 'Correo principal para respuestas del Agente 6 y ficha del agente en UI.';


-- =============================================================================
-- SECCIÓN 5: TABLA asistente — trabajadores que actúan a nombre de un agente
-- =============================================================================
-- Los asistentes pueden enviar y recibir correos en nombre del agente.
-- El Agente 4 los identifica por su email y mapea al agente correspondiente.
-- Un asistente pertenece a exactamente un agente.
-- =============================================================================

CREATE TABLE asistente (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    -- FK al agente al que pertenece — obligatoria, sin null
    agente_id   UUID        NOT NULL REFERENCES agente(id) ON DELETE CASCADE,
    nombre      TEXT        NOT NULL,
    -- Email único globalmente (cruzado con agente_email via trigger)
    -- El Agente 4 busca este email en el cascade de identificación
    email       TEXT        NOT NULL,
    telefono    TEXT        NULL,
    activo      BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Email único dentro de la tabla asistente
    -- (unicidad cruzada con agente_email se refuerza via trigger)
    CONSTRAINT uq_asistente_email
        UNIQUE (email),

    CONSTRAINT ck_asistente_email_formato CHECK (
        email ~* '^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$'
    ),

    CONSTRAINT ck_asistente_nombre CHECK (TRIM(nombre) <> '')
);

COMMENT ON TABLE asistente IS
    'Asistentes o trabajadores que actúan a nombre de un agente. '
    'Su email es buscado por el Agente 4 para mapear correos entrantes al agente correcto. '
    'Pertenecen a exactamente un agente.';

COMMENT ON COLUMN asistente.agente_id IS 'Agente al que representa este asistente. Obligatorio.';
COMMENT ON COLUMN asistente.email     IS 'Email único en toda la DB (incluyendo agente_email) para identificación por el Agente 4.';
COMMENT ON COLUMN asistente.activo    IS 'Soft-delete. Un asistente inactivo ya no puede enviar correos reconocidos por el sistema.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- agente
CREATE INDEX idx_agente_activo
    ON agente (activo)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_agente_activo IS
    'Filtrado de agentes activos — el 95%+ de queries de negocio usan activo = TRUE.';

-- Índice sobre nombre para búsqueda fuzzy en la UI (búsqueda de agente por nombre)
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX idx_agente_nombre
    ON agente USING gin (nombre gin_trgm_ops);

COMMENT ON INDEX idx_agente_nombre IS
    'Búsqueda por nombre de agente en la UI (LIKE/ILIKE y similitud). '
    'Requiere extensión pg_trgm (habilitada en Supabase por defecto).';

-- agente_telefono
CREATE INDEX idx_agente_telefono_agente
    ON agente_telefono (agente_id);

-- Solo UN teléfono preferente por agente — índice único parcial
CREATE UNIQUE INDEX uq_agente_telefono_preferente
    ON agente_telefono (agente_id)
    WHERE preferente = TRUE;

COMMENT ON INDEX uq_agente_telefono_preferente IS
    'Garantiza que cada agente tenga máximo un teléfono marcado como preferente.';

-- agente_email
CREATE INDEX idx_agente_email_agente
    ON agente_email (agente_id);

-- Solo UN email preferente por agente — índice único parcial
CREATE UNIQUE INDEX uq_agente_email_preferente
    ON agente_email (agente_id)
    WHERE preferente = TRUE;

COMMENT ON INDEX uq_agente_email_preferente IS
    'Garantiza que cada agente tenga máximo un correo marcado como preferente.';

-- asistente
CREATE INDEX idx_asistente_agente
    ON asistente (agente_id);

CREATE INDEX idx_asistente_activo
    ON asistente (activo)
    WHERE activo = TRUE;


-- =============================================================================
-- SECCIÓN 7: TRIGGERS — updated_at
-- =============================================================================
-- La función set_updated_at() ya fue creada en la migración 20260522000000.
-- Solo se registran los triggers para las tablas de este módulo.

CREATE TRIGGER trg_agente_updated_at
    BEFORE UPDATE ON agente
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_asistente_updated_at
    BEFORE UPDATE ON asistente
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 8: TRIGGERS — UNICIDAD CRUZADA DE EMAILS
-- =============================================================================
-- Un mismo email no puede existir tanto en agente_email como en asistente.
-- El Agente 4 necesita que la búsqueda por email sea inequívoca.
--
-- Se implementa con dos triggers espejo:
--   1. Antes de insertar/actualizar en agente_email → verificar en asistente
--   2. Antes de insertar/actualizar en asistente    → verificar en agente_email
-- =============================================================================

-- Función 1: valida que el email no exista en asistente
CREATE OR REPLACE FUNCTION validar_email_unico_agente()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM asistente
        WHERE email = NEW.email
          AND id <> COALESCE(NEW.id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) THEN
        RAISE EXCEPTION
            'El correo "%" ya está registrado como email de un asistente. '
            'Un correo electrónico no puede pertenecer a un agente y a un asistente al mismo tiempo.',
            NEW.email;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validar_email_unico_agente() IS
    'Valida que el email de agente_email no esté ya registrado en asistente. '
    'Garantiza unicidad global de emails para el Agente 4.';

CREATE TRIGGER trg_agente_email_unicidad_cruzada
    BEFORE INSERT OR UPDATE OF email ON agente_email
    FOR EACH ROW
    EXECUTE FUNCTION validar_email_unico_agente();


-- Función 2: valida que el email no exista en agente_email
CREATE OR REPLACE FUNCTION validar_email_unico_asistente()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM agente_email
        WHERE email = NEW.email
    ) THEN
        RAISE EXCEPTION
            'El correo "%" ya está registrado como email de un agente. '
            'Un correo electrónico no puede pertenecer a un asistente y a un agente al mismo tiempo.',
            NEW.email;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validar_email_unico_asistente() IS
    'Valida que el email de asistente no esté ya registrado en agente_email. '
    'Garantiza unicidad global de emails para el Agente 4.';

CREATE TRIGGER trg_asistente_email_unicidad_cruzada
    BEFORE INSERT OR UPDATE OF email ON asistente
    FOR EACH ROW
    EXECUTE FUNCTION validar_email_unico_asistente();


-- =============================================================================
-- SECCIÓN 9: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--   Lectura:  todos los usuarios autenticados ven el catálogo completo de
--             agentes (activos e inactivos). Los analistas necesitan ver el
--             agente al que pertenece un trámite aunque no sea el suyo.
--   Escritura: directores y gerentes pueden crear y modificar agentes.
--              Analistas solo lectura.
--
-- Las funciones auth_rol() y auth_ramo() ya existen de la migración anterior.
-- =============================================================================

-- Habilitar RLS en las 4 tablas
ALTER TABLE agente            ENABLE ROW LEVEL SECURITY;
ALTER TABLE agente_telefono   ENABLE ROW LEVEL SECURITY;
ALTER TABLE agente_email      ENABLE ROW LEVEL SECURITY;
ALTER TABLE asistente         ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: agente
-- -----------------------------------------------------------------------------

-- Todos los usuarios autenticados ven todos los agentes (activos e inactivos)
-- Justificación: un analista necesita ver el agente de un trámite histórico
-- aunque el agente ya esté inactivo.
CREATE POLICY pol_agente_select_todos
    ON agente
    FOR SELECT
    TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_agente_select_todos ON agente IS
    'Catálogo de agentes visible para todos los usuarios del CRM. '
    'Incluye inactivos para preservar trazabilidad de trámites históricos.';

-- Directores y gerentes pueden crear agentes
CREATE POLICY pol_agente_insert_admin
    ON agente
    FOR INSERT
    TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

-- Directores y gerentes pueden editar agentes
CREATE POLICY pol_agente_update_admin
    ON agente
    FOR UPDATE
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

-- DELETE físico: nadie — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: agente_telefono
-- -----------------------------------------------------------------------------

CREATE POLICY pol_agente_telefono_select
    ON agente_telefono
    FOR SELECT
    TO authenticated
    USING (TRUE);

CREATE POLICY pol_agente_telefono_insert
    ON agente_telefono
    FOR INSERT
    TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_agente_telefono_update
    ON agente_telefono
    FOR UPDATE
    TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- Teléfonos SÍ se pueden eliminar físicamente (no hay implicación de integridad)
CREATE POLICY pol_agente_telefono_delete
    ON agente_telefono
    FOR DELETE
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );


-- -----------------------------------------------------------------------------
-- POLICIES: agente_email
-- -----------------------------------------------------------------------------

CREATE POLICY pol_agente_email_select
    ON agente_email
    FOR SELECT
    TO authenticated
    USING (TRUE);

CREATE POLICY pol_agente_email_insert
    ON agente_email
    FOR INSERT
    TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_agente_email_update
    ON agente_email
    FOR UPDATE
    TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

CREATE POLICY pol_agente_email_delete
    ON agente_email
    FOR DELETE
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );


-- -----------------------------------------------------------------------------
-- POLICIES: asistente
-- -----------------------------------------------------------------------------

CREATE POLICY pol_asistente_select
    ON asistente
    FOR SELECT
    TO authenticated
    USING (TRUE);

CREATE POLICY pol_asistente_insert
    ON asistente
    FOR INSERT
    TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_asistente_update
    ON asistente
    FOR UPDATE
    TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- Asistente: soft-delete vía activo = FALSE, igual que agente
-- DELETE físico: nadie


-- =============================================================================
-- SECCIÓN 10: GRANTS
-- =============================================================================

-- agente: analistas solo SELECT, directores y gerentes también INSERT/UPDATE
GRANT SELECT ON TABLE agente            TO authenticated;
GRANT INSERT, UPDATE ON TABLE agente    TO authenticated;
-- DELETE no se otorga — soft-delete es el único camino

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE agente_telefono   TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE agente_email       TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE asistente                  TO authenticated;
-- asistente: soft-delete también, sin DELETE físico


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000001_modulo_02_agentes.sql
-- =============================================================================

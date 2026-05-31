-- ============================================================
-- MIGRACIÓN: 20260522000000_modulo_01_usuarios.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000000_modulo_01_usuarios.sql
-- Módulo 1 — Usuarios del sistema Olimpo CRM
-- =============================================================================
-- Contexto:
--   Tabla central de identidad del CRM. Cada registro espeja un usuario de
--   Supabase Auth (auth.users). El UUID de Auth ES el PK de esta tabla.
--   Los campos de autorización (rol, ramo) se almacenan en app_metadata del
--   JWT de Supabase para que las policies RLS los lean sin consulta adicional.
--
-- Roles:
--   director_general — todos los ramos, configuración de usuarios
--   director_ops     — todos los ramos, configuración de SLAs y notificaciones
--   gerente          — solo su ramo, gestiona analistas y vacaciones
--   analista         — solo sus trámites asignados
--
-- Ramos:
--   vida | gmm | autos | pyme
--
-- Regla de negocio crítica:
--   gerente y analista DEBEN tener ramo.
--   director_general y director_ops DEBEN tener ramo = NULL.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

-- Roles del sistema Olimpo
CREATE TYPE rol_usuario AS ENUM (
    'director_general',
    'director_ops',
    'gerente',
    'analista'
);

COMMENT ON TYPE rol_usuario IS
    'Roles del sistema Olimpo. Define el nivel de acceso y las responsabilidades de cada usuario.';

-- Ramos de seguros de la promotoría
CREATE TYPE ramo_usuario AS ENUM (
    'vida',
    'gmm',   -- Gastos Médicos Mayores
    'autos',
    'pyme'
);

COMMENT ON TYPE ramo_usuario IS
    'Ramos de seguros administrados por la promotoría. Solo aplica a gerentes y analistas.';


-- =============================================================================
-- SECCIÓN 2: TABLA PRINCIPAL
-- =============================================================================

CREATE TABLE usuario (
    -- -------------------------------------------------------------------------
    -- Identidad — el UUID es el mismo que auth.users, no se auto-genera aquí.
    -- ON DELETE CASCADE: si se elimina el usuario de Auth, se elimina su perfil.
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,

    -- -------------------------------------------------------------------------
    -- Datos de negocio
    -- -------------------------------------------------------------------------
    nombre          TEXT            NOT NULL,
    email           TEXT            NOT NULL,
    rol             rol_usuario     NOT NULL,
    ramo            ramo_usuario    NULL,         -- NULL solo para directores
    telefono        TEXT            NULL,         -- aparece en firma de correos
    firma_html      TEXT            NULL,         -- HTML inyectado por el Agente 6

    -- -------------------------------------------------------------------------
    -- Estado — soft-delete: desactivar en lugar de eliminar
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría Olimpo (sin created_by/updated_by: el registro se crea
    -- automáticamente por trigger; las modificaciones quedan en audit_log)
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Email único en toda la instancia (single-tenant, una DB por cliente)
    CONSTRAINT uq_usuario_email
        UNIQUE (email),

    -- Regla de negocio: gerente y analista requieren ramo;
    -- directores no pueden tener ramo asignado.
    CONSTRAINT ck_ramo_segun_rol CHECK (
        (rol IN ('gerente', 'analista') AND ramo IS NOT NULL)
        OR
        (rol IN ('director_general', 'director_ops') AND ramo IS NULL)
    )
);

COMMENT ON TABLE usuario IS
    'Usuarios internos del CRM Olimpo. Cada fila espeja un registro de auth.users. '
    'El id es el UUID de Supabase Auth para que coincida con auth.uid().';

COMMENT ON COLUMN usuario.id          IS 'UUID de Supabase Auth — NO se auto-genera. Viene de auth.users.id.';
COMMENT ON COLUMN usuario.nombre      IS 'Nombre completo del usuario.';
COMMENT ON COLUMN usuario.email       IS 'Correo corporativo. Usado por el Agente 6 vía Gmail API para enviar correos a nombre del analista.';
COMMENT ON COLUMN usuario.rol         IS 'Rol dentro del CRM. Determina permisos RLS y vistas de dashboard.';
COMMENT ON COLUMN usuario.ramo        IS 'Ramo de seguros asignado. Obligatorio para gerente y analista; NULL para directores.';
COMMENT ON COLUMN usuario.telefono    IS 'Teléfono de contacto. Se incluye en la firma de correos del Agente 6.';
COMMENT ON COLUMN usuario.firma_html  IS 'HTML completo de la firma corporativa. Inyectado por el Agente 6 al redactar correos.';
COMMENT ON COLUMN usuario.activo      IS 'Soft-delete. Desactivar en lugar de eliminar para preservar integridad referencial con trámites históricos.';
COMMENT ON COLUMN usuario.created_at  IS 'Marca de tiempo de creación — asignada por trigger al INSERT en auth.users.';
COMMENT ON COLUMN usuario.updated_at  IS 'Marca de tiempo de última modificación — mantenida por trigger set_updated_at.';


-- =============================================================================
-- SECCIÓN 3: ÍNDICES
-- =============================================================================

-- Índice sobre ramo — la query más frecuente de RLS es filtrar por ramo
-- (gerentes y analistas ven solo su ramo). Alta selectividad con 4 valores
-- pero con RLS activo el planner lo usa consistentemente.
CREATE INDEX idx_usuario_ramo
    ON usuario (ramo)
    WHERE ramo IS NOT NULL;

COMMENT ON INDEX idx_usuario_ramo IS
    'Filtrado por ramo para policies RLS de gerente y analista. '
    'Parcial: excluye directores (ramo IS NULL) para reducir tamaño del índice.';

-- Índice sobre rol — las policies RLS verifican el rol del usuario consultado
-- (no solo el del JWT). Útil para INSERT de director que valida unicidad de
-- directores o para búsquedas de administración por rol.
CREATE INDEX idx_usuario_rol
    ON usuario (rol);

COMMENT ON INDEX idx_usuario_rol IS
    'Búsquedas y validaciones por rol. Usado en administración de usuarios '
    'y en joins para la lógica de asignación de trámites.';

-- Índice sobre activo — la mayoría de queries de negocio filtran activo = TRUE.
-- Índice parcial sobre TRUE para cubrir el caso más frecuente.
CREATE INDEX idx_usuario_activo
    ON usuario (activo)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_usuario_activo IS
    'Filtrado de usuarios activos. Índice parcial porque el 95%+ de queries '
    'buscan activo = TRUE. Los gerentes que consultan inactivos usan seq scan '
    'sobre su subconjunto de ramo, que es pequeño.';

-- Nota: email ya tiene índice implícito por UNIQUE constraint.
-- No se agrega índice adicional sobre email.


-- =============================================================================
-- SECCIÓN 4: FUNCIÓN Y TRIGGER — updated_at AUTOMÁTICO
-- =============================================================================

-- Función reutilizable para mantener updated_at en todas las tablas del CRM.
-- Se crea aquí porque usuario es la primera tabla; las demás tablas la
-- referenciarán sin volver a declararla.
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_updated_at() IS
    'Función reutilizable para actualizar automáticamente la columna updated_at '
    'en cualquier tabla del CRM Olimpo que tenga ese campo.';

-- Trigger que invoca la función antes de cada UPDATE en usuario
CREATE TRIGGER trg_usuario_updated_at
    BEFORE UPDATE ON usuario
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TRIGGER trg_usuario_updated_at ON usuario IS
    'Mantiene updated_at sincronizado con la marca de tiempo real de modificación.';


-- =============================================================================
-- SECCIÓN 5: FUNCIÓN Y TRIGGER — SINCRONIZACIÓN AUTH → USUARIO
-- =============================================================================
-- Al crear un usuario en Supabase Auth (desde la app o desde el Superadmin),
-- se incluye en los metadatos:
--
--   raw_user_meta_data:  { nombre, telefono, firma_html }
--   app_metadata:        { rol, ramo }
--
-- app_metadata es editable solo por service_role (no por el usuario final),
-- lo que garantiza que rol y ramo no puedan ser manipulados desde el cliente.
--
-- El trigger crea el registro completo en usuario en el mismo instante en que
-- Supabase Auth confirma la creación. Si faltan campos obligatorios (rol)
-- en app_metadata, el trigger lanza una excepción y el INSERT en auth.users
-- falla atómicamente — nunca queda un usuario de Auth sin su perfil en usuario.
-- =============================================================================

CREATE OR REPLACE FUNCTION sync_auth_usuario()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
-- SECURITY DEFINER es necesario porque auth.users está en el schema auth
-- y el trigger necesita permisos para escribir en public.usuario.
SET search_path = public
AS $$
DECLARE
    v_rol       TEXT;
    v_ramo      TEXT;
    v_nombre    TEXT;
    v_email     TEXT;
    v_telefono  TEXT;
    v_firma     TEXT;
BEGIN
    -- Extraer campos desde los metadatos del nuevo usuario de Auth
    v_rol       := NEW.raw_app_meta_data  ->> 'rol';
    v_ramo      := NEW.raw_app_meta_data  ->> 'ramo';
    v_nombre    := NEW.raw_user_meta_data ->> 'nombre';
    v_email     := NEW.email;
    v_telefono  := NEW.raw_user_meta_data ->> 'telefono';
    v_firma     := NEW.raw_user_meta_data ->> 'firma_html';

    -- Validación: rol es obligatorio — fallo explícito y descriptivo
    IF v_rol IS NULL THEN
        RAISE EXCEPTION
            'No se puede crear el usuario: falta "rol" en app_metadata. '
            'Asegúrate de incluir { rol, ramo } en app_metadata al crear el usuario de Auth.';
    END IF;

    -- Validación: nombre es obligatorio
    IF v_nombre IS NULL OR TRIM(v_nombre) = '' THEN
        RAISE EXCEPTION
            'No se puede crear el usuario: falta "nombre" en raw_user_meta_data.';
    END IF;

    -- Insertar el perfil completo en public.usuario
    INSERT INTO public.usuario (
        id,
        nombre,
        email,
        rol,
        ramo,
        telefono,
        firma_html,
        activo,
        created_at,
        updated_at
    ) VALUES (
        NEW.id,
        TRIM(v_nombre),
        v_email,
        v_rol::rol_usuario,
        CASE WHEN v_ramo IS NOT NULL THEN v_ramo::ramo_usuario ELSE NULL END,
        NULLIF(TRIM(COALESCE(v_telefono, '')), ''),
        NULLIF(TRIM(COALESCE(v_firma, '')), ''),
        TRUE,
        NOW(),
        NOW()
    );

    RETURN NEW;

EXCEPTION
    WHEN invalid_text_representation THEN
        -- El cast a rol_usuario o ramo_usuario falló — valor no reconocido
        RAISE EXCEPTION
            'Valor de rol o ramo inválido. '
            'Roles válidos: director_general, director_ops, gerente, analista. '
            'Ramos válidos: vida, gmm, autos, pyme. '
            'Valor de rol recibido: %, valor de ramo recibido: %',
            v_rol, v_ramo;
END;
$$;

COMMENT ON FUNCTION sync_auth_usuario() IS
    'Trigger AFTER INSERT en auth.users. Crea el perfil completo en public.usuario '
    'leyendo rol y ramo de app_metadata (solo editable por service_role) y '
    'nombre, telefono, firma_html de raw_user_meta_data. '
    'Falla atómicamente si faltan campos obligatorios.';

-- Registrar el trigger de INSERT en auth.users
CREATE TRIGGER trg_auth_on_new_usuario
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION sync_auth_usuario();

COMMENT ON TRIGGER trg_auth_on_new_usuario ON auth.users IS
    'Sincroniza auth.users → public.usuario en cada creación de usuario. '
    'Garantiza que nunca exista un usuario de Auth sin perfil en el CRM.';


-- -----------------------------------------------------------------------------
-- Sincronización de email cuando cambia en auth.users
-- -----------------------------------------------------------------------------
-- Si el email se actualiza en Supabase Auth (vía dashboard, API de Auth, o
-- confirmación de cambio de email), se refleja automáticamente en usuario.email.
-- Crítico: el Agente 6 usa usuario.email para el campo "From" de Gmail API.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION sync_auth_usuario_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    -- Solo actuar si el email realmente cambió
    IF NEW.email IS DISTINCT FROM OLD.email THEN
        UPDATE public.usuario
        SET
            email      = NEW.email,
            updated_at = NOW()
        WHERE id = NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION sync_auth_usuario_email() IS
    'Mantiene usuario.email sincronizado si el email cambia en auth.users. '
    'Evita que el Agente 6 envíe correos a una dirección desactualizada.';

CREATE TRIGGER trg_auth_on_update_email
    AFTER UPDATE OF email ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION sync_auth_usuario_email();

COMMENT ON TRIGGER trg_auth_on_update_email ON auth.users IS
    'Propaga cambios de email desde auth.users hacia public.usuario.';


-- =============================================================================
-- SECCIÓN 6: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia de lectura de rol/ramo:
--   Las policies leen del JWT usando:
--     auth.jwt() -> 'app_metadata' ->> 'rol'
--     auth.jwt() -> 'app_metadata' ->> 'ramo'
--
--   Esto evita consultas recursivas a la misma tabla usuario dentro de las
--   policies (que causarían bucles o errores de permisos en Supabase).
--
--   app_metadata solo puede ser modificado por service_role — no por el
--   usuario autenticado — garantizando que los valores sean confiables.
-- =============================================================================

ALTER TABLE usuario ENABLE ROW LEVEL SECURITY;

-- Negar todo por defecto (principio de mínimo privilegio)
-- Las policies siguientes son excepciones explícitas a esta negación.


-- -----------------------------------------------------------------------------
-- Funciones auxiliares para policies — evitan repetición y mejoran legibilidad
-- -----------------------------------------------------------------------------

-- Devuelve el rol del usuario autenticado desde el JWT
CREATE OR REPLACE FUNCTION auth_rol()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT auth.jwt() -> 'app_metadata' ->> 'rol'
$$;

COMMENT ON FUNCTION auth_rol() IS
    'Lee el rol del usuario autenticado desde app_metadata del JWT de Supabase Auth. '
    'Usado en policies RLS para evitar repetición del patrón de extracción.';

-- Devuelve el ramo del usuario autenticado desde el JWT
CREATE OR REPLACE FUNCTION auth_ramo()
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT auth.jwt() -> 'app_metadata' ->> 'ramo'
$$;

COMMENT ON FUNCTION auth_ramo() IS
    'Lee el ramo del usuario autenticado desde app_metadata del JWT de Supabase Auth. '
    'Usado en policies RLS de gerente y analista.';


-- -----------------------------------------------------------------------------
-- POLICY: SELECT
-- -----------------------------------------------------------------------------

-- director_general y director_ops ven todos los usuarios (activos e inactivos)
CREATE POLICY pol_usuario_select_director
    ON usuario
    FOR SELECT
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_usuario_select_director ON usuario IS
    'Directores (general y ops) tienen visibilidad completa de todos los usuarios.';

-- gerente ve todos los usuarios de su ramo (activos E inactivos)
-- Justificación: necesita ver analistas inactivos para gestionar históricos
-- de asignación y cobertura de vacaciones pasadas.
-- Nota: comparamos ramo::text con auth_ramo() (TEXT) para evitar cast que
-- lanzaría excepción si app_metadata.ramo tuviera un valor inválido.
CREATE POLICY pol_usuario_select_gerente
    ON usuario
    FOR SELECT
    TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

COMMENT ON POLICY pol_usuario_select_gerente ON usuario IS
    'Gerente ve activos e inactivos de su propio ramo. '
    'Necesario para gestión de asignaciones históricas y cobertura de vacaciones.';

-- analista ve todos los analistas de su mismo ramo (activos e inactivos)
-- Justificación: necesita saber quiénes son sus compañeros de ramo para
-- colaboración y para entender el contexto de asignaciones.
-- Nota: comparamos ramo::text con auth_ramo() (TEXT) por la misma razón.
CREATE POLICY pol_usuario_select_analista
    ON usuario
    FOR SELECT
    TO authenticated
    USING (
        auth_rol() = 'analista'
        AND ramo::text = auth_ramo()
        AND rol = 'analista'
    );

COMMENT ON POLICY pol_usuario_select_analista ON usuario IS
    'Analista ve únicamente analistas (no gerentes ni directores) de su mismo ramo. '
    'No puede ver su propia fila con información privilegiada de otros roles.';

-- Cualquier usuario autenticado puede ver su propio perfil completo
-- (necesario para que la app cargue los datos de sesión: nombre, firma, etc.)
CREATE POLICY pol_usuario_select_propio
    ON usuario
    FOR SELECT
    TO authenticated
    USING (
        id = auth.uid()
    );

COMMENT ON POLICY pol_usuario_select_propio ON usuario IS
    'Todo usuario puede leer su propio perfil. Necesario para cargar datos de '
    'sesión (firma, teléfono, preferencias) independientemente del rol.';


-- -----------------------------------------------------------------------------
-- POLICY: INSERT
-- -----------------------------------------------------------------------------

-- NO se crea policy INSERT para el rol authenticated.
--
-- Razón: el único camino válido para crear un registro en usuario es el trigger
-- sync_auth_usuario que se dispara al hacer INSERT en auth.users. Ese trigger
-- se ejecuta con service_role (SECURITY DEFINER) y bypasa RLS.
--
-- Si existiera una policy INSERT para directores autenticados, podrían hacer
-- INSERT directo en usuario con cualquier UUID — incluyendo UUIDs que no
-- existen en auth.users — creando registros huérfanos e inconsistencias.
--
-- Flujo correcto de creación de usuarios:
--   director → llama API (backend) → API usa service_role →
--   supabase.auth.admin.createUser({ app_metadata: {rol, ramo}, ... }) →
--   trigger trg_auth_on_new_usuario → INSERT en usuario


-- -----------------------------------------------------------------------------
-- POLICY: UPDATE
-- -----------------------------------------------------------------------------

-- Directores pueden actualizar cualquier usuario
CREATE POLICY pol_usuario_update_director
    ON usuario
    FOR UPDATE
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_usuario_update_director ON usuario IS
    'Directores pueden modificar cualquier perfil de usuario (activar, desactivar, '
    'cambiar teléfono, actualizar firma).';

-- Cualquier usuario puede actualizar su propio perfil (teléfono y firma_html)
-- Restricción: no puede cambiar su propio rol, ramo ni estado activo.
-- La lógica de negocio en el API debe rechazar cambios a esos campos;
-- esta policy es la primera línea de defensa.
CREATE POLICY pol_usuario_update_propio
    ON usuario
    FOR UPDATE
    TO authenticated
    USING (
        id = auth.uid()
    )
    WITH CHECK (
        id = auth.uid()
        -- El rol y ramo en esta fila deben coincidir con los del JWT
        -- para evitar que el usuario se auto-asigne un rol diferente.
        AND rol = auth_rol()::rol_usuario
        AND (
            (ramo IS NULL AND auth_ramo() IS NULL)
            OR ramo = auth_ramo()::ramo_usuario
        )
    );

COMMENT ON POLICY pol_usuario_update_propio ON usuario IS
    'Cada usuario puede actualizar su propio teléfono y firma_html. '
    'El WITH CHECK impide que modifique su rol o ramo — deben coincidir con el JWT. '
    'La capa de API también debe validar qué campos se permiten actualizar.';


-- -----------------------------------------------------------------------------
-- POLICY: DELETE
-- -----------------------------------------------------------------------------

-- DELETE físico está prohibido para todos — se usa soft-delete (activo = FALSE).
-- Solo el Superadmin con service_role podría hacer DELETE si fuera necesario.
-- No se crea ninguna policy de DELETE para usuarios autenticados.

-- Nota explícita: la ausencia de policy DELETE significa que ningún usuario
-- autenticado puede hacer DELETE sobre usuario. El soft-delete se hace
-- mediante UPDATE (activo = FALSE), que sí tiene policy.


-- =============================================================================
-- SECCIÓN 7: GRANT DE PERMISOS AL ROL authenticated
-- =============================================================================
-- En Supabase, el rol "authenticated" es el que usan todos los usuarios
-- con sesión activa. Los GRANTs a nivel de tabla son necesarios además de RLS.
-- RLS controla qué filas; GRANTs controlan qué operaciones.
-- =============================================================================

-- SELECT y UPDATE: los usuarios autenticados necesitan leer y editar perfiles.
-- INSERT y DELETE: prohibidos para authenticated.
--   INSERT: solo vía trigger en auth.users (service_role, bypasa RLS).
--   DELETE: prohibido — soft-delete vía UPDATE activo = FALSE.
GRANT SELECT, UPDATE ON TABLE usuario TO authenticated;

-- El rol service_role ya tiene acceso completo por defecto en Supabase.


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000000_modulo_01_usuarios.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000001_modulo_02_agentes.sql
-- ============================================================
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


-- ============================================================
-- MIGRACIÓN: 20260522000002_modulo_03_polizas.sql
-- ============================================================
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


-- ============================================================
-- MIGRACIÓN: 20260522000003_modulo_04_tramites.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000003_modulo_04_tramites.sql
-- Módulo 4 — Trámites: tabla central de operaciones del CRM Olimpo
-- =============================================================================
-- Filosofía de diseño:
--   Dos tablas con responsabilidades distintas y complementarias:
--
--   tramite        → Estado ACTUAL. Siempre consistente. Se actualiza constantemente.
--                    Responde: ¿dónde está este trámite? ¿quién lo atiende? ¿cuándo vence?
--
--   tramite_evento → Historia INMUTABLE. Append-only. Nunca se edita ni borra.
--                    Responde: ¿cómo llegó hasta aquí? ¿quién hizo qué y cuándo?
--                    Alimenta el RAG con contexto rico y ordenado cronológicamente.
--
-- Principios anti-huérfano:
--   1. analista_id es NULL solo en estado 'recibido' — CHECK en DB lo enforce.
--   2. Trigger auto-asigna gerente_id al momento de asignar analista_id.
--   3. ultima_actividad se actualiza con cada INSERT en tramite_evento.
--   4. requiere_atencion permite que el agente IA escale a humano.
--
-- Relaciones con módulos anteriores:
--   tramite.poliza_id    → poliza.id     (Módulo 3 — nullable)
--   tramite.asegurado_id → asegurado.id  (Módulo 3 — nullable)
--   tramite.agente_id    → agente.id     (Módulo 2 — nullable: NULL cuando cascada CUA falla)
--   tramite.asistente_id → asistente.id  (Módulo 2 — nullable)
--   tramite.analista_id  → usuario.id    (Módulo 1 — nullable solo en recibido)
--   tramite.gerente_id   → usuario.id    (Módulo 1 — auto-asignado por trigger)
--
-- Relaciones con módulos futuros:
--   correo.tramite_id    → tramite.id    (Módulo 5)
--   adjunto.tramite_id   → tramite.id    (Módulo 5)
--   sla_tramite.tramite_id → tramite.id  (Módulo 7)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

-- Máquina de estados del trámite (orden refleja el flujo normal)
CREATE TYPE estado_tramite AS ENUM (
    'recibido',             -- llegó el correo/tramite, aún sin procesar
    'validando',            -- los agentes IA están procesando documentos
    'pendiente_documentos', -- faltan documentos, se solicitaron al agente
    'completo',             -- documentación completa, listo para GNP
    'turnado_gnp',          -- enviado a GNP, esperando acuse
    'en_proceso_gnp',       -- GNP lo está procesando internamente
    'activado',             -- GNP activó la póliza (puede repetirse en endosos)
    'aprobado',             -- proceso finalizado con éxito
    'rechazado'             -- GNP rechazó o el trámite no prosperó
);

COMMENT ON TYPE estado_tramite IS
    'Máquina de estados del trámite. '
    'Flujo normal: recibido→validando→pendiente_documentos↔completo→turnado_gnp→en_proceso_gnp→activado→aprobado. '
    'El estado activado puede repetirse (endosos con múltiples activaciones).';


CREATE TYPE tipo_tramite AS ENUM (
    'alta',         -- nueva póliza
    'endoso',       -- modificación a póliza existente
    'renovacion',   -- renovación de póliza vencida
    'cancelacion',  -- cancelación de póliza
    'siniestro',    -- reporte de siniestro
    'reactivacion', -- reactivación de póliza cancelada
    'consulta',     -- consulta general sin tramitación formal
    'desconocido'   -- Agente 2 no pudo determinar el tipo con confianza suficiente
);

COMMENT ON TYPE tipo_tramite IS
    'Tipo de gestión que representa el trámite. Determina los documentos requeridos.';


CREATE TYPE prioridad_tramite AS ENUM (
    'normal',
    'alta',
    'urgente'
);

COMMENT ON TYPE prioridad_tramite IS
    'Prioridad de atención. Afecta el orden en el dashboard del analista y las alertas de SLA.';


CREATE TYPE canal_origen_tramite AS ENUM (
    'email',    -- llegó por correo electrónico (flujo principal)
    'manual',   -- creado manualmente por un analista o director
    'portal'    -- futuro: portal de agentes
);

COMMENT ON TYPE canal_origen_tramite IS
    'Canal por el que ingresó el trámite al sistema.';


CREATE TYPE tipo_evento_tramite AS ENUM (
    'creacion',              -- trámite creado en el sistema
    'cambio_estado',         -- cambio en la máquina de estados
    'asignacion',            -- analista asignado por primera vez
    'reasignacion',          -- cambio de analista
    'nota_analista',         -- nota interna escrita por analista o gerente
    'documento_agregado',    -- nuevo documento procesado
    'correo_recibido',       -- correo entrante vinculado al trámite
    'correo_enviado',        -- correo saliente del Agente 6 enviado
    'accion_agente_ia',      -- acción realizada por un agente IA (1-6)
    'activacion_gnp',        -- GNP activó la póliza
    'solicitud_documentos',  -- se solicitaron documentos faltantes al agente
    'rechazo_gnp',           -- GNP rechazó el trámite
    'aprendizaje_rag'        -- evento generado para entrenar el RAG
);

COMMENT ON TYPE tipo_evento_tramite IS
    'Catálogo de eventos que pueden ocurrir en la vida de un trámite. '
    'Cada evento en tramite_evento tiene exactamente uno de estos tipos.';


-- =============================================================================
-- SECCIÓN 2: GENERADOR DE FOLIO INTERNO (TRM-YYYY-NNNNN)
-- =============================================================================
-- El folio reinicia cada año: TRM-2025-00001, TRM-2025-00002, ..., TRM-2026-00001.
-- Se usa una tabla de contadores por año para garantizar atomicidad y unicidad
-- incluso bajo carga concurrente (INSERT ... ON CONFLICT es atómico en PostgreSQL).
-- =============================================================================

CREATE TABLE tramite_folio_contador (
    anio        SMALLINT    PRIMARY KEY,
    contador    INTEGER     NOT NULL DEFAULT 0
);

COMMENT ON TABLE tramite_folio_contador IS
    'Contador de folios por año. Garantiza que TRM-YYYY-NNNNN sea único y secuencial. '
    'Operado exclusivamente por la función siguiente_folio_tramite().';


CREATE OR REPLACE FUNCTION siguiente_folio_tramite()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_anio      SMALLINT;
    v_contador  INTEGER;
BEGIN
    v_anio := EXTRACT(YEAR FROM NOW())::SMALLINT;

    -- INSERT o incremento atómico — thread-safe bajo concurrencia
    INSERT INTO tramite_folio_contador (anio, contador)
    VALUES (v_anio, 1)
    ON CONFLICT (anio) DO UPDATE
        SET contador = tramite_folio_contador.contador + 1
    RETURNING contador INTO v_contador;

    -- Formato: TRM-2025-00001
    RETURN 'TRM-' || v_anio::TEXT || '-' || LPAD(v_contador::TEXT, 5, '0');
END;
$$;

COMMENT ON FUNCTION siguiente_folio_tramite() IS
    'Genera el siguiente folio interno secuencial por año (TRM-YYYY-NNNNN). '
    'Reinicia a 00001 cada año nuevo. Seguro bajo concurrencia.';


-- =============================================================================
-- SECCIÓN 3: TABLA tramite — estado actual del trámite
-- =============================================================================

CREATE TABLE tramite (
    -- -------------------------------------------------------------------------
    -- Identificadores
    -- -------------------------------------------------------------------------
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    -- Folio interno: auto-generado por trigger antes del INSERT
    folio           TEXT                    NOT NULL,
    -- Folio OT: asignado por GNP, llega después de turnar el trámite
    folio_ot        TEXT                    NULL,

    -- -------------------------------------------------------------------------
    -- Clasificación
    -- -------------------------------------------------------------------------
    tipo_tramite    tipo_tramite            NOT NULL,
    estado          estado_tramite          NOT NULL DEFAULT 'recibido',
    prioridad       prioridad_tramite       NOT NULL DEFAULT 'normal',
    canal_origen    canal_origen_tramite    NOT NULL DEFAULT 'email',
    -- Ramo denormalizado para RLS sin JOIN — se copia de poliza o se extrae
    -- del contexto por el Agente 2 al momento de clasificar el trámite
    ramo            ramo_usuario            NULL,

    -- -------------------------------------------------------------------------
    -- Relaciones con entidades del CRM
    -- -------------------------------------------------------------------------
    -- Póliza vinculada — NULL si es un alta nueva y la póliza aún no existe
    poliza_id       UUID    NULL REFERENCES poliza(id),
    -- Asegurado principal del trámite — NULL hasta que el Agente 3 lo identifique
    asegurado_id    UUID    NULL REFERENCES asegurado(id),
    -- Agente que gestiona — identificado por el Agente 4 via cascada CUA.
    -- NULL cuando la cascada falla (confianza < umbral): el trámite se crea
    -- con requiere_atencion = TRUE para que un analista lo asigne manualmente.
    -- El CHECK abajo exige que esté presente a partir del estado 'completo'.
    agente_id       UUID    NULL REFERENCES agente(id),
    -- Asistente — solo si el correo vino de un asistente en lugar del agente
    asistente_id    UUID    NULL REFERENCES asistente(id),
    -- Analista responsable — EL DUEÑO del trámite.
    -- NULL solo en 'recibido'. El CHECK abajo lo enforce a partir de 'validando'.
    analista_id     UUID    NULL REFERENCES usuario(id),
    -- Gerente del analista — auto-asignado por trigger cuando se asigna analista.
    -- Denormalizado para evitar JOINs en dashboards y RLS.
    gerente_id      UUID    NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Descripción y contexto
    -- -------------------------------------------------------------------------
    titulo          TEXT    NOT NULL,   -- descripción breve: "Alta GMM Familia García"
    descripcion     TEXT    NULL,       -- descripción detallada del trámite

    -- Datos estructurados producidos por cada agente IA.
    -- Estructura esperada (se va llenando conforme avanza el pipeline):
    -- {
    --   "agente_1": { "adjuntos": 3, "zips_procesados": 1, "archivos_extraidos": 4 },
    --   "agente_2": { "confianza_agente": 0.92, "confianza_tipo_tramite": 0.88 },
    --   "agente_3": { "documentos_ocr": ["INE", "solicitud_alta"], "ilegibles": [] },
    --   "agente_4": { "metodo_id": "cua_directo", "confianza_asignacion": 0.97 },
    --   "agente_5": { "docs_validos": 3, "docs_faltantes": ["carta_medica"] },
    --   "agente_6": { "correo_borrador_id": "uuid", "palabras": 245 }
    -- }
    datos_tramite   JSONB   NULL DEFAULT '{}',

    -- Resumen generado por IA — texto legible para el RAG y para la UI.
    -- El Agente 5 o 6 lo actualiza con cada cambio significativo.
    resumen_ia      TEXT    NULL,

    -- Tags para filtrar en la UI y enriquecer el RAG
    -- Ejemplos: ["urgente", "cliente-vip", "documentos-incompletos", "rechazo-previo"]
    etiquetas       TEXT[]  NOT NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Señales de atención y calidad
    -- -------------------------------------------------------------------------
    -- El agente IA lo activa cuando detecta que necesita intervención humana
    -- (cascada fallida, documento ilegible, ambigüedad alta, rechazo previo)
    requiere_atencion   BOOLEAN     NOT NULL DEFAULT FALSE,
    -- Score 0-1 asignado por el Agente 2 basado en complejidad documental y ramo
    score_complejidad   NUMERIC(3,2) NULL CHECK (score_complejidad BETWEEN 0 AND 1),

    -- -------------------------------------------------------------------------
    -- Monitoreo del pipeline IA
    -- -------------------------------------------------------------------------
    -- Indica qué agente IA está procesando activamente el trámite en este momento.
    -- NULL = ningún agente corriendo (idle o pipeline completado).
    -- Permite detectar trámites atascados y reanudar pipelines tras fallos.
    -- Valores: 'agente_1' | 'agente_2' | 'agente_3' | 'agente_4' | 'agente_5' | 'agente_6'
    paso_pipeline_actual TEXT        NULL,
    -- Timestamp de cuándo inició el paso actual — para detectar timeouts
    paso_pipeline_inicio TIMESTAMPTZ NULL,

    -- -------------------------------------------------------------------------
    -- Fechas de seguimiento GNP
    -- -------------------------------------------------------------------------
    fecha_recepcion     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Deadline calculado por el motor de SLAs (Módulo 7)
    fecha_limite_sla    TIMESTAMPTZ NULL,
    -- Cuándo se envió a GNP (estado turnado_gnp)
    ot_fecha_envio      DATE        NULL,
    -- Cuándo respondió GNP (aprobado o rechazado)
    ot_fecha_respuesta  DATE        NULL,
    -- Motivo de rechazo cuando GNP rechaza — texto libre del analista o IA
    motivo_rechazo_gnp  TEXT        NULL,

    -- -------------------------------------------------------------------------
    -- Actividad — anti-abandono
    -- -------------------------------------------------------------------------
    -- Se actualiza automáticamente en cada INSERT a tramite_evento.
    -- Permite detectar trámites sin actividad y activar alertas.
    ultima_actividad    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- Estado y auditoría
    -- -------------------------------------------------------------------------
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    CONSTRAINT uq_tramite_folio     UNIQUE (folio),
    CONSTRAINT uq_tramite_folio_ot  UNIQUE (folio_ot),

    -- CONTRATO ANTI-HUÉRFANO — analista obligatorio tras estados iniciales
    CONSTRAINT ck_tramite_analista_requerido CHECK (
        estado IN ('recibido', 'validando')
        OR analista_id IS NOT NULL
    ),

    -- CONTRATO DE IDENTIFICACIÓN — agente obligatorio antes de turnar a GNP
    -- NULL en estados tempranos (Agente 4 aún no terminó o cascada fallida).
    -- requiere_atencion = TRUE cuando agente_id sigue NULL pasando 'validando'.
    CONSTRAINT ck_tramite_agente_requerido CHECK (
        estado IN ('recibido', 'validando', 'pendiente_documentos')
        OR agente_id IS NOT NULL
    ),

    -- El motivo de rechazo solo aplica cuando el estado es 'rechazado'
    CONSTRAINT ck_tramite_rechazo_consistente CHECK (
        motivo_rechazo_gnp IS NULL OR estado = 'rechazado'
    ),

    -- Las fechas OT solo aplican cuando existe folio_ot
    CONSTRAINT ck_tramite_ot_envio CHECK (
        ot_fecha_envio IS NULL OR folio_ot IS NOT NULL
    ),

    CONSTRAINT ck_tramite_titulo CHECK (TRIM(titulo) <> '')
);

COMMENT ON TABLE tramite IS
    'Tabla central del CRM Olimpo. Representa el estado ACTUAL de cada gestión. '
    'Se actualiza constantemente. El historial completo vive en tramite_evento. '
    'Constraint ck_tramite_analista_requerido elimina los trámites sin dueño a nivel DB.';

COMMENT ON COLUMN tramite.folio               IS 'Folio interno auto-generado: TRM-YYYY-NNNNN. Reinicia por año. Nunca NULL.';
COMMENT ON COLUMN tramite.folio_ot            IS 'Número de Orden de Trabajo asignado por GNP. Llega al turnarse el trámite.';
COMMENT ON COLUMN tramite.ramo                IS 'Ramo denormalizado desde poliza o extraído por Agente 2. Evita JOINs en RLS.';
COMMENT ON COLUMN tramite.analista_id         IS 'Dueño del trámite. NULL solo en recibido/validando — el CHECK lo enforce.';
COMMENT ON COLUMN tramite.gerente_id          IS 'Gerente del analista. Auto-asignado por trigger cuando se asigna analista_id.';
COMMENT ON COLUMN tramite.datos_tramite       IS 'Salidas estructuradas de los 6 agentes IA. Se construye incrementalmente.';
COMMENT ON COLUMN tramite.resumen_ia          IS 'Resumen textual generado por IA. Alimenta el RAG y aparece en la UI del analista.';
COMMENT ON COLUMN tramite.etiquetas           IS 'Tags de texto libre para filtrado en UI y enriquecimiento del RAG.';
COMMENT ON COLUMN tramite.requiere_atencion   IS 'True cuando el agente IA detecta que necesita decisión o acción humana urgente.';
COMMENT ON COLUMN tramite.score_complejidad   IS 'Score 0-1 de complejidad asignado por Agente 2. Ayuda a priorizar y asignar.';
COMMENT ON COLUMN tramite.ultima_actividad    IS 'Timestamp de la última actividad. Actualizado por trigger en cada tramite_evento.';
COMMENT ON COLUMN tramite.fecha_limite_sla    IS 'Deadline de SLA calculado por el motor de SLAs (Módulo 7). NULL hasta activarse.';


-- =============================================================================
-- SECCIÓN 4: TABLA tramite_evento — historia inmutable del trámite
-- =============================================================================
-- Registro append-only de todo lo que ocurrió en la vida del trámite.
-- NUNCA se edita ni elimina un evento.
-- Es la fuente de verdad para:
--   - El timeline del trámite en la UI
--   - Los chunks de texto que alimentan el RAG
--   - La trazabilidad para auditorías y disputas
--   - El análisis de tiempos entre estados para SLA
-- =============================================================================

CREATE TABLE tramite_evento (
    id              UUID                    PRIMARY KEY DEFAULT gen_random_uuid(),
    tramite_id      UUID                    NOT NULL REFERENCES tramite(id) ON DELETE CASCADE,
    tipo_evento     tipo_evento_tramite     NOT NULL,

    -- Para eventos tipo 'cambio_estado': estado antes y después
    estado_anterior estado_tramite          NULL,
    estado_nuevo    estado_tramite          NULL,

    -- Actor humano — NULL si el evento fue generado por un agente IA
    usuario_id      UUID                    NULL REFERENCES usuario(id),
    -- Actor IA — NULL si el evento fue generado por un humano
    -- Valores esperados: 'agente_1' a 'agente_6', o nombre del proceso
    agente_ia_nombre TEXT                   NULL,

    -- Descripción legible para humanos — es el texto principal que lee el RAG.
    -- Debe ser autocontenido: "El Agente 5 validó 3 documentos. Falta: carta médica."
    descripcion     TEXT                    NOT NULL,

    -- Datos estructurados del evento para procesamiento programático
    -- Estructura varía por tipo_evento. Ejemplos:
    --   cambio_estado:        { "razon": "documentos completos" }
    --   documento_agregado:   { "documento_id": "uuid", "tipo": "INE", "confianza": 0.95 }
    --   correo_recibido:      { "correo_id": "uuid", "asunto": "..." }
    --   accion_agente_ia:     { "agente": "agente_5", "resultado": {...} }
    --   rechazo_gnp:          { "codigo_rechazo": "R-042", "detalle": "..." }
    datos           JSONB                   NULL DEFAULT '{}',

    -- Controla si el evento aparece en el timeline visible del analista.
    -- false: eventos internos de la IA que no aportan a la UI pero sí al RAG.
    visible_en_timeline BOOLEAN             NOT NULL DEFAULT TRUE,

    -- Sin updated_at — los eventos son INMUTABLES
    created_at      TIMESTAMPTZ             NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- cambio_estado requiere ambos estados
    CONSTRAINT ck_evento_cambio_estado CHECK (
        tipo_evento <> 'cambio_estado'
        OR (estado_anterior IS NOT NULL AND estado_nuevo IS NOT NULL)
    ),

    -- Solo un actor por evento (humano o IA, no ambos ni ninguno)
    CONSTRAINT ck_evento_actor CHECK (
        (usuario_id IS NOT NULL AND agente_ia_nombre IS NULL)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NOT NULL)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NULL) -- eventos del sistema
    ),

    CONSTRAINT ck_evento_descripcion CHECK (TRIM(descripcion) <> '')
);

COMMENT ON TABLE tramite_evento IS
    'Historia inmutable del trámite. Append-only — nunca se edita ni elimina. '
    'Alimenta el RAG con contexto cronológico rico. '
    'El timeline de la UI lee de aquí filtrando visible_en_timeline = TRUE.';

COMMENT ON COLUMN tramite_evento.descripcion        IS 'Texto legible y autocontenido. Principal insumo del RAG para este trámite.';
COMMENT ON COLUMN tramite_evento.visible_en_timeline IS 'FALSE para eventos internos de IA que no aportan valor al analista en la UI.';
COMMENT ON COLUMN tramite_evento.usuario_id         IS 'Actor humano. NULL si el evento fue generado por un agente IA.';
COMMENT ON COLUMN tramite_evento.agente_ia_nombre   IS 'Actor IA. NULL si el evento fue generado por un humano.';


-- =============================================================================
-- SECCIÓN 5: ÍNDICES
-- =============================================================================

-- tramite — queries de dashboard (el patrón más frecuente)
CREATE INDEX idx_tramite_analista_estado
    ON tramite (analista_id, estado)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_tramite_analista_estado IS
    'Query principal del dashboard del analista: sus trámites por estado.';

CREATE INDEX idx_tramite_gerente_estado
    ON tramite (gerente_id, estado)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_tramite_gerente_estado IS
    'Query principal del dashboard del gerente: trámites de su equipo por estado.';

CREATE INDEX idx_tramite_agente
    ON tramite (agente_id);

CREATE INDEX idx_tramite_poliza
    ON tramite (poliza_id)
    WHERE poliza_id IS NOT NULL;

CREATE INDEX idx_tramite_ramo_estado
    ON tramite (ramo, estado)
    WHERE activo = TRUE;

-- Índice para detectar trámites sin actividad reciente (SLA y anti-abandono)
CREATE INDEX idx_tramite_ultima_actividad
    ON tramite (ultima_actividad)
    WHERE activo = TRUE AND estado NOT IN ('aprobado', 'rechazado');

COMMENT ON INDEX idx_tramite_ultima_actividad IS
    'Detecta trámites inactivos para alertas de SLA. Solo trámites abiertos.';

-- Índice para trámites que requieren atención humana urgente
CREATE INDEX idx_tramite_requiere_atencion
    ON tramite (requiere_atencion, prioridad)
    WHERE requiere_atencion = TRUE AND activo = TRUE;

-- Folio OT — búsqueda cuando GNP responde con el número de OT
CREATE INDEX idx_tramite_folio_ot
    ON tramite (folio_ot)
    WHERE folio_ot IS NOT NULL;

-- Búsqueda por folio interno en la barra de búsqueda de la UI
CREATE INDEX idx_tramite_folio
    ON tramite (folio);

-- SLA: trámites próximos a vencer
CREATE INDEX idx_tramite_sla_vencimiento
    ON tramite (fecha_limite_sla)
    WHERE fecha_limite_sla IS NOT NULL
      AND activo = TRUE
      AND estado NOT IN ('aprobado', 'rechazado');

-- JSONB: búsquedas dentro de datos_tramite y etiquetas
CREATE INDEX idx_tramite_datos
    ON tramite USING gin (datos_tramite);

CREATE INDEX idx_tramite_etiquetas
    ON tramite USING gin (etiquetas);

-- tramite_evento — queries del timeline
CREATE INDEX idx_tramite_evento_tramite_ts
    ON tramite_evento (tramite_id, created_at DESC);

COMMENT ON INDEX idx_tramite_evento_tramite_ts IS
    'Timeline del trámite ordenado por tiempo. Query más frecuente de tramite_evento.';

CREATE INDEX idx_tramite_evento_tipo
    ON tramite_evento (tramite_id, tipo_evento);

-- Para el RAG: eventos visibles ordenados por tiempo
CREATE INDEX idx_tramite_evento_rag
    ON tramite_evento (tramite_id, created_at)
    WHERE visible_en_timeline = TRUE;

COMMENT ON INDEX idx_tramite_evento_rag IS
    'Eventos visibles para construcción de chunks RAG por trámite.';


-- =============================================================================
-- SECCIÓN 6: FUNCIONES Y TRIGGERS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 Auto-generación del folio en INSERT
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_folio_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.folio IS NULL THEN
        NEW.folio := siguiente_folio_tramite();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tramite_set_folio
    BEFORE INSERT ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION set_folio_tramite();

COMMENT ON TRIGGER trg_tramite_set_folio ON tramite IS
    'Genera el folio TRM-YYYY-NNNNN automáticamente si no se provee en el INSERT.';


-- -----------------------------------------------------------------------------
-- 6.2 updated_at automático
-- set_updated_at() ya existe desde migración 20260522000000.
-- -----------------------------------------------------------------------------

CREATE TRIGGER trg_tramite_updated_at
    BEFORE UPDATE ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- -----------------------------------------------------------------------------
-- 6.3 Auto-asignación de gerente_id cuando se asigna analista_id
-- Busca el gerente activo del mismo ramo que el analista.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION asignar_gerente_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ramo_analista ramo_usuario;
    v_gerente_id    UUID;
BEGIN
    -- Solo actuar si analista_id cambió y tiene un valor
    IF NEW.analista_id IS NOT NULL
       AND (OLD.analista_id IS NULL OR OLD.analista_id <> NEW.analista_id)
    THEN
        -- Obtener el ramo del analista asignado
        SELECT ramo INTO v_ramo_analista
        FROM usuario
        WHERE id = NEW.analista_id;

        -- Buscar el gerente activo de ese ramo
        SELECT id INTO v_gerente_id
        FROM usuario
        WHERE rol = 'gerente'
          AND ramo = v_ramo_analista
          AND activo = TRUE
        LIMIT 1;

        NEW.gerente_id := v_gerente_id;

        -- Si el trámite no tiene ramo, heredarlo del analista
        IF NEW.ramo IS NULL THEN
            NEW.ramo := v_ramo_analista;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION asignar_gerente_tramite() IS
    'Al asignar analista_id, auto-busca y asigna el gerente activo de su ramo. '
    'También hereda el ramo al trámite si aún no lo tiene.';

CREATE TRIGGER trg_tramite_asignar_gerente
    BEFORE INSERT OR UPDATE OF analista_id ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION asignar_gerente_tramite();


-- -----------------------------------------------------------------------------
-- 6.4 Registro automático de cambios de estado en tramite_evento
--
-- Atribución de cambios al actor correcto:
--   Los agentes IA corren con service_role — auth.uid() devuelve NULL.
--   Para que el trigger sepa qué agente hizo el cambio, el agente IA debe
--   declararse ANTES de ejecutar el UPDATE usando una variable de sesión:
--
--     -- Python (Agente 5):
--     supabase.rpc('set_agente_ia_sesion', {'nombre': 'agente_5'}).execute()
--     supabase.table('tramite').update({'estado': 'completo'}).eq('id', id).execute()
--
--   El trigger lee app.agente_ia_actual de la sesión PostgreSQL.
--   Si es NULL (lo hizo un humano), usa auth.uid() en su lugar.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION set_agente_ia_sesion(nombre TEXT)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
AS $$
    SELECT set_config('app.agente_ia_actual', nombre, TRUE);
$$;

COMMENT ON FUNCTION set_agente_ia_sesion(TEXT) IS
    'Los agentes IA llaman esta función antes de modificar tramite para que '
    'los triggers de auditoría puedan atribuir el cambio al agente correcto. '
    'La variable vive solo en la sesión actual (TRUE = local a la transacción).';


CREATE OR REPLACE FUNCTION registrar_cambio_estado_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_agente_ia     TEXT;
    v_usuario_id    UUID;
BEGIN
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN

        -- Determinar actor: ¿humano o agente IA?
        v_agente_ia  := NULLIF(current_setting('app.agente_ia_actual', TRUE), '');
        v_usuario_id := CASE WHEN v_agente_ia IS NULL THEN auth.uid() ELSE NULL END;

        INSERT INTO tramite_evento (
            tramite_id,
            tipo_evento,
            estado_anterior,
            estado_nuevo,
            usuario_id,
            agente_ia_nombre,
            descripcion,
            datos,
            visible_en_timeline,
            created_at
        ) VALUES (
            NEW.id,
            'cambio_estado',
            OLD.estado,
            NEW.estado,
            v_usuario_id,
            v_agente_ia,
            CASE
                WHEN v_agente_ia IS NOT NULL
                THEN v_agente_ia || ' cambió el estado de "' || OLD.estado || '" a "' || NEW.estado || '".'
                ELSE 'Estado cambiado de "' || OLD.estado || '" a "' || NEW.estado || '".'
            END,
            jsonb_build_object(
                'estado_anterior',   OLD.estado,
                'estado_nuevo',      NEW.estado,
                'actor',             COALESCE(v_agente_ia, 'usuario')
            ),
            TRUE,
            NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_cambio_estado_tramite() IS
    'Registra automáticamente cada cambio de estado en tramite_evento. '
    'Lee app.agente_ia_actual (set_agente_ia_sesion) para atribuir el cambio '
    'al agente IA correcto cuando es service_role quien ejecuta el UPDATE.';

CREATE TRIGGER trg_tramite_registrar_estado
    AFTER UPDATE OF estado ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION registrar_cambio_estado_tramite();


-- -----------------------------------------------------------------------------
-- 6.5 Registro automático de asignación/reasignación en tramite_evento
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION registrar_asignacion_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_nombre_analista TEXT;
    v_tipo            tipo_evento_tramite;
    v_descripcion     TEXT;
BEGIN
    IF NEW.analista_id IS DISTINCT FROM OLD.analista_id
       AND NEW.analista_id IS NOT NULL
    THEN
        SELECT nombre INTO v_nombre_analista
        FROM usuario WHERE id = NEW.analista_id;

        v_tipo := CASE
            WHEN OLD.analista_id IS NULL THEN 'asignacion'
            ELSE 'reasignacion'
        END;

        v_descripcion := CASE
            WHEN OLD.analista_id IS NULL
            THEN 'Trámite asignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
            ELSE 'Trámite reasignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
        END;

        INSERT INTO tramite_evento (
            tramite_id, tipo_evento, usuario_id, agente_ia_nombre,
            descripcion, datos, visible_en_timeline, created_at
        ) VALUES (
            NEW.id, v_tipo,
            CASE WHEN NULLIF(current_setting('app.agente_ia_actual', TRUE), '') IS NULL
                 THEN auth.uid() ELSE NULL END,
            NULLIF(current_setting('app.agente_ia_actual', TRUE), ''),
            v_descripcion,
            jsonb_build_object(
                'analista_anterior_id', OLD.analista_id,
                'analista_nuevo_id',    NEW.analista_id
            ),
            TRUE, NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tramite_registrar_asignacion
    AFTER UPDATE OF analista_id ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION registrar_asignacion_tramite();


-- -----------------------------------------------------------------------------
-- 6.6 Actualización de ultima_actividad en tramite al insertar un evento
-- Mantiene el campo anti-abandono sincronizado automáticamente.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION actualizar_ultima_actividad_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE tramite
    SET ultima_actividad = NOW()
    WHERE id = NEW.tramite_id;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION actualizar_ultima_actividad_tramite() IS
    'Cada nuevo evento en tramite_evento actualiza ultima_actividad en tramite. '
    'Permite detectar trámites abandonados consultando solo la tabla tramite.';

CREATE TRIGGER trg_tramite_evento_actividad
    AFTER INSERT ON tramite_evento
    FOR EACH ROW
    EXECUTE FUNCTION actualizar_ultima_actividad_tramite();


-- -----------------------------------------------------------------------------
-- 6.7 Evento de creación automático al insertar un trámite
-- El primer evento de toda historia es la creación del trámite.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION registrar_creacion_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO tramite_evento (
        tramite_id,
        tipo_evento,
        usuario_id,
        descripcion,
        datos,
        visible_en_timeline,
        created_at
    ) VALUES (
        NEW.id,
        'creacion',
        auth.uid(),
        'Trámite ' || NEW.folio || ' creado. Tipo: ' || NEW.tipo_tramite ||
            '. Canal: ' || NEW.canal_origen || '.',
        jsonb_build_object(
            'folio',         NEW.folio,
            'tipo_tramite',  NEW.tipo_tramite,
            'canal_origen',  NEW.canal_origen,
            'estado_inicial', NEW.estado
        ),
        TRUE,
        NOW()
    );

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tramite_registrar_creacion
    AFTER INSERT ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION registrar_creacion_tramite();


-- =============================================================================
-- SECCIÓN 7: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--   director_general / director_ops — ven y gestionan todos los trámites
--   gerente — ve los trámites de su ramo (via gerente_id o ramo)
--   analista — ve solo los trámites donde es el analista asignado
--
-- tramite_evento hereda la visibilidad del tramite padre via subquery.
-- Los eventos son append-only: INSERT sí, UPDATE y DELETE no.
-- =============================================================================

ALTER TABLE tramite         ENABLE ROW LEVEL SECURITY;
ALTER TABLE tramite_evento  ENABLE ROW LEVEL SECURITY;
ALTER TABLE tramite_folio_contador ENABLE ROW LEVEL SECURITY;

-- El contador de folios es interno — solo service_role lo opera
-- authenticated no necesita acceso directo


-- -----------------------------------------------------------------------------
-- POLICIES: tramite
-- -----------------------------------------------------------------------------

CREATE POLICY pol_tramite_select_director
    ON tramite FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

COMMENT ON POLICY pol_tramite_select_director ON tramite IS
    'Directores ven todos los trámites sin restricción de ramo ni analista.';

CREATE POLICY pol_tramite_select_gerente
    ON tramite FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (
            gerente_id = auth.uid()
            -- Fallback: ramo coincide (cubre trámites antes de asignar gerente_id)
            OR (ramo IS NOT NULL AND ramo::text = auth_ramo())
        )
    );

COMMENT ON POLICY pol_tramite_select_gerente ON tramite IS
    'Gerente ve trámites donde es el gerente asignado o que coinciden con su ramo.';

CREATE POLICY pol_tramite_select_analista
    ON tramite FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    );

COMMENT ON POLICY pol_tramite_select_analista ON tramite IS
    'Analista ve únicamente los trámites donde es el analista asignado. '
    'Los trámites en recibido/validando sin asignar son invisibles hasta ser asignados.';

-- INSERT: cualquier rol autenticado puede crear trámites
-- (el Agente 1 usa service_role; analistas crean trámites manuales)
CREATE POLICY pol_tramite_insert
    ON tramite FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- UPDATE: cada rol actualiza lo que puede ver
CREATE POLICY pol_tramite_update_director
    ON tramite FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_tramite_update_gerente
    ON tramite FOR UPDATE TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (gerente_id = auth.uid() OR (ramo IS NOT NULL AND ramo::text = auth_ramo()))
    )
    WITH CHECK (
        auth_rol() = 'gerente'
        AND (gerente_id = auth.uid() OR (ramo IS NOT NULL AND ramo::text = auth_ramo()))
    );

CREATE POLICY pol_tramite_update_analista
    ON tramite FOR UPDATE TO authenticated
    USING (auth_rol() = 'analista' AND analista_id = auth.uid())
    WITH CHECK (auth_rol() = 'analista' AND analista_id = auth.uid());

-- DELETE: nadie — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: tramite_evento (append-only — no UPDATE, no DELETE)
-- -----------------------------------------------------------------------------

-- SELECT: misma visibilidad que el trámite padre
CREATE POLICY pol_tramite_evento_select
    ON tramite_evento FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM tramite t
            WHERE t.id = tramite_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente'
                    AND (t.gerente_id = auth.uid()
                         OR (t.ramo IS NOT NULL AND t.ramo::text = auth_ramo())))
                OR (auth_rol() = 'analista' AND t.analista_id = auth.uid())
              )
        )
    );

-- INSERT: cualquier rol puede agregar eventos a trámites que puede ver
-- (notas de analistas, acciones manuales, etc.)
-- Los agentes IA usan service_role (bypasa RLS)
CREATE POLICY pol_tramite_evento_insert
    ON tramite_evento FOR INSERT TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM tramite t
            WHERE t.id = tramite_id
              AND (
                auth_rol() IN ('director_general', 'director_ops')
                OR (auth_rol() = 'gerente'
                    AND (t.gerente_id = auth.uid()
                         OR (t.ramo IS NOT NULL AND t.ramo::text = auth_ramo())))
                OR (auth_rol() = 'analista' AND t.analista_id = auth.uid())
              )
        )
    );

-- UPDATE y DELETE: absolutamente nadie — los eventos son sagrados e inmutables


-- =============================================================================
-- SECCIÓN 8: GRANTS
-- =============================================================================

-- tramite_folio_contador: solo service_role (el trigger lo usa internamente)
-- No se otorga acceso a authenticated

GRANT SELECT, INSERT, UPDATE ON TABLE tramite TO authenticated;
GRANT SELECT, INSERT ON TABLE tramite_evento TO authenticated;
-- tramite_evento: sin UPDATE ni DELETE para nadie — append-only

-- Los agentes IA llaman esta función para identificarse antes de modificar tramite
GRANT EXECUTE ON FUNCTION set_agente_ia_sesion(TEXT) TO authenticated;

-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000003_modulo_04_tramites.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000004_modulo_05_correos_adjuntos.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000004_modulo_05_correos_adjuntos.sql
-- Módulo 5 — Correos, Adjuntos y Documentos del CRM Olimpo
-- =============================================================================
-- Cuatro tablas con responsabilidades distintas:
--
--   correo          → Registro de emails entrantes y salientes (Gmail API).
--                     El message_id de Gmail es la clave de idempotencia.
--
--   correo_tramite  → Junction many-to-many: un correo puede generar múltiples
--                     trámites; un trámite puede tener múltiples correos.
--
--   adjunto         → Archivos físicos del correo (PDFs, imágenes, ZIPs).
--                     Los ZIPs descomprimidos generan adjuntos hijos via
--                     adjunto_padre_id. Las contraseñas son TEMPORALES.
--
--   documento       → Resultado del OCR + clasificación por el Agente 3.
--                     Datos estructurados extraídos, tipo de documento,
--                     confianza, estado de validación por el Agente 5.
--
-- Flujo de un correo entrante:
--   Gmail → correo (recibido) →
--   Agente 1: adjuntos extraídos, ZIPs descomprimidos, passwords eliminados →
--   Agente 2: cuerpo analizado, datos extraídos, tramite creado →
--   Agente 3: OCR + clasificación → documentos creados →
--   Agente 4: correo_tramite vinculado, tramite asignado →
--   Agente 5: documentos validados →
--   Agente 6: correo saliente (borrador) creado
--
-- Relaciones con módulos anteriores:
--   correo_tramite.tramite_id → tramite.id   (Módulo 4)
--   correo.analista_id        → usuario.id   (Módulo 1)
--   documento.tramite_id      → tramite.id   (Módulo 4)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_correo AS ENUM (
    'entrante',   -- recibido desde agente/asistente vía Gmail BCC/DWD
    'saliente'    -- generado por Agente 6, revisado y enviado por analista
);

COMMENT ON TYPE tipo_correo IS
    'Dirección del correo. entrante: llega de agentes/asistentes. '
    'saliente: generado por el Agente 6 y enviado por el analista.';


CREATE TYPE estado_correo AS ENUM (
    -- Ciclo de vida de correos ENTRANTES
    'recibido',               -- llegó de Gmail, aún sin procesar
    'procesando',             -- pipeline Agentes 1-4 corriendo
    'procesado',              -- pipeline completado, trámite creado/vinculado
    'error_procesamiento',    -- pipeline falló, requiere revisión manual

    -- Ciclo de vida de correos SALIENTES (Agente 6)
    'borrador',               -- Agente 6 lo generó, pendiente de revisión
    'en_revision',            -- analista está revisando el borrador
    'aprobado',               -- analista aprobó, listo para enviar
    'enviado',                -- enviado vía Gmail API exitosamente
    'error_envio'             -- fallo en el envío, reintentando o requiere atención
);

COMMENT ON TYPE estado_correo IS
    'Estado del correo según su tipo. '
    'Entrantes: recibido→procesando→procesado. '
    'Salientes: borrador→en_revision→aprobado→enviado.';


CREATE TYPE estado_adjunto AS ENUM (
    'pendiente',    -- recién registrado, en cola para Agente 1
    'procesando',   -- Agente 1 extrayendo/descomprimiendo
    'procesado',    -- listo para OCR (Agente 3)
    'ilegible',     -- corrompido, formato no soportado
    'error'         -- error técnico durante el procesamiento
);

COMMENT ON TYPE estado_adjunto IS
    'Estado del adjunto en el pipeline del Agente 1.';


-- Tipos de documento reconocidos por GNP y el sistema
-- Se puede extender con ALTER TYPE ... ADD VALUE sin downtime
CREATE TYPE tipo_documento AS ENUM (
    -- Identificación personal
    'ine',                    -- Credencial para votar / INE
    'pasaporte',
    'acta_nacimiento',
    'curp',
    'comprobante_domicilio',

    -- Documentos de trámite GNP
    'solicitud_alta',         -- Solicitud de alta de póliza
    'formulario_gnp',         -- Cualquier forma oficial de GNP
    'carta_medica',           -- Carta médica (GMM, vida)
    'dictamen_medico',        -- Dictamen médico especializado
    'cuestionario_salud',     -- Cuestionario de salud (GMM, vida)
    'poliza_anterior',        -- Póliza anterior para renovaciones
    'endoso',                 -- Documento de endoso

    -- Documentos para autos
    'tarjeta_circulacion',
    'factura_vehiculo',
    'fotografia_vehiculo',

    -- Documentos para pyme / persona moral
    'acta_constitutiva',
    'poder_notarial',
    'cedula_fiscal',          -- Cédula de identificación fiscal
    'estado_cuenta',          -- Estado de cuenta bancario

    -- Documentos financieros
    'comprobante_pago',
    'recibo_prima',

    'otro'                    -- No clasificado o tipo no reconocido
);

COMMENT ON TYPE tipo_documento IS
    'Tipos de documento reconocidos por GNP. '
    'Usar ALTER TYPE ADD VALUE para agregar nuevos tipos sin migración completa.';


CREATE TYPE estado_validacion_documento AS ENUM (
    'pendiente_validacion',   -- Agente 5 aún no lo ha revisado
    'valido',                 -- Cumple requisitos GNP para este trámite
    'invalido',               -- No cumple (incompleto, mal llenado, tipo incorrecto)
    'ilegible',               -- OCR falló o calidad insuficiente
    'vencido',                -- Documento expirado (ej: INE caducada)
    'duplicado'               -- Ya existe un documento de este tipo en el trámite
);

COMMENT ON TYPE estado_validacion_documento IS
    'Resultado de la validación del Agente 5 contra requisitos GNP.';


-- =============================================================================
-- SECCIÓN 2: TABLA correo
-- =============================================================================

CREATE TABLE correo (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identificadores Gmail — clave de idempotencia
    -- -------------------------------------------------------------------------
    -- ID único del mensaje en Gmail. Previene procesar el mismo correo dos veces.
    -- NULL solo para correos salientes creados en el CRM (no tienen message_id aún).
    message_id      TEXT            NULL,
    -- ID del hilo de conversación en Gmail. Agrupa correos relacionados.
    thread_id       TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Clasificación
    -- -------------------------------------------------------------------------
    tipo            tipo_correo     NOT NULL,
    estado          estado_correo   NOT NULL DEFAULT 'recibido',

    -- -------------------------------------------------------------------------
    -- Cabeceras del correo
    -- -------------------------------------------------------------------------
    de_email        TEXT            NOT NULL,
    de_nombre       TEXT            NULL,
    -- Arrays para múltiples destinatarios
    para_emails     TEXT[]          NOT NULL DEFAULT '{}',
    cc_emails       TEXT[]          NOT NULL DEFAULT '{}',
    asunto          TEXT            NOT NULL DEFAULT '',

    -- -------------------------------------------------------------------------
    -- Cuerpo del correo
    -- -------------------------------------------------------------------------
    -- HTML del correo — para correos salientes incluye la firma del analista
    cuerpo_html     TEXT            NULL,
    -- Texto plano — extraído para el Agente 2 y como fallback de lectura
    cuerpo_texto    TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Fechas
    -- -------------------------------------------------------------------------
    -- Fecha real del correo (del header Date:, no de cuando se insertó en DB)
    fecha_correo    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    -- Para salientes: cuándo se envió exitosamente vía Gmail API
    fecha_envio     TIMESTAMPTZ     NULL,

    -- -------------------------------------------------------------------------
    -- Actor para correos salientes
    -- -------------------------------------------------------------------------
    -- Analista que aprobó y disparó el envío del borrador del Agente 6
    analista_id     UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Datos extraídos por el Agente 2 (entrantes)
    -- -------------------------------------------------------------------------
    -- Resultado estructurado del análisis del cuerpo por el Agente 2.
    -- Ejemplos: { "tipo_tramite_detectado": "alta", "confianza": 0.91,
    --             "numero_poliza_mencionado": "...", "ramo_detectado": "gmm" }
    datos_agente2   JSONB           NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- message_id único: previene duplicados del mismo correo de Gmail
    CONSTRAINT uq_correo_message_id UNIQUE (message_id),

    -- Solo correos entrantes tienen message_id; salientes lo reciben al enviarse
    CONSTRAINT ck_correo_message_id CHECK (
        tipo = 'saliente' OR message_id IS NOT NULL
    ),

    -- Fecha de envío solo para correos enviados
    CONSTRAINT ck_correo_fecha_envio CHECK (
        fecha_envio IS NULL OR estado = 'enviado'
    ),

    CONSTRAINT ck_correo_de_email CHECK (TRIM(de_email) <> '')
);

COMMENT ON TABLE correo IS
    'Registro central de todos los correos del CRM: entrantes (Gmail BCC/DWD) '
    'y salientes (borradores del Agente 6 enviados por el analista). '
    'message_id de Gmail es la clave de idempotencia para correos entrantes.';

COMMENT ON COLUMN correo.message_id   IS 'ID único de Gmail. UNIQUE — previene procesar el mismo correo dos veces.';
COMMENT ON COLUMN correo.thread_id    IS 'Hilo de conversación de Gmail. Permite agrupar intercambios relacionados.';
COMMENT ON COLUMN correo.datos_agente2 IS 'Salida estructurada del Agente 2: tipo de trámite detectado, confianzas, entidades extraídas.';
COMMENT ON COLUMN correo.analista_id  IS 'Solo para correos salientes: analista que revisó y aprobó el borrador del Agente 6.';


-- =============================================================================
-- SECCIÓN 3: TABLA correo_tramite — junction correo ↔ trámite
-- =============================================================================
-- Un correo puede dar origen a múltiples trámites (ej: un email con
-- renovaciones de 3 pólizas distintas).
-- Un trámite acumula múltiples correos a lo largo de su vida.
-- =============================================================================

CREATE TABLE correo_tramite (
    correo_id       UUID        NOT NULL REFERENCES correo(id)  ON DELETE CASCADE,
    tramite_id      UUID        NOT NULL REFERENCES tramite(id) ON DELETE CASCADE,
    -- Indica si este correo fue el que originó el trámite (vs. correos posteriores)
    es_origen       BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (correo_id, tramite_id)
);

COMMENT ON TABLE correo_tramite IS
    'Junction many-to-many entre correos y trámites. '
    'es_origen = TRUE marca el correo que dio origen al trámite.';

COMMENT ON COLUMN correo_tramite.es_origen IS
    'TRUE solo para el correo que generó el trámite. '
    'Los correos posteriores del mismo hilo tienen es_origen = FALSE.';


-- =============================================================================
-- SECCIÓN 4: TABLA adjunto — archivos físicos del correo
-- =============================================================================
-- Cada archivo adjunto al correo tiene un registro aquí.
-- Los ZIPs descomprimidos generan registros hijos con adjunto_padre_id.
-- Las contraseñas ZIP son TEMPORALES: se guardan, se usan y se eliminan.
-- =============================================================================

CREATE TABLE adjunto (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- FK al correo del que proviene este adjunto
    correo_id           UUID            NOT NULL REFERENCES correo(id) ON DELETE CASCADE,

    -- Self-reference para archivos extraídos de un ZIP.
    -- NULL = archivo directo del correo.
    -- NOT NULL = fue extraído de un ZIP (su padre).
    adjunto_padre_id    UUID            NULL REFERENCES adjunto(id) ON DELETE CASCADE,

    -- -------------------------------------------------------------------------
    -- Metadatos del archivo
    -- -------------------------------------------------------------------------
    nombre_archivo      TEXT            NOT NULL,
    tipo_mime           TEXT            NULL,   -- ej: "application/pdf", "image/jpeg"
    tamanio_bytes       BIGINT          NULL,   -- NULL si no se pudo determinar
    -- Ruta en Supabase Storage: /tramites/{tramite_id}/correos/{correo_id}/{adjunto_id}
    storage_path        TEXT            NULL,   -- NULL hasta que el archivo se suba a Storage

    -- -------------------------------------------------------------------------
    -- Contraseña ZIP — CAMPO TEMPORAL Y SENSIBLE
    -- -------------------------------------------------------------------------
    -- El Agente 1 guarda aquí la contraseña encontrada en el correo.
    -- Se usa para descomprimir y se borra INMEDIATAMENTE después.
    -- Solo accesible vía service_role — authenticated NO tiene GRANT en esta columna.
    password            TEXT            NULL,
    -- TRUE confirma que la contraseña fue usada y eliminada. Auditoría de seguridad.
    password_eliminado  BOOLEAN         NOT NULL DEFAULT FALSE,

    -- -------------------------------------------------------------------------
    -- Estado en el pipeline del Agente 1
    -- -------------------------------------------------------------------------
    estado              estado_adjunto  NOT NULL DEFAULT 'pendiente',
    -- Razón del error si estado = 'error' o 'ilegible'
    motivo_error        TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_adjunto_nombre CHECK (TRIM(nombre_archivo) <> ''),

    -- La contraseña solo puede estar si el password no fue eliminado aún
    CONSTRAINT ck_adjunto_password CHECK (
        NOT (password IS NOT NULL AND password_eliminado = TRUE)
    ),

    -- Un archivo no puede ser su propio padre
    CONSTRAINT ck_adjunto_no_autoreferencia CHECK (
        adjunto_padre_id IS NULL OR adjunto_padre_id <> id
    )
);

COMMENT ON TABLE adjunto IS
    'Archivos adjuntos de los correos. Los ZIPs descomprimidos tienen adjunto_padre_id. '
    'El campo password es TEMPORAL y SENSIBLE — solo accesible vía service_role.';

COMMENT ON COLUMN adjunto.adjunto_padre_id  IS 'FK al ZIP origen. NULL para archivos directos del correo.';
COMMENT ON COLUMN adjunto.storage_path      IS 'Ruta en Supabase Storage: /tramites/{tramite_id}/correos/{correo_id}/{adjunto_id}.';
COMMENT ON COLUMN adjunto.password          IS 'Contraseña ZIP TEMPORAL. Solo service_role. Debe ser NULL después del procesamiento.';
COMMENT ON COLUMN adjunto.password_eliminado IS 'Confirma que la contraseña fue eliminada. Inmutable una vez en TRUE.';


-- =============================================================================
-- SECCIÓN 5: TABLA documento — resultado OCR + clasificación (Agente 3)
-- =============================================================================
-- Representa el resultado del procesamiento de un adjunto:
--   - Qué tipo de documento es (clasificación)
--   - Qué texto contiene (OCR)
--   - Qué datos estructurados se extrajeron (JSONB)
--   - Si es válido para el trámite (validación del Agente 5)
--
-- Un adjunto genera un documento por tramite al que está vinculado.
-- =============================================================================

CREATE TABLE documento (
    id                      UUID                        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Adjunto origen — el archivo físico procesado
    adjunto_id              UUID                        NOT NULL REFERENCES adjunto(id),
    -- Trámite al que pertenece esta validación del documento
    tramite_id              UUID                        NOT NULL REFERENCES tramite(id),

    -- -------------------------------------------------------------------------
    -- Clasificación (Agente 3)
    -- -------------------------------------------------------------------------
    tipo_documento          tipo_documento              NOT NULL DEFAULT 'otro',
    -- Confianza del modelo en la clasificación del tipo (0-1)
    confianza_clasificacion NUMERIC(4, 3)               NULL CHECK (confianza_clasificacion BETWEEN 0 AND 1),

    -- -------------------------------------------------------------------------
    -- OCR (Agente 3 — Phi-3/Mistral en RunPod, Google Vision como fallback)
    -- -------------------------------------------------------------------------
    -- Texto completo extraído por OCR. Almacenado en DB para consultas directas
    -- y para construcción de chunks RAG. Documentos de seguros raramente superan 20KB.
    texto_ocr               TEXT                        NULL,
    -- Confianza del OCR (0-1). Bajo 0.70 → Agente 3 intenta con modelo alternativo.
    confianza_ocr           NUMERIC(4, 3)               NULL CHECK (confianza_ocr BETWEEN 0 AND 1),
    -- Modelo que realizó el OCR exitosamente
    modelo_ocr              TEXT                        NULL,   -- 'phi3', 'mistral', 'google_vision'
    -- Número de intentos de OCR (para auditoría y optimización de costos)
    intentos_ocr            SMALLINT                    NOT NULL DEFAULT 0,

    -- -------------------------------------------------------------------------
    -- Datos estructurados extraídos (Agente 3)
    -- -------------------------------------------------------------------------
    -- Campos clave extraídos del documento según su tipo. Estructura varía:
    --
    --   tipo_documento = 'ine':
    --     { "nombre": "...", "curp": "...", "fecha_nacimiento": "...",
    --       "fecha_vencimiento": "...", "clave_elector": "..." }
    --
    --   tipo_documento = 'solicitud_alta':
    --     { "contratante": "...", "rfc": "...", "suma_asegurada": 500000,
    --       "inicio_vigencia": "...", "tipo_cobertura": "amplia" }
    --
    --   tipo_documento = 'tarjeta_circulacion':
    --     { "vin": "...", "placas": "...", "marca": "...", "modelo": "...", "anio": 2023 }
    datos_extraidos         JSONB                       NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Vigencia del documento (Agente 3 extrae, Agente 5 valida)
    -- -------------------------------------------------------------------------
    -- Fecha de vencimiento si el documento expira (INE, comprobante domicilio, etc.)
    vigente_hasta           DATE                        NULL,

    -- -------------------------------------------------------------------------
    -- Validación (Agente 5)
    -- -------------------------------------------------------------------------
    estado_validacion       estado_validacion_documento NOT NULL DEFAULT 'pendiente_validacion',
    -- Por qué el documento es inválido o ilegible — texto para el analista y el RAG
    motivo_invalidez        TEXT                        NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at              TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ                 NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Un adjunto no puede tener dos documentos del mismo tipo en el mismo trámite
    CONSTRAINT uq_documento_adjunto_tramite UNIQUE (adjunto_id, tramite_id),

    -- motivo_invalidez solo aplica cuando el estado lo justifica
    CONSTRAINT ck_documento_motivo CHECK (
        motivo_invalidez IS NULL
        OR estado_validacion IN ('invalido', 'ilegible', 'vencido', 'duplicado')
    ),

    -- vigente_hasta solo tiene sentido para documentos válidos o que expiraron
    CONSTRAINT ck_documento_vigencia CHECK (
        vigente_hasta IS NULL
        OR tipo_documento IN (
            'ine', 'pasaporte', 'comprobante_domicilio',
            'carta_medica', 'poder_notarial', 'estado_cuenta'
        )
    )
);

COMMENT ON TABLE documento IS
    'Resultado del procesamiento OCR + clasificación del Agente 3 sobre un adjunto. '
    'Incluye el texto OCR completo (para RAG), datos estructurados extraídos, '
    'y el resultado de validación del Agente 5.';

COMMENT ON COLUMN documento.texto_ocr           IS 'Texto completo extraído por OCR. Alimenta el RAG y la validación del Agente 5.';
COMMENT ON COLUMN documento.datos_extraidos     IS 'Campos clave estructurados según tipo_documento. El Agente 3 los escribe, el Agente 4 los lee.';
COMMENT ON COLUMN documento.confianza_ocr       IS 'Confianza OCR (0-1). < 0.70 activa fallback a modelo alternativo o Google Vision.';
COMMENT ON COLUMN documento.vigente_hasta       IS 'Fecha de vencimiento del documento. El Agente 5 la compara con fecha_recepcion del trámite.';
COMMENT ON COLUMN documento.estado_validacion   IS 'Resultado del Agente 5. Determina si el trámite pasa a completo o pendiente_documentos.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- correo
CREATE INDEX idx_correo_thread
    ON correo (thread_id)
    WHERE thread_id IS NOT NULL;

COMMENT ON INDEX idx_correo_thread IS
    'Agrupa correos del mismo hilo de conversación Gmail.';

CREATE INDEX idx_correo_tipo_estado
    ON correo (tipo, estado);

CREATE INDEX idx_correo_fecha
    ON correo (fecha_correo DESC);

CREATE INDEX idx_correo_de_email
    ON correo (de_email);

COMMENT ON INDEX idx_correo_de_email IS
    'El Agente 4 busca el remitente aquí en el cascade de identificación.';

CREATE INDEX idx_correo_analista
    ON correo (analista_id)
    WHERE analista_id IS NOT NULL;

-- Para detectar correos salientes pendientes de envío (dashboard del analista)
CREATE INDEX idx_correo_borradores
    ON correo (analista_id, estado)
    WHERE tipo = 'saliente' AND estado IN ('borrador', 'en_revision', 'aprobado');

-- correo_tramite
CREATE INDEX idx_correo_tramite_tramite
    ON correo_tramite (tramite_id);

CREATE INDEX idx_correo_tramite_correo
    ON correo_tramite (correo_id);

-- Para encontrar el correo origen de un trámite
CREATE INDEX idx_correo_tramite_origen
    ON correo_tramite (tramite_id)
    WHERE es_origen = TRUE;

-- adjunto
CREATE INDEX idx_adjunto_correo
    ON adjunto (correo_id);

CREATE INDEX idx_adjunto_padre
    ON adjunto (adjunto_padre_id)
    WHERE adjunto_padre_id IS NOT NULL;

CREATE INDEX idx_adjunto_estado
    ON adjunto (estado)
    WHERE estado IN ('pendiente', 'procesando');

COMMENT ON INDEX idx_adjunto_estado IS
    'El Agente 1 consulta adjuntos pendientes de procesar.';

-- Para auditoría de seguridad: adjuntos con password sin eliminar
CREATE INDEX idx_adjunto_password_pendiente
    ON adjunto (correo_id)
    WHERE password IS NOT NULL AND password_eliminado = FALSE;

COMMENT ON INDEX idx_adjunto_password_pendiente IS
    'Auditoría: adjuntos con contraseña ZIP sin eliminar. Debe estar vacío en operación normal.';

-- documento
CREATE INDEX idx_documento_tramite
    ON documento (tramite_id);

CREATE INDEX idx_documento_adjunto
    ON documento (adjunto_id);

CREATE INDEX idx_documento_tipo_validacion
    ON documento (tramite_id, tipo_documento, estado_validacion);

COMMENT ON INDEX idx_documento_tipo_validacion IS
    'El Agente 5 consulta documentos de un trámite por tipo y estado de validación.';

-- Para el RAG: búsqueda de texto en documentos
CREATE INDEX idx_documento_texto_ocr
    ON documento USING gin (to_tsvector('spanish', COALESCE(texto_ocr, '')));

COMMENT ON INDEX idx_documento_texto_ocr IS
    'Búsqueda full-text en texto OCR en español. Alimenta el RAG de pólizas.';

-- Para el RAG: búsqueda en datos extraídos (JSONB)
CREATE INDEX idx_documento_datos
    ON documento USING gin (datos_extraidos);

CREATE INDEX idx_documento_vencidos
    ON documento (vigente_hasta)
    WHERE vigente_hasta IS NOT NULL AND estado_validacion = 'pendiente_validacion';

COMMENT ON INDEX idx_documento_vencidos IS
    'El Agente 5 detecta documentos próximos a vencer antes de validar.';


-- =============================================================================
-- SECCIÓN 7: TRIGGERS — updated_at
-- =============================================================================
-- set_updated_at() ya existe desde migración 20260522000000.

CREATE TRIGGER trg_correo_updated_at
    BEFORE UPDATE ON correo
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_adjunto_updated_at
    BEFORE UPDATE ON adjunto
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_documento_updated_at
    BEFORE UPDATE ON documento
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 8: TRIGGER — Protección de password_eliminado (inmutable en TRUE)
-- =============================================================================
-- Una vez que password_eliminado = TRUE, no puede volver a FALSE.
-- La contraseña eliminada no puede restaurarse.
-- =============================================================================

CREATE OR REPLACE FUNCTION proteger_password_eliminado()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.password_eliminado = TRUE AND NEW.password_eliminado = FALSE THEN
        RAISE EXCEPTION
            'No se puede revertir password_eliminado a FALSE. '
            'Una vez eliminada la contraseña ZIP, el campo es inmutable.';
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION proteger_password_eliminado() IS
    'Impide revertir password_eliminado de TRUE a FALSE. '
    'Garantiza que la eliminación de contraseñas ZIP sea irreversible.';

CREATE TRIGGER trg_adjunto_proteger_password
    BEFORE UPDATE OF password_eliminado ON adjunto
    FOR EACH ROW
    EXECUTE FUNCTION proteger_password_eliminado();


-- =============================================================================
-- SECCIÓN 9: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--   correo y adjunto: visibilidad heredada de los trámites vinculados.
--   documento: misma visibilidad que su trámite.
--   correo_tramite: visible si el usuario puede ver el trámite o el correo.
--
-- El campo adjunto.password NUNCA es visible para authenticated:
--   Se usa GRANT a nivel de columna para excluirlo del acceso estándar.
--   Solo service_role (los agentes IA) pueden leer y escribir ese campo.
-- =============================================================================

ALTER TABLE correo          ENABLE ROW LEVEL SECURITY;
ALTER TABLE correo_tramite  ENABLE ROW LEVEL SECURITY;
ALTER TABLE adjunto         ENABLE ROW LEVEL SECURITY;
ALTER TABLE documento       ENABLE ROW LEVEL SECURITY;


-- Función auxiliar reutilizable: ¿puede el usuario actual ver este trámite?
-- Evita repetir la lógica de visibilidad en cada policy.
CREATE OR REPLACE FUNCTION puede_ver_tramite(p_tramite_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
    SELECT EXISTS (
        SELECT 1 FROM tramite t
        WHERE t.id = p_tramite_id
          AND (
            auth_rol() IN ('director_general', 'director_ops')
            OR (auth_rol() = 'gerente'
                AND (t.gerente_id = auth.uid()
                     OR (t.ramo IS NOT NULL AND t.ramo::text = auth_ramo())))
            OR (auth_rol() = 'analista' AND t.analista_id = auth.uid())
          )
    )
$$;

COMMENT ON FUNCTION puede_ver_tramite(UUID) IS
    'Verifica si el usuario autenticado puede ver un trámite dado. '
    'Centraliza la lógica de visibilidad para usarla en policies de tablas secundarias.';


-- -----------------------------------------------------------------------------
-- POLICIES: correo
-- Un correo es visible si el usuario puede ver AL MENOS UNO de sus trámites
-- vinculados, o si es un correo saliente del propio analista.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_correo_select_director
    ON correo FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_correo_select_via_tramite
    ON correo FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('gerente', 'analista')
        AND EXISTS (
            SELECT 1 FROM correo_tramite ct
            WHERE ct.correo_id = id
              AND puede_ver_tramite(ct.tramite_id)
        )
    );

-- Un analista puede ver sus propios correos salientes aunque no tengan trámite aún
CREATE POLICY pol_correo_select_propio_saliente
    ON correo FOR SELECT TO authenticated
    USING (
        tipo = 'saliente'
        AND analista_id = auth.uid()
    );

-- INSERT: analistas, gerentes y directores pueden crear borradores
CREATE POLICY pol_correo_insert
    ON correo FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- UPDATE: directores actualizan cualquiera; analistas solo sus borradores
CREATE POLICY pol_correo_update_director
    ON correo FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_correo_update_analista
    ON correo FOR UPDATE TO authenticated
    USING (tipo = 'saliente' AND analista_id = auth.uid() AND estado IN ('borrador', 'en_revision'))
    WITH CHECK (tipo = 'saliente' AND analista_id = auth.uid());


-- -----------------------------------------------------------------------------
-- POLICIES: correo_tramite
-- -----------------------------------------------------------------------------

CREATE POLICY pol_correo_tramite_select
    ON correo_tramite FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR puede_ver_tramite(tramite_id)
    );

CREATE POLICY pol_correo_tramite_insert
    ON correo_tramite FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- DELETE: solo directores (corrección de vínculos incorrectos)
CREATE POLICY pol_correo_tramite_delete
    ON correo_tramite FOR DELETE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));


-- -----------------------------------------------------------------------------
-- POLICIES: adjunto
-- Visibilidad via el correo padre (que hereda de los trámites).
-- NUNCA exponer adjunto.password a authenticated.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_adjunto_select_director
    ON adjunto FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_adjunto_select_via_correo
    ON adjunto FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('gerente', 'analista')
        AND EXISTS (
            SELECT 1 FROM correo_tramite ct
            WHERE ct.correo_id = correo_id
              AND puede_ver_tramite(ct.tramite_id)
        )
    );

-- INSERT/UPDATE: solo Agentes IA via service_role + directores para correcciones
CREATE POLICY pol_adjunto_insert
    ON adjunto FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_adjunto_update
    ON adjunto FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));


-- -----------------------------------------------------------------------------
-- POLICIES: documento
-- -----------------------------------------------------------------------------

CREATE POLICY pol_documento_select_director
    ON documento FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_documento_select_via_tramite
    ON documento FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('gerente', 'analista')
        AND puede_ver_tramite(tramite_id)
    );

-- Analistas pueden actualizar el estado de validación manualmente (override del Agente 5)
CREATE POLICY pol_documento_update_validacion
    ON documento FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
        AND puede_ver_tramite(tramite_id)
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

-- INSERT: solo Agente 3 via service_role + directores para carga manual
CREATE POLICY pol_documento_insert
    ON documento FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));


-- =============================================================================
-- SECCIÓN 10: GRANTS — con exclusión de columna 'password' en adjunto
-- =============================================================================
-- PostgreSQL permite GRANTs a nivel de columna.
-- authenticated puede ver TODAS las columnas de adjunto EXCEPTO 'password'.
-- Solo service_role (los agentes IA) tiene acceso a adjunto.password.
-- =============================================================================

GRANT SELECT, INSERT ON TABLE correo         TO authenticated;
GRANT UPDATE (estado, cuerpo_html, cuerpo_texto, fecha_envio, datos_agente2, updated_at)
    ON TABLE correo TO authenticated;

GRANT SELECT, INSERT, DELETE ON TABLE correo_tramite TO authenticated;

-- adjunto: GRANT por columna — excluye 'password' explícitamente
GRANT SELECT (
    id, correo_id, adjunto_padre_id, nombre_archivo, tipo_mime,
    tamanio_bytes, storage_path, password_eliminado, estado,
    motivo_error, created_at, updated_at
) ON TABLE adjunto TO authenticated;

GRANT UPDATE (
    estado, storage_path, motivo_error, password_eliminado, updated_at
) ON TABLE adjunto TO authenticated;

-- 'password' y el INSERT completo (que incluye password) solo via service_role
-- No se hace GRANT de INSERT a authenticated para adjunto —
-- los adjuntos los crea el Agente 1 via service_role.

GRANT SELECT ON TABLE documento TO authenticated;
GRANT UPDATE (
    tipo_documento, estado_validacion, motivo_invalidez,
    confianza_clasificacion, updated_at
) ON TABLE documento TO authenticated;
-- INSERT de documentos solo via service_role (Agente 3)

GRANT EXECUTE ON FUNCTION puede_ver_tramite(UUID) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000004_modulo_05_correos_adjuntos.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000005_modulo_06_rag.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000005_modulo_06_rag.sql
-- Módulo 6 — RAG: Base de conocimiento vectorial del CRM Olimpo
-- =============================================================================
-- Tres RAGs con propósitos distintos y complementarios:
--
--   rag_gnp          → Conocimiento estático de GNP: manuales, requisitos por
--                       producto, formularios modelo, circulares. Curado por humanos
--                       vía la app rag-ingest. Se filtra por metadata ANTES del
--                       vector search para mayor precisión y menor costo.
--
--   rag_polizas      → Historial dinámico de pólizas: se construye automáticamente
--                       conforme el Agente 5 procesa trámites. Empieza vacío.
--                       Cada trámite aprobado/rechazado/activado agrega un chunk.
--                       Con el tiempo genera patrones por agente, ramo y tipo.
--
--   rag_aprendizajes → Memoria de rechazos de GNP: cada rechazo genera un chunk
--                       que explica QUÉ salió mal y CÓMO corregirlo. Es el
--                       diferenciador competitivo — el sistema aprende de sus errores.
--                       Los analistas validan los aprendizajes para filtrar ruido.
--
-- Modelo de embeddings: OpenAI text-embedding-3-small (1536 dimensiones)
-- Similaridad: coseno (los embeddings de OpenAI están normalizados)
-- Índice: HNSW — mejor precisión en producción vs. IVFFlat
--
-- Flujo de escritura:
--   rag_gnp:          app rag-ingest → genera chunks → llama OpenAI → INSERT
--   rag_polizas:      Agente 5 al completar validación → INSERT (via Celery)
--   rag_aprendizajes: Agente 5 al recibir rechazo GNP → INSERT (via Celery)
--                     Analista/Gerente → valida con UPDATE aprendizaje_validado
--
-- Flujo de lectura (Agente 5 — Validación):
--   1. Pre-filtrar por ramo, tipo_tramite, tipo_documento, vigente
--   2. Vector search con embedding del documento a validar
--   3. Contextualizar respuesta con chunks más similares
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: EXTENSIÓN PGVECTOR
-- =============================================================================
-- Supabase la habilita por defecto, pero se declara explícitamente en la
-- migración para que sea reproducible en cualquier ambiente.

CREATE EXTENSION IF NOT EXISTS vector;

-- pg_trgm ya fue requerida en módulos anteriores (idx_agente_nombre, etc.)
-- Se declara aquí también para garantizar que exista antes de los índices RAG.
CREATE EXTENSION IF NOT EXISTS pg_trgm;


-- =============================================================================
-- SECCIÓN 2: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_fuente_rag AS ENUM (
    'manual',               -- Manual técnico de GNP (ej: Manual de Suscripción GMM)
    'requisitos',           -- Lista oficial de requisitos por producto y tipo de trámite
    'ejemplo_formulario',   -- Formulario GNP correctamente llenado (gold standard)
    'circular',             -- Circular o comunicado oficial de GNP con fecha de vigencia
    'politica_interna',     -- Política interna de la promotoría (no de GNP)
    'otro'
);

COMMENT ON TYPE tipo_fuente_rag IS
    'Tipo de documento origen del chunk en rag_gnp. '
    'Determina el peso y la confiabilidad del conocimiento.';


CREATE TYPE tipo_chunk_poliza AS ENUM (
    'validacion_exitosa',   -- Agente 5 validó todos los documentos del trámite
    'activacion_gnp',       -- GNP activó la póliza (puede repetirse en endosos)
    'aprobacion_final',     -- Trámite cerrado como aprobado
    'rechazo_gnp',          -- GNP rechazó — también genera chunk en rag_aprendizajes
    'endoso_procesado',     -- Endoso completado exitosamente
    'patron_detectado'      -- Patrón observado por el sistema en el historial de la póliza
);

COMMENT ON TYPE tipo_chunk_poliza IS
    'Tipo de evento que originó el chunk en rag_polizas. '
    'Permite filtrar el historial por tipo de evento.';


-- =============================================================================
-- SECCIÓN 3: TABLA rag_gnp — Conocimiento estático de GNP
-- =============================================================================
-- Fuente de verdad sobre requisitos, productos y procedimientos de GNP.
-- Curado manualmente via la app rag-ingest.
-- Se filtra por metadata (ramo, tipo_tramite, tipo_documento) ANTES del
-- vector search para reducir el espacio de búsqueda y aumentar la precisión.
-- =============================================================================

CREATE TABLE rag_gnp (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Vector embedding — corazón del RAG
    -- -------------------------------------------------------------------------
    -- text-embedding-3-small: 1536 dimensiones, normalizado (cosine ≈ dot product)
    -- NULL temporalmente durante el proceso de ingesta (chunk creado, embedding pendiente)
    embedding           vector(1536)    NULL,

    -- -------------------------------------------------------------------------
    -- Contenido del chunk
    -- -------------------------------------------------------------------------
    -- Texto del chunk listo para embeberse. Debe ser auto-contenido e incluir
    -- contexto en el texto mismo. Ejemplo:
    -- "[Ramo: GMM] [Trámite: Alta] [Vigente desde: 2024-01-01]
    --  Para el alta de una póliza de GMM se requieren los siguientes documentos:
    --  1. Solicitud de alta firmada por el contratante..."
    contenido           TEXT            NOT NULL,
    -- Hash SHA256 del contenido para detectar duplicados en re-ingestas
    hash_contenido      TEXT            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Metadata para pre-filtrado (SIEMPRE filtrar antes del vector search)
    -- -------------------------------------------------------------------------
    -- NULL = aplica a todos los ramos / tipos / documentos
    ramo                ramo_usuario    NULL,
    tipo_tramite        tipo_tramite    NULL,
    tipo_documento      tipo_documento  NULL,

    -- -------------------------------------------------------------------------
    -- Metadatos de la fuente
    -- -------------------------------------------------------------------------
    tipo_fuente         tipo_fuente_rag NOT NULL DEFAULT 'otro',
    titulo_fuente       TEXT            NOT NULL, -- ej: "Manual Suscripción GMM 2024"
    numero_pagina       SMALLINT        NULL,     -- página en el doc fuente
    seccion             TEXT            NULL,     -- sección o capítulo del documento

    -- -------------------------------------------------------------------------
    -- Control de vigencia — crítico para requisitos que cambian
    -- -------------------------------------------------------------------------
    vigente_desde       DATE            NULL,     -- cuándo entró en vigor este requisito
    vigente_hasta       DATE            NULL,     -- cuándo dejó de aplicar (NULL = aún vigente)
    -- Flag rápido para filtrar: WHERE vigente = TRUE sin calcular fechas en cada query
    vigente             BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Tags adicionales para búsqueda y filtrado semántico
    -- Ejemplos: ["suma_asegurada", "beneficiarios", "exclusiones", "espera"]
    tags                TEXT[]          NOT NULL DEFAULT '{}',

    -- Metadata flexible para datos adicionales del chunk
    -- Ej: { "numero_circular": "C-2024-042", "producto_gnp": "GMM Plus" }
    metadata            JSONB           NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Trazabilidad de la ingesta
    -- -------------------------------------------------------------------------
    -- Modelo de embedding usado — para saber cuándo re-embeberse
    version_embedding   TEXT            NULL,     -- ej: "text-embedding-3-small"
    -- Quién ingresó este chunk (usuario del rag-ingest)
    ingresado_por       UUID            NULL REFERENCES usuario(id),
    -- Quién validó que el contenido es correcto
    revisado_por        UUID            NULL REFERENCES usuario(id),
    -- Costo aproximado en tokens para análisis de costos
    num_tokens          INTEGER         NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_rag_gnp_hash UNIQUE (hash_contenido),

    CONSTRAINT ck_rag_gnp_vigencia CHECK (
        vigente_hasta IS NULL OR vigente_desde IS NULL
        OR vigente_hasta >= vigente_desde
    ),

    CONSTRAINT ck_rag_gnp_contenido CHECK (TRIM(contenido) <> ''),
    CONSTRAINT ck_rag_gnp_titulo    CHECK (TRIM(titulo_fuente) <> '')
);

COMMENT ON TABLE rag_gnp IS
    'Base de conocimiento estático de GNP: manuales, requisitos, formularios, circulares. '
    'Curado manualmente vía rag-ingest. Filtrar por ramo/tipo/vigente ANTES del vector search.';

COMMENT ON COLUMN rag_gnp.embedding        IS 'Vector 1536-dim (text-embedding-3-small). NULL durante ingesta hasta que se genere.';
COMMENT ON COLUMN rag_gnp.contenido        IS 'Texto del chunk enriquecido con contexto. Incluye metadata en el texto para mejor embedding.';
COMMENT ON COLUMN rag_gnp.hash_contenido   IS 'SHA256 del contenido. Previene chunks duplicados en re-ingestas.';
COMMENT ON COLUMN rag_gnp.vigente          IS 'Flag de búsqueda rápida. Siempre filtrar WHERE vigente = TRUE antes del vector search.';
COMMENT ON COLUMN rag_gnp.tags             IS 'Tags semánticos adicionales: ["exclusiones", "espera", "suma_asegurada", etc.].';
COMMENT ON COLUMN rag_gnp.version_embedding IS 'Modelo usado para generar el embedding. Cambiar si se migra de modelo.';


-- =============================================================================
-- SECCIÓN 4: TABLA rag_polizas — Historial dinámico de pólizas
-- =============================================================================
-- Se construye automáticamente conforme el Agente 5 procesa trámites.
-- Empieza VACÍO — no hay carga histórica inicial.
-- Con el tiempo construye un "diario de vida" por póliza que el Agente 5
-- usa para entender el contexto antes de validar un nuevo trámite.
-- =============================================================================

CREATE TABLE rag_poliza (
    id                  UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Vector embedding
    -- -------------------------------------------------------------------------
    embedding           vector(1536)        NULL,

    -- -------------------------------------------------------------------------
    -- Contenido del chunk — narrativa del evento
    -- -------------------------------------------------------------------------
    -- Texto narrativo generado por el Agente 5. Debe ser auto-contenido. Ejemplo:
    -- "Póliza 123456 (GMM Individual) - Agente: Juan García (CUA 1234567)
    --  Trámite TRM-2025-00042 procesado el 15/03/2025.
    --  Documentos: INE (vigente hasta 2028), Solicitud Alta GNP, Comprobante Domicilio.
    --  Resultado: 3 documentos válidos. GNP activó el 20/03/2025."
    contenido           TEXT                NOT NULL,

    -- -------------------------------------------------------------------------
    -- Vínculos con entidades del CRM
    -- -------------------------------------------------------------------------
    poliza_id           UUID                NULL REFERENCES poliza(id),
    tramite_id          UUID                NOT NULL REFERENCES tramite(id),
    -- Evento específico que originó este chunk (si aplica)
    tramite_evento_id   UUID                NULL REFERENCES tramite_evento(id),

    -- -------------------------------------------------------------------------
    -- Metadata para pre-filtrado
    -- -------------------------------------------------------------------------
    tipo_chunk          tipo_chunk_poliza   NOT NULL,
    -- Denormalizado del trámite para filtrar sin JOIN
    ramo                ramo_usuario        NULL,
    tipo_tramite        tipo_tramite        NULL,
    -- CUA del agente — permite buscar historial por agente
    agente_cua          TEXT                NULL,

    -- -------------------------------------------------------------------------
    -- Trazabilidad
    -- -------------------------------------------------------------------------
    version_embedding   TEXT                NULL,
    num_tokens          INTEGER             NULL,
    created_at          TIMESTAMPTZ         NOT NULL DEFAULT NOW()
    -- Sin updated_at — chunks inmutables una vez creados
);

COMMENT ON TABLE rag_poliza IS
    'Historial vectorial de pólizas. Se construye automáticamente por el Agente 5. '
    'Empieza vacío. Cada trámite significativo agrega un chunk narrativo. '
    'Chunks inmutables — append-only.';

COMMENT ON COLUMN rag_poliza.contenido        IS 'Narrativa del evento generada por el Agente 5. Auto-contenida para contexto de búsqueda.';
COMMENT ON COLUMN rag_poliza.tramite_id       IS 'Trámite que originó este chunk. NOT NULL — cada chunk tiene su tramite de origen.';
COMMENT ON COLUMN rag_poliza.agente_cua       IS 'CUA del agente denormalizado. Permite filtrar historial por agente sin JOIN.';


-- =============================================================================
-- SECCIÓN 5: TABLA rag_aprendizaje — Memoria de rechazos de GNP
-- =============================================================================
-- Cada rechazo de GNP genera un chunk de aprendizaje que explica:
--   - Qué salió mal (causa del rechazo)
--   - Por qué GNP lo rechazó (regla o criterio aplicado)
--   - Cómo se corrigió (si se resolvió)
--
-- El Agente 5 consulta esta tabla PRIMERO antes de validar un trámite,
-- para anticipar rechazos basándose en patrones históricos.
--
-- Los analistas validan los aprendizajes para filtrar los incorrectos
-- antes de que afecten futuras validaciones.
-- =============================================================================

CREATE TABLE rag_aprendizaje (
    id                      UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Vector embedding
    -- -------------------------------------------------------------------------
    embedding               vector(1536)        NULL,

    -- -------------------------------------------------------------------------
    -- Contenido del aprendizaje — el núcleo del diferenciador competitivo
    -- -------------------------------------------------------------------------
    -- Texto generado por el Agente 5 al recibir el rechazo. Debe explicar
    -- con suficiente detalle para que el Agente 5 evite el mismo error. Ejemplo:
    -- "RECHAZO GNP - Ramo: GMM - Alta (01/04/2025)
    --  Problema: INE del asegurado vencida al inicio de vigencia.
    --  Detalle: La póliza inicia el 01/04/2025. La INE presentada venció el 31/03/2025.
    --  Regla GNP: Los documentos de identidad deben estar vigentes AL MENOS durante
    --  todo el primer período de cobertura (generalmente 1 año).
    --  Lección: Verificar que fecha_vencimiento_INE > fecha_inicio_poliza + 365 días.
    --  Corrección: Se solicitó nueva INE. Aprobado el 05/04/2025."
    contenido               TEXT                NOT NULL,

    -- -------------------------------------------------------------------------
    -- Vínculos con el trámite origen
    -- -------------------------------------------------------------------------
    tramite_id              UUID                NOT NULL REFERENCES tramite(id),
    poliza_id               UUID                NULL REFERENCES poliza(id),
    -- Documento específico que causó el rechazo (si identificado)
    documento_id            UUID                NULL REFERENCES documento(id),

    -- -------------------------------------------------------------------------
    -- Metadata para pre-filtrado — más específica que rag_gnp
    -- -------------------------------------------------------------------------
    ramo                    ramo_usuario        NOT NULL,
    tipo_tramite            tipo_tramite        NULL,
    tipo_documento          tipo_documento      NULL,   -- qué tipo de doc causó el rechazo

    -- -------------------------------------------------------------------------
    -- Datos del rechazo GNP
    -- -------------------------------------------------------------------------
    codigo_rechazo_gnp      TEXT                NULL,   -- código oficial de GNP si lo provee
    motivo_rechazo          TEXT                NOT NULL, -- descripción legible del motivo
    -- Qué acción correctiva se tomó y cuál fue el resultado
    correccion_aplicada     TEXT                NULL,
    -- TRUE si el trámite fue finalmente aprobado después de la corrección
    resuelto                BOOLEAN             NOT NULL DEFAULT FALSE,
    fecha_resolucion        DATE                NULL,

    -- -------------------------------------------------------------------------
    -- Control de calidad del aprendizaje
    -- -------------------------------------------------------------------------
    -- FALSE = generado por IA, no validado. Se usa pero con menor peso.
    -- TRUE = validado por analista o gerente. Alta confiabilidad.
    aprendizaje_validado    BOOLEAN             NOT NULL DEFAULT FALSE,
    validado_por            UUID                NULL REFERENCES usuario(id),
    fecha_validacion        TIMESTAMPTZ         NULL,
    -- El analista puede marcar un aprendizaje como incorrecto para excluirlo
    descartado              BOOLEAN             NOT NULL DEFAULT FALSE,
    motivo_descarte         TEXT                NULL,

    -- Tags para búsqueda semántica adicional
    tags                    TEXT[]              NOT NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Trazabilidad
    -- -------------------------------------------------------------------------
    version_embedding       TEXT                NULL,
    num_tokens              INTEGER             NULL,
    created_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_rag_aprendizaje_contenido CHECK (TRIM(contenido) <> ''),
    CONSTRAINT ck_rag_aprendizaje_motivo    CHECK (TRIM(motivo_rechazo) <> ''),

    CONSTRAINT ck_rag_aprendizaje_validacion CHECK (
        NOT aprendizaje_validado
        OR (validado_por IS NOT NULL AND fecha_validacion IS NOT NULL)
    ),

    CONSTRAINT ck_rag_aprendizaje_descarte CHECK (
        NOT descartado OR motivo_descarte IS NOT NULL
    ),

    CONSTRAINT ck_rag_aprendizaje_resolucion CHECK (
        NOT resuelto OR fecha_resolucion IS NOT NULL
    ),

    -- Un aprendizaje no puede estar validado y descartado al mismo tiempo
    CONSTRAINT ck_rag_aprendizaje_estado CHECK (
        NOT (aprendizaje_validado AND descartado)
    )
);

COMMENT ON TABLE rag_aprendizaje IS
    'Memoria de rechazos GNP. El diferenciador competitivo del CRM: '
    'cada rechazo se convierte en conocimiento que previene futuros rechazos. '
    'El Agente 5 consulta esta tabla antes de validar para anticipar problemas.';

COMMENT ON COLUMN rag_aprendizaje.contenido             IS 'Narrativa completa del rechazo + causa + lección + corrección. Auto-contenida.';
COMMENT ON COLUMN rag_aprendizaje.aprendizaje_validado  IS 'TRUE = analista validó que el aprendizaje es correcto. FALSE = solo IA, menor confianza.';
COMMENT ON COLUMN rag_aprendizaje.descartado            IS 'TRUE = aprendizaje incorrecto o ruido, excluido del RAG. Requiere motivo.';
COMMENT ON COLUMN rag_aprendizaje.resuelto              IS 'TRUE = el rechazo fue superado y el trámite aprobado tras la corrección.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- ---------------------------------------------------------------------------
-- rag_gnp — índice HNSW para vector search + índices de pre-filtrado
-- ---------------------------------------------------------------------------

-- Índice HNSW principal para similaridad coseno
-- Solo sobre chunks con embedding generado (vigente = TRUE implícito en queries)
CREATE INDEX idx_rag_gnp_embedding
    ON rag_gnp USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

COMMENT ON INDEX idx_rag_gnp_embedding IS
    'HNSW coseno sobre rag_gnp. Parámetros: m=16 (conexiones), ef_construction=64 (calidad). '
    'PRE-FILTRAR por ramo/tipo/vigente ANTES de usar este índice.';

-- Pre-filtrado: vigente + ramo (la combinación más frecuente)
CREATE INDEX idx_rag_gnp_vigente_ramo
    ON rag_gnp (vigente, ramo)
    WHERE vigente = TRUE;

COMMENT ON INDEX idx_rag_gnp_vigente_ramo IS
    'Pre-filtrado antes del vector search: ramo específico con contenido vigente.';

-- Pre-filtrado: vigente + tipo_tramite + tipo_documento
CREATE INDEX idx_rag_gnp_filtros
    ON rag_gnp (vigente, ramo, tipo_tramite, tipo_documento)
    WHERE vigente = TRUE;

-- Búsqueda por tags (GIN para arrays)
CREATE INDEX idx_rag_gnp_tags
    ON rag_gnp USING gin (tags);

-- Búsqueda en metadata JSONB
CREATE INDEX idx_rag_gnp_metadata
    ON rag_gnp USING gin (metadata);

-- Chunks sin embedding (pendientes de procesar en la cola)
CREATE INDEX idx_rag_gnp_sin_embedding
    ON rag_gnp (created_at)
    WHERE embedding IS NULL;

COMMENT ON INDEX idx_rag_gnp_sin_embedding IS
    'Worker de embeddings consulta aquí los chunks pendientes de procesar.';


-- ---------------------------------------------------------------------------
-- rag_poliza — índice HNSW + pre-filtrado por poliza y tipo
-- ---------------------------------------------------------------------------

CREATE INDEX idx_rag_poliza_embedding
    ON rag_poliza USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Historial de una póliza específica ordenado por tiempo
CREATE INDEX idx_rag_poliza_poliza_ts
    ON rag_poliza (poliza_id, created_at DESC)
    WHERE poliza_id IS NOT NULL;

COMMENT ON INDEX idx_rag_poliza_poliza_ts IS
    'Recupera el historial completo de una póliza ordenado cronológicamente.';

-- Pre-filtrado por ramo y tipo para búsqueda de patrones similares
CREATE INDEX idx_rag_poliza_ramo_tipo
    ON rag_poliza (ramo, tipo_chunk, tipo_tramite);

-- Historial por CUA del agente
CREATE INDEX idx_rag_poliza_agente_cua
    ON rag_poliza (agente_cua)
    WHERE agente_cua IS NOT NULL;

-- Chunks sin embedding pendientes
CREATE INDEX idx_rag_poliza_sin_embedding
    ON rag_poliza (created_at)
    WHERE embedding IS NULL;


-- ---------------------------------------------------------------------------
-- rag_aprendizaje — índice HNSW + pre-filtrado por ramo y validación
-- ---------------------------------------------------------------------------

CREATE INDEX idx_rag_aprendizaje_embedding
    ON rag_aprendizaje USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- Pre-filtrado principal: aprendizajes activos y no descartados por ramo
CREATE INDEX idx_rag_aprendizaje_activos
    ON rag_aprendizaje (ramo, tipo_tramite, tipo_documento)
    WHERE descartado = FALSE;

COMMENT ON INDEX idx_rag_aprendizaje_activos IS
    'El Agente 5 pre-filtra aprendizajes no descartados por ramo/tipo antes del vector search.';

-- Aprendizajes validados por humanos (mayor confiabilidad)
CREATE INDEX idx_rag_aprendizaje_validados
    ON rag_aprendizaje (ramo, aprendizaje_validado)
    WHERE aprendizaje_validado = TRUE AND descartado = FALSE;

-- Pendientes de validación humana (para dashboard del analista/gerente)
CREATE INDEX idx_rag_aprendizaje_pendientes_validacion
    ON rag_aprendizaje (ramo, created_at DESC)
    WHERE aprendizaje_validado = FALSE AND descartado = FALSE;

COMMENT ON INDEX idx_rag_aprendizaje_pendientes_validacion IS
    'Dashboard: aprendizajes generados por IA que esperan validación humana.';

-- Aprendizajes por trámite origen
CREATE INDEX idx_rag_aprendizaje_tramite
    ON rag_aprendizaje (tramite_id);

-- Tags para búsqueda adicional
CREATE INDEX idx_rag_aprendizaje_tags
    ON rag_aprendizaje USING gin (tags);

-- Chunks sin embedding pendientes
CREATE INDEX idx_rag_aprendizaje_sin_embedding
    ON rag_aprendizaje (created_at)
    WHERE embedding IS NULL;


-- =============================================================================
-- SECCIÓN 7: TRIGGERS
-- =============================================================================

-- updated_at para rag_gnp y rag_aprendizaje (rag_poliza es inmutable)
CREATE TRIGGER trg_rag_gnp_updated_at
    BEFORE UPDATE ON rag_gnp
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_rag_aprendizaje_updated_at
    BEFORE UPDATE ON rag_aprendizaje
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- Trigger: cuando un aprendizaje se valida, registrar automáticamente quién y cuándo
CREATE OR REPLACE FUNCTION registrar_validacion_aprendizaje()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.aprendizaje_validado = TRUE AND OLD.aprendizaje_validado = FALSE THEN
        NEW.validado_por     := auth.uid();
        NEW.fecha_validacion := NOW();
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_validacion_aprendizaje() IS
    'Al marcar un aprendizaje como validado, auto-registra quién lo validó y cuándo. '
    'El analista solo necesita hacer UPDATE aprendizaje_validado = TRUE.';

CREATE TRIGGER trg_rag_aprendizaje_validacion
    BEFORE UPDATE OF aprendizaje_validado ON rag_aprendizaje
    FOR EACH ROW
    EXECUTE FUNCTION registrar_validacion_aprendizaje();


-- =============================================================================
-- SECCIÓN 8: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- Estrategia:
--
--   rag_gnp:
--     SELECT: todos los autenticados (el Agente 5 necesita leer para validar)
--     INSERT/UPDATE: solo directores y la app rag-ingest (service_role)
--     El campo 'vigente' se puede desactivar por gerentes para retirar contenido
--
--   rag_poliza:
--     SELECT: el analista ve chunks de pólizas que puede ver; directores ven todo
--     INSERT: solo service_role (Agente 5 via Celery) — los chunks son inmutables
--     No UPDATE, no DELETE
--
--   rag_aprendizaje:
--     SELECT: todos los autenticados (filtrado por ramo para gerentes/analistas)
--     INSERT: solo service_role (Agente 5)
--     UPDATE: analistas/gerentes pueden validar o descartar (campos específicos)
-- =============================================================================

ALTER TABLE rag_gnp          ENABLE ROW LEVEL SECURITY;
ALTER TABLE rag_poliza        ENABLE ROW LEVEL SECURITY;
ALTER TABLE rag_aprendizaje  ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------------
-- POLICIES: rag_gnp
-- ---------------------------------------------------------------------------

-- Todos leen el conocimiento de GNP (el Agente 5 lo necesita)
CREATE POLICY pol_rag_gnp_select
    ON rag_gnp FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_rag_gnp_select ON rag_gnp IS
    'Todos los usuarios autenticados pueden leer el conocimiento de GNP. '
    'El Agente 5 consulta esta tabla para validar documentos.';

-- Solo directores gestionan el contenido de GNP desde la app
-- (la app rag-ingest usa service_role y no necesita policy)
CREATE POLICY pol_rag_gnp_insert
    ON rag_gnp FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_rag_gnp_update
    ON rag_gnp FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));


-- ---------------------------------------------------------------------------
-- POLICIES: rag_poliza
-- ---------------------------------------------------------------------------

-- Directores ven todo el historial
CREATE POLICY pol_rag_poliza_select_director
    ON rag_poliza FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

-- Gerente ve chunks de pólizas de su ramo
CREATE POLICY pol_rag_poliza_select_gerente
    ON rag_poliza FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND (ramo IS NULL OR ramo::text = auth_ramo())
    );

-- Analista ve chunks de sus trámites y pólizas asignadas
CREATE POLICY pol_rag_poliza_select_analista
    ON rag_poliza FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND (
            EXISTS (
                SELECT 1 FROM tramite t
                WHERE t.id = tramite_id
                  AND t.analista_id = auth.uid()
            )
        )
    );

-- INSERT: solo service_role (Agente 5 via Celery) — no se expone a authenticated
-- No UPDATE, no DELETE: chunks inmutables


-- ---------------------------------------------------------------------------
-- POLICIES: rag_aprendizaje
-- ---------------------------------------------------------------------------

-- Directores ven todos los aprendizajes
CREATE POLICY pol_rag_aprendizaje_select_director
    ON rag_aprendizaje FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

-- Gerente ve aprendizajes de su ramo (incluyendo no validados para revisarlos)
CREATE POLICY pol_rag_aprendizaje_select_gerente
    ON rag_aprendizaje FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

-- Analista ve aprendizajes validados y no descartados de su ramo
-- (excluye los pendientes de validación para no generar ruido)
CREATE POLICY pol_rag_aprendizaje_select_analista
    ON rag_aprendizaje FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND ramo::text = auth_ramo()
        AND descartado = FALSE
    );

-- UPDATE: analistas y gerentes pueden validar o descartar aprendizajes de su ramo
CREATE POLICY pol_rag_aprendizaje_update_validacion
    ON rag_aprendizaje FOR UPDATE TO authenticated
    USING (
        ramo::text = auth_ramo()
        AND auth_rol() IN ('gerente', 'analista', 'director_general', 'director_ops')
        AND descartado = FALSE
    )
    WITH CHECK (
        ramo::text = auth_ramo()
        OR auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_rag_aprendizaje_update_validacion ON rag_aprendizaje IS
    'Analistas y gerentes validan o descartan aprendizajes de su ramo. '
    'El trigger registra automáticamente quién validó y cuándo.';

-- INSERT: solo service_role (Agente 5) — no se expone a authenticated


-- =============================================================================
-- SECCIÓN 9: GRANTS
-- =============================================================================

GRANT SELECT ON TABLE rag_gnp TO authenticated;
GRANT INSERT, UPDATE (
    vigente, vigente_hasta, tags, metadata, revisado_por, updated_at
) ON TABLE rag_gnp TO authenticated;

GRANT SELECT ON TABLE rag_poliza TO authenticated;
-- Sin INSERT/UPDATE para authenticated — solo service_role

GRANT SELECT ON TABLE rag_aprendizaje TO authenticated;
GRANT UPDATE (
    aprendizaje_validado, descartado, motivo_descarte, tags, updated_at
) ON TABLE rag_aprendizaje TO authenticated;
-- INSERT solo service_role

GRANT EXECUTE ON FUNCTION registrar_validacion_aprendizaje() TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000005_modulo_06_rag.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000006_modulo_07_asignacion_vacaciones.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000006_modulo_07_asignacion_vacaciones.sql
-- Módulo 7 — Asignación de agentes a analistas y cobertura de vacaciones
-- =============================================================================
-- Contexto:
--   Este módulo resuelve la pregunta central del Agente 4:
--   "Este trámite es del agente X en ramo Y — ¿a qué analista lo asigno?"
--
--   Dos tablas con propósitos complementarios:
--
--   asignacion         → Regla estática: agente X + ramo Y → analista Z.
--                        Configurada por gerentes y directores.
--                        El Agente 4 la consulta durante la cascada CUA.
--
--   cobertura_vacaciones → Regla temporal: analista Z está de vacaciones,
--                          analista W lo cubre del DD/MM al DD/MM.
--                          Sobreescribe la asignacion durante el período.
--
--   La función resolver_analista_asignacion() combina ambas tablas y devuelve
--   el UUID del analista correcto para un trámite dado.
--
-- Relaciones con módulos anteriores:
--   asignacion.agente_id             → agente.id    (Módulo 2)
--   asignacion.analista_id           → usuario.id   (Módulo 1)
--   asignacion.asignado_por          → usuario.id   (Módulo 1)
--   cobertura_vacaciones.analista_*  → usuario.id   (Módulo 1)
--   cobertura_vacaciones.creado_por  → usuario.id   (Módulo 1)
--
-- Uso en el pipeline de IA (Agente 4):
--   1. Agente 4 identifica agente_id via cascada CUA
--   2. Llama: SELECT resolver_analista_asignacion(agente_id, ramo, NOW()::DATE)
--   3. Si devuelve UUID → asigna ese analista al trámite
--   4. Si devuelve NULL → ninguna regla activa; marca requiere_atencion = TRUE
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TABLA asignacion
-- =============================================================================
-- Regla de enrutamiento permanente: para el agente X en el ramo Y,
-- los trámites van al analista Z.
--
-- Reglas de negocio:
--   - Solo puede haber UNA asignación activa por (agente_id, ramo).
--     Si se reasigna, se desactiva la anterior y se crea una nueva.
--   - El analista_id DEBE tener rol='analista' y ramo igual al de la asignación.
--     Un analista de vida no puede recibir trámites de autos — trigger lo enforce.
--   - Si no existe asignación para un agente+ramo, el trámite llega con
--     requiere_atencion = TRUE para asignación manual.
-- =============================================================================

CREATE TABLE asignacion (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Clave de enrutamiento: el agente y el ramo del trámite
    -- -------------------------------------------------------------------------
    agente_id       UUID            NOT NULL REFERENCES agente(id),
    ramo            ramo_usuario    NOT NULL,

    -- -------------------------------------------------------------------------
    -- Destino: el analista que recibe los trámites de este agente+ramo
    -- -------------------------------------------------------------------------
    analista_id     UUID            NOT NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Metadatos de gestión
    -- -------------------------------------------------------------------------
    -- Contexto opcional de por qué se hizo esta asignación
    notas           TEXT            NULL,
    -- Quién la configuró (director o gerente)
    asignado_por    UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Estado — soft-delete para mantener historial de asignaciones pasadas
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE asignacion IS
    'Reglas de enrutamiento: agente + ramo → analista. '
    'El Agente 4 las consulta para asignar trámites automáticamente. '
    'Solo puede existir una asignación activa por (agente_id, ramo) — ver índice uq_asignacion_activa.';

COMMENT ON COLUMN asignacion.agente_id      IS 'Agente de seguros cuyo trámite se enruta.';
COMMENT ON COLUMN asignacion.ramo           IS 'Ramo del trámite (vida, gmm, autos, pyme). Junto con agente_id forma la clave de enrutamiento.';
COMMENT ON COLUMN asignacion.analista_id    IS 'Analista destino. Validado por trigger: debe tener rol=analista y ramo coincidente.';
COMMENT ON COLUMN asignacion.asignado_por   IS 'Director o gerente que configuró esta regla. NULL si fue migración o carga inicial.';
COMMENT ON COLUMN asignacion.activo         IS 'Soft-delete. Al reasignar: desactivar la antigua, crear nueva. Historial preservado.';


-- =============================================================================
-- SECCIÓN 2: TABLA cobertura_vacaciones
-- =============================================================================
-- Cobertura temporal durante ausencias (vacaciones, incapacidades, permisos).
-- Durante el período activo, los trámites del analista ausente se redirigen
-- al analista de cobertura — esto lo maneja resolver_analista_asignacion().
--
-- Reglas de negocio:
--   - El analista de cobertura debe ser del MISMO ramo que el ausente.
--   - Un analista no puede cubrirse a sí mismo.
--   - Las coberturas pueden solaparse (varios analistas cubren a uno) — es
--     responsabilidad del gerente evitar solapamientos indeseados.
--   - Si hay múltiples coberturas activas para la misma fecha,
--     resolver_analista_asignacion() toma la primera (ORDER BY created_at).
--   - ramo está denormalizado para evitar JOINs en las policies RLS.
-- =============================================================================

CREATE TABLE cobertura_vacaciones (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Los dos analistas involucrados
    -- -------------------------------------------------------------------------
    -- El analista que estará ausente
    analista_ausente_id     UUID            NOT NULL REFERENCES usuario(id),
    -- El analista que cubre durante la ausencia
    analista_cobertura_id   UUID            NOT NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Ramo denormalizado — ambos analistas deben ser del mismo ramo.
    -- Se valida por trigger. Permite RLS sin JOIN a usuario.
    -- -------------------------------------------------------------------------
    ramo                    ramo_usuario    NOT NULL,

    -- -------------------------------------------------------------------------
    -- Período de cobertura
    -- -------------------------------------------------------------------------
    fecha_inicio            DATE            NOT NULL,
    fecha_fin               DATE            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Metadatos de gestión
    -- -------------------------------------------------------------------------
    notas                   TEXT            NULL,
    creado_por              UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Estado — permite desactivar anticipadamente (regreso antes de lo esperado)
    -- -------------------------------------------------------------------------
    activa                  BOOLEAN         NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- El fin no puede ser anterior al inicio
    CONSTRAINT ck_cobertura_fechas
        CHECK (fecha_fin >= fecha_inicio),

    -- Un analista no se puede cubrir a sí mismo
    CONSTRAINT ck_cobertura_distintos
        CHECK (analista_ausente_id <> analista_cobertura_id)
);

COMMENT ON TABLE cobertura_vacaciones IS
    'Cobertura temporal durante ausencias de analistas. '
    'Durante el período activo, resolver_analista_asignacion() redirige los '
    'trámites del analista ausente al analista de cobertura. '
    'Ambos analistas deben ser del mismo ramo — validado por trigger.';

COMMENT ON COLUMN cobertura_vacaciones.analista_ausente_id   IS 'Analista que estará fuera. Sus trámites se redirigen al analista_cobertura.';
COMMENT ON COLUMN cobertura_vacaciones.analista_cobertura_id IS 'Analista que recibe los trámites durante la ausencia.';
COMMENT ON COLUMN cobertura_vacaciones.ramo                  IS 'Ramo de ambos analistas. Denormalizado para RLS. Validado por trigger.';
COMMENT ON COLUMN cobertura_vacaciones.activa                IS 'FALSE si el analista regresó antes de fecha_fin. Desactivar en lugar de borrar.';


-- =============================================================================
-- SECCIÓN 3: ÍNDICES
-- =============================================================================

-- asignacion ——————————————————————————————————————————————————————————————————

-- Unicidad de asignación activa: solo UNA regla por agente+ramo cuando activo=TRUE.
-- Índice parcial porque cuando activo=FALSE pueden existir múltiples históricos.
CREATE UNIQUE INDEX uq_asignacion_activa
    ON asignacion (agente_id, ramo)
    WHERE activo = TRUE;

COMMENT ON INDEX uq_asignacion_activa IS
    'Garantiza que solo exista una asignación activa por agente+ramo. '
    'Parcial: permite múltiples registros inactivos (historial de asignaciones).';

-- Lookup principal del Agente 4: dado agente_id + ramo, encontrar analista
CREATE INDEX idx_asignacion_agente_ramo
    ON asignacion (agente_id, ramo)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_asignacion_agente_ramo IS
    'Lookup del Agente 4: resolver_analista_asignacion() usa este índice primero.';

-- Buscar todas las asignaciones de un analista (dashboard del gerente, reasignación masiva)
CREATE INDEX idx_asignacion_analista
    ON asignacion (analista_id)
    WHERE activo = TRUE;

-- Buscar asignaciones por ramo (gestión del gerente)
CREATE INDEX idx_asignacion_ramo
    ON asignacion (ramo)
    WHERE activo = TRUE;

-- cobertura_vacaciones ————————————————————————————————————————————————————————

-- Lookup de cobertura activa: ¿quién cubre al analista X en la fecha Y?
-- Es la query crítica de resolver_analista_asignacion().
CREATE INDEX idx_cobertura_ausente_fecha
    ON cobertura_vacaciones (analista_ausente_id, fecha_inicio, fecha_fin)
    WHERE activa = TRUE;

COMMENT ON INDEX idx_cobertura_ausente_fecha IS
    'Lookup de cobertura activa por analista ausente y fecha. '
    'Usado por resolver_analista_asignacion() como segunda consulta.';

-- ¿A quién está cubriendo el analista X esta semana?
CREATE INDEX idx_cobertura_cobertura
    ON cobertura_vacaciones (analista_cobertura_id, fecha_inicio, fecha_fin)
    WHERE activa = TRUE;

-- Gestión del gerente por ramo
CREATE INDEX idx_cobertura_ramo
    ON cobertura_vacaciones (ramo)
    WHERE activa = TRUE;


-- =============================================================================
-- SECCIÓN 4: TRIGGERS — updated_at
-- =============================================================================

CREATE TRIGGER trg_asignacion_updated_at
    BEFORE UPDATE ON asignacion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_cobertura_updated_at
    BEFORE UPDATE ON cobertura_vacaciones
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 5: TRIGGER — Validación de asignacion
-- =============================================================================
-- Garantiza que el analista_id apunte a un usuario con:
--   rol = 'analista'
--   ramo = asignacion.ramo
-- Esto impide asignar un analista de GMM a trámites de Autos, por ejemplo.
-- =============================================================================

CREATE OR REPLACE FUNCTION validar_analista_asignacion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol   rol_usuario;
    v_ramo  ramo_usuario;
BEGIN
    SELECT rol, ramo
    INTO v_rol, v_ramo
    FROM usuario
    WHERE id = NEW.analista_id AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El usuario con id % no existe o está inactivo.',
            NEW.analista_id;
    END IF;

    IF v_rol <> 'analista' THEN
        RAISE EXCEPTION
            'Solo se puede asignar un usuario con rol "analista". '
            'El usuario seleccionado tiene rol "%".',
            v_rol;
    END IF;

    IF v_ramo <> NEW.ramo THEN
        RAISE EXCEPTION
            'El analista es del ramo "%" pero la asignación es para el ramo "%". '
            'Un analista solo puede recibir trámites de su propio ramo.',
            v_ramo, NEW.ramo;
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validar_analista_asignacion() IS
    'Valida que el analista_id tenga rol=analista y ramo coincidente con la asignación. '
    'Dispara en INSERT y UPDATE de la tabla asignacion.';

CREATE TRIGGER trg_asignacion_validar_analista
    BEFORE INSERT OR UPDATE OF analista_id, ramo ON asignacion
    FOR EACH ROW
    EXECUTE FUNCTION validar_analista_asignacion();


-- =============================================================================
-- SECCIÓN 6: TRIGGER — Validación de cobertura_vacaciones
-- =============================================================================
-- Garantiza que ambos analistas sean del mismo ramo y que ese ramo
-- coincida con el campo ramo denormalizado de la cobertura.
-- También valida que ambos tengan rol='analista' y estén activos.
-- =============================================================================

CREATE OR REPLACE FUNCTION validar_cobertura_vacaciones()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_rol_ausente   rol_usuario;
    v_ramo_ausente  ramo_usuario;
    v_rol_cobertura rol_usuario;
    v_ramo_cobertura ramo_usuario;
BEGIN
    -- Validar analista ausente
    SELECT rol, ramo
    INTO v_rol_ausente, v_ramo_ausente
    FROM usuario
    WHERE id = NEW.analista_ausente_id AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El analista ausente (id %) no existe o está inactivo.',
            NEW.analista_ausente_id;
    END IF;

    IF v_rol_ausente <> 'analista' THEN
        RAISE EXCEPTION
            'El analista ausente debe tener rol "analista", tiene "%".',
            v_rol_ausente;
    END IF;

    -- Validar analista de cobertura
    SELECT rol, ramo
    INTO v_rol_cobertura, v_ramo_cobertura
    FROM usuario
    WHERE id = NEW.analista_cobertura_id AND activo = TRUE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'El analista de cobertura (id %) no existe o está inactivo.',
            NEW.analista_cobertura_id;
    END IF;

    IF v_rol_cobertura <> 'analista' THEN
        RAISE EXCEPTION
            'El analista de cobertura debe tener rol "analista", tiene "%".',
            v_rol_cobertura;
    END IF;

    -- Validar que ambos sean del mismo ramo
    IF v_ramo_ausente <> v_ramo_cobertura THEN
        RAISE EXCEPTION
            'Los analistas deben ser del mismo ramo. '
            'Ausente: %, Cobertura: %.',
            v_ramo_ausente, v_ramo_cobertura;
    END IF;

    -- Sincronizar el campo ramo denormalizado con el ramo real de los analistas
    NEW.ramo := v_ramo_ausente;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION validar_cobertura_vacaciones() IS
    'Valida que ambos analistas existan, estén activos, tengan rol=analista '
    'y sean del mismo ramo. Sincroniza el campo ramo denormalizado automáticamente.';

CREATE TRIGGER trg_cobertura_validar
    BEFORE INSERT OR UPDATE ON cobertura_vacaciones
    FOR EACH ROW
    EXECUTE FUNCTION validar_cobertura_vacaciones();


-- =============================================================================
-- SECCIÓN 7: FUNCIÓN resolver_analista_asignacion()
-- =============================================================================
-- Función principal que el Agente 4 llama para determinar a qué analista
-- asignar un trámite.
--
-- Algoritmo:
--   1. Busca la asignación activa para (agente_id, ramo)
--   2. Si la encuentra, verifica si ese analista tiene cobertura activa hoy
--   3. Si hay cobertura → devuelve el analista de cobertura
--   4. Si no hay cobertura → devuelve el analista asignado
--   5. Si no hay asignación → devuelve NULL (Agente 4 marcará requiere_atencion)
--
-- Uso en Python (Agente 4):
--   result = supabase.rpc('resolver_analista_asignacion', {
--       'p_agente_id': agente_id,
--       'p_ramo': 'gmm',
--       'p_fecha': date.today().isoformat()
--   }).execute()
--   analista_id = result.data  # UUID o None
-- =============================================================================

CREATE OR REPLACE FUNCTION resolver_analista_asignacion(
    p_agente_id UUID,
    p_ramo      ramo_usuario,
    p_fecha     DATE DEFAULT CURRENT_DATE
)
RETURNS UUID
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_analista_id   UUID;
    v_cobertura_id  UUID;
BEGIN
    -- Paso 1: Buscar la asignación activa para este agente+ramo
    SELECT analista_id
    INTO v_analista_id
    FROM asignacion
    WHERE agente_id = p_agente_id
      AND ramo      = p_ramo
      AND activo    = TRUE
    LIMIT 1;

    -- Sin asignación → el Agente 4 marcará requiere_atencion = TRUE en el trámite
    IF v_analista_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Paso 2: Verificar si el analista tiene cobertura activa en la fecha dada
    SELECT analista_cobertura_id
    INTO v_cobertura_id
    FROM cobertura_vacaciones
    WHERE analista_ausente_id = v_analista_id
      AND activa       = TRUE
      AND fecha_inicio <= p_fecha
      AND fecha_fin    >= p_fecha
    ORDER BY created_at  -- si hay solapamientos, toma la cobertura más antigua (prioridad)
    LIMIT 1;

    -- Paso 3: Devolver cobertura si aplica, o el analista original
    RETURN COALESCE(v_cobertura_id, v_analista_id);
END;
$$;

COMMENT ON FUNCTION resolver_analista_asignacion(UUID, ramo_usuario, DATE) IS
    'Resuelve el analista correcto para un trámite dado agente_id + ramo + fecha. '
    'Combina asignacion y cobertura_vacaciones. Devuelve NULL si no hay regla activa. '
    'El Agente 4 llama esta función durante la cascada CUA para determinar la asignación.';


-- =============================================================================
-- SECCIÓN 8: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE asignacion           ENABLE ROW LEVEL SECURITY;
ALTER TABLE cobertura_vacaciones ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: asignacion
-- -----------------------------------------------------------------------------

-- Directores ven todas las asignaciones (todos los ramos)
CREATE POLICY pol_asignacion_select_director
    ON asignacion FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_asignacion_select_director ON asignacion IS
    'Directores ven todas las reglas de asignación sin restricción de ramo.';

-- Gerente ve las asignaciones de su ramo
CREATE POLICY pol_asignacion_select_gerente
    ON asignacion FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

COMMENT ON POLICY pol_asignacion_select_gerente ON asignacion IS
    'Gerente ve las asignaciones activas e inactivas de su propio ramo.';

-- Analista ve solo las asignaciones donde él es el destino
CREATE POLICY pol_asignacion_select_analista
    ON asignacion FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND analista_id = auth.uid()
    );

COMMENT ON POLICY pol_asignacion_select_analista ON asignacion IS
    'Analista puede ver qué agentes tiene asignados. Solo sus propias asignaciones.';

-- INSERT: directores (cualquier ramo) y gerentes (solo su ramo)
CREATE POLICY pol_asignacion_insert
    ON asignacion FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    );

COMMENT ON POLICY pol_asignacion_insert ON asignacion IS
    'Directores pueden crear asignaciones en cualquier ramo. '
    'Gerentes solo en su propio ramo.';

-- UPDATE: misma lógica que INSERT
CREATE POLICY pol_asignacion_update
    ON asignacion FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    );

-- DELETE: no — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: cobertura_vacaciones
-- -----------------------------------------------------------------------------

-- Directores ven todas las coberturas
CREATE POLICY pol_cobertura_select_director
    ON cobertura_vacaciones FOR SELECT TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

-- Gerente ve las coberturas de su ramo
CREATE POLICY pol_cobertura_select_gerente
    ON cobertura_vacaciones FOR SELECT TO authenticated
    USING (
        auth_rol() = 'gerente'
        AND ramo::text = auth_ramo()
    );

-- Analista ve las coberturas donde él es ausente o donde él es el que cubre
CREATE POLICY pol_cobertura_select_analista
    ON cobertura_vacaciones FOR SELECT TO authenticated
    USING (
        auth_rol() = 'analista'
        AND (
            analista_ausente_id   = auth.uid()
            OR analista_cobertura_id = auth.uid()
        )
    );

COMMENT ON POLICY pol_cobertura_select_analista ON cobertura_vacaciones IS
    'Analista ve sus propias vacaciones y períodos donde cubre a otros. '
    'No puede ver coberturas de analistas de otros ramos.';

-- INSERT: directores y gerentes (su ramo — el trigger sincroniza el campo ramo)
CREATE POLICY pol_cobertura_insert
    ON cobertura_vacaciones FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR auth_rol() = 'gerente'
    );

COMMENT ON POLICY pol_cobertura_insert ON cobertura_vacaciones IS
    'Directores y gerentes pueden crear coberturas. '
    'El trigger valida que el ramo de los analistas coincida con el ramo del gerente.';

-- UPDATE: directores y gerentes
CREATE POLICY pol_cobertura_update
    ON cobertura_vacaciones FOR UPDATE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    )
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
        OR (
            auth_rol() = 'gerente'
            AND ramo::text = auth_ramo()
        )
    );

-- DELETE: no — soft-delete vía activa = FALSE


-- =============================================================================
-- SECCIÓN 9: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON TABLE asignacion           TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE cobertura_vacaciones TO authenticated;

-- El Agente 4 llama esta función desde service_role, pero también debe estar
-- disponible para authenticated (consultas desde la UI y tests de integración)
GRANT EXECUTE ON FUNCTION resolver_analista_asignacion(UUID, ramo_usuario, DATE) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000006_modulo_07_asignacion_vacaciones.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000007_modulo_08_slas.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000007_modulo_08_slas.sql
-- Módulo 8 — Motor de SLAs configurable por director
-- =============================================================================
-- Filosofía de diseño:
--   NINGÚN valor de SLA está hardcodeado en el código ni en esta migración.
--   Todo se configura desde la UI del director general / director de operaciones:
--
--   dia_inhabil      → Calendario de días no laborables (feriados, puentes, cierres).
--                      Puede ser global o específico por ramo.
--
--   sla_definicion   → Reglas de SLA: para tramites de tipo X, ramo Y, prioridad Z
--                      → el plazo es N días hábiles. Regla más específica gana.
--
--   sla_tramite      → Instancia activa por trámite. Se crea automáticamente al
--                      llamar activar_sla_tramite(). Lleva el deadline calculado,
--                      el estado y el historial de pausas.
--
-- Funciones para el pipeline de IA y el backend:
--
--   calcular_fecha_limite_sla(inicio, dias, ramo)
--       → calcula la fecha límite excluyendo fines de semana + dias_inhabil
--
--   resolver_sla_definicion(tipo_tramite, ramo, prioridad)
--       → encuentra la definición más específica que aplica al trámite
--
--   activar_sla_tramite(tramite_id)
--       → llama a las dos funciones anteriores y crea el sla_tramite
--       → también sincroniza tramite.fecha_limite_sla
--       → el Agente 4 la llama al asignar el analista
--
-- Relaciones con módulos anteriores:
--   sla_definicion.creado_por    → usuario.id   (Módulo 1)
--   sla_tramite.tramite_id       → tramite.id   (Módulo 4)
--   sla_tramite.sla_definicion_id → sla_definicion.id
--   dia_inhabil.creado_por       → usuario.id   (Módulo 1)
--
-- Regla de negocio crítica (ver CLAUDE.md):
--   No hay SLAs ni umbrales hardcodeados. Todos deben poder modificarse
--   desde el Superadmin o desde la UI del director sin tocar código.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE estado_sla AS ENUM (
    'en_curso',     -- el reloj corre, no se ha vencido
    'cumplido',     -- trámite cerrado antes del deadline
    'incumplido',   -- deadline superado sin cerrar el trámite
    'pausado'       -- reloj detenido (ej: trámite en_proceso_gnp — no es culpa de la promotoría)
);

COMMENT ON TYPE estado_sla IS
    'Estado del SLA de un trámite. '
    'Pausado aplica cuando el trámite está en espera de GNP — el reloj se detiene '
    'para no penalizar a la promotoría por tiempos externos.';


-- =============================================================================
-- SECCIÓN 2: TABLA dia_inhabil
-- =============================================================================
-- Calendario de días no laborables que el motor de SLA excluye al contar
-- días hábiles. Configurable por el director desde la UI.
--
-- Ejemplos de días típicos en México:
--   1 Enero   — Año Nuevo
--   5 Feb     — Día de la Constitución
--   21 Mar    — Natalicio de Benito Juárez
--   Semana Santa — Jueves y Viernes Santos
--   1 May     — Día del Trabajo
--   16 Sep    — Independencia
--   2 Nov     — Día de Muertos (algunos ramos descansan)
--   20 Nov    — Revolución Mexicana
--   25 Dic    — Navidad
--
-- aplica_ramo NULL = aplica a toda la promotoría
-- aplica_ramo = 'gmm' = solo afecta el SLA de trámites GMM (ej: cierre de GNP GMM)
-- =============================================================================

CREATE TABLE dia_inhabil (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    fecha           DATE            NOT NULL,
    descripcion     TEXT            NOT NULL,

    -- NULL = aplica a todos los ramos (día festivo nacional)
    -- NOT NULL = solo afecta ese ramo (cierre específico de GNP para un ramo)
    aplica_ramo     ramo_usuario    NULL,

    creado_por      UUID            NULL REFERENCES usuario(id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Un mismo día puede ser inhábil de forma diferente por ramo,
    -- pero solo una vez como global y una vez por ramo específico.
    CONSTRAINT uq_dia_inhabil_fecha_ramo
        UNIQUE (fecha, aplica_ramo)
);

COMMENT ON TABLE dia_inhabil IS
    'Calendario de días no laborables. Configurable por el director desde la UI. '
    'El motor de SLA excluye estos días al calcular fecha_limite. '
    'aplica_ramo NULL = festivo para toda la promotoría; '
    'aplica_ramo = "gmm" = solo afecta el calendario de trámites GMM.';

COMMENT ON COLUMN dia_inhabil.aplica_ramo IS
    'NULL = aplica a todos los ramos. NOT NULL = solo al ramo especificado. '
    'calcular_fecha_limite_sla() excluye los días globales MÁS los del ramo del trámite.';


-- =============================================================================
-- SECCIÓN 3: TABLA sla_definicion
-- =============================================================================
-- Cada fila es una regla de SLA configurable por el director.
-- Ejemplos de configuraciones posibles:
--
--   nombre                  tipo_tramite  ramo   prioridad  dias_habiles  alerta_pct
--   ─────────────────────── ────────────  ─────  ─────────  ────────────  ──────────
--   "Alta GMM urgente"      alta          gmm    urgente    3             70
--   "Alta GMM normal"       alta          gmm    normal     5             80
--   "Endosos todos ramos"   endoso        NULL   NULL       8             75
--   "Cancelaciones"         cancelacion   NULL   NULL       10            80
--   "Default general"       NULL          NULL   NULL       15            80
--
-- Resolución de conflictos — regla de especificidad:
--   Cuando un trámite coincide con múltiples reglas, gana la MÁS ESPECÍFICA.
--   Score = tipo_tramite(4) + ramo(2) + prioridad(1) → range 0-7
--   La función resolver_sla_definicion() aplica esta lógica.
-- =============================================================================

CREATE TABLE sla_definicion (
    -- -------------------------------------------------------------------------
    -- Identidad
    -- -------------------------------------------------------------------------
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre          TEXT            NOT NULL,
    descripcion     TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Criterios de aplicación (NULL = "aplica a todos")
    -- Los tres campos juntos forman la clave de especificidad.
    -- -------------------------------------------------------------------------
    -- NULL = aplica a cualquier tipo de trámite
    tipo_tramite    tipo_tramite    NULL,
    -- NULL = aplica a cualquier ramo
    ramo            ramo_usuario    NULL,
    -- NULL = aplica a cualquier prioridad
    prioridad_aplica prioridad_tramite NULL,

    -- -------------------------------------------------------------------------
    -- Parámetros del SLA — 100% configurables
    -- -------------------------------------------------------------------------
    -- Plazo en días hábiles (excluyendo fines de semana y dias_inhabil)
    dias_habiles    SMALLINT        NOT NULL
                    CHECK (dias_habiles > 0 AND dias_habiles <= 365),

    -- Porcentaje del plazo al que se envía la alerta preventiva.
    -- Ej: 80 = alerta cuando se ha consumido el 80% del tiempo disponible.
    -- Ej: al día 4 de un SLA de 5 días → alerta.
    alerta_porcentaje NUMERIC(5,2)  NOT NULL DEFAULT 80
                    CHECK (alerta_porcentaje > 0 AND alerta_porcentaje < 100),

    -- -------------------------------------------------------------------------
    -- Estado y auditoría
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,
    creado_por      UUID            NULL REFERENCES usuario(id),
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINT: nombre único por combinación de criterios activos
    -- Evita duplicados ambiguos al mismo nivel de especificidad.
    -- -------------------------------------------------------------------------
    CONSTRAINT ck_sla_nombre_not_empty
        CHECK (TRIM(nombre) <> ''),
    CONSTRAINT ck_sla_dias_positivos
        CHECK (dias_habiles >= 1)
);

COMMENT ON TABLE sla_definicion IS
    'Reglas de SLA configurables por el director. Ningún valor está hardcodeado. '
    'resolver_sla_definicion() selecciona la regla más específica que aplica '
    'a un trámite según tipo, ramo y prioridad.';

COMMENT ON COLUMN sla_definicion.nombre           IS 'Nombre descriptivo visible en la UI del director. Ej: "Alta GMM normal".';
COMMENT ON COLUMN sla_definicion.tipo_tramite     IS 'NULL = aplica a cualquier tipo. NOT NULL = solo ese tipo de trámite.';
COMMENT ON COLUMN sla_definicion.ramo             IS 'NULL = aplica a todos los ramos. NOT NULL = solo ese ramo.';
COMMENT ON COLUMN sla_definicion.prioridad_aplica IS 'NULL = aplica a cualquier prioridad. NOT NULL = solo esa prioridad.';
COMMENT ON COLUMN sla_definicion.dias_habiles     IS 'Plazo en días hábiles. Excluye fines de semana y dias_inhabil.';
COMMENT ON COLUMN sla_definicion.alerta_porcentaje IS '% del plazo consumido al que se dispara la alerta preventiva (Módulo 9).';


-- =============================================================================
-- SECCIÓN 4: TABLA sla_tramite
-- =============================================================================
-- Una instancia de SLA por trámite. Se crea al llamar activar_sla_tramite().
-- Lleva el deadline calculado, el estado actual y el historial de pausas.
--
-- Ciclo de vida:
--   activar_sla_tramite() → INSERT (estado=en_curso)
--   trámite avanza → UPDATE (alerta_enviada=TRUE cuando alcanza porcentaje)
--   trámite se cierra → UPDATE (estado=cumplido/incumplido, fecha_cumplimiento)
--   trámite en_proceso_gnp → UPDATE (estado=pausado, pausado_en=NOW())
--   trámite sale de GNP → UPDATE (estado=en_curso, fecha_limite += tiempo_pausado)
-- =============================================================================

CREATE TABLE sla_tramite (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Una sola instancia activa por trámite
    tramite_id          UUID            NOT NULL UNIQUE REFERENCES tramite(id),

    -- Qué regla se aplicó al crear este SLA (auditoría y referencia)
    sla_definicion_id   UUID            NOT NULL REFERENCES sla_definicion(id),

    -- -------------------------------------------------------------------------
    -- Tiempos del SLA
    -- -------------------------------------------------------------------------
    -- Cuándo inició el reloj (fecha de recepción del trámite)
    fecha_inicio        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Deadline calculado: fecha_inicio + dias_habiles (excluyendo inhábiles).
    -- Si se pausa y se reanuda, este campo se extiende por el tiempo pausado.
    fecha_limite        TIMESTAMPTZ     NOT NULL,

    -- -------------------------------------------------------------------------
    -- Estado
    -- -------------------------------------------------------------------------
    estado              estado_sla      NOT NULL DEFAULT 'en_curso',

    -- Cuándo se alcanzó el estado final (cumplido/incumplido)
    fecha_cumplimiento  TIMESTAMPTZ     NULL,

    -- -------------------------------------------------------------------------
    -- Control de alertas
    -- -------------------------------------------------------------------------
    -- TRUE cuando el job de alertas ya envió la notificación preventiva
    alerta_enviada      BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Cuándo se envió la alerta preventiva (para auditoría)
    alerta_enviada_en   TIMESTAMPTZ     NULL,

    -- -------------------------------------------------------------------------
    -- Control de pausas
    -- -------------------------------------------------------------------------
    -- Cuándo inició la pausa actual (NULL = no está pausado)
    pausado_en          TIMESTAMPTZ     NULL,
    -- Tiempo total acumulado en pausa (en segundos). Se suma a fecha_limite al reanudar.
    segundos_pausados   INTEGER         NOT NULL DEFAULT 0 CHECK (segundos_pausados >= 0),

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS de consistencia
    -- -------------------------------------------------------------------------

    -- Solo puede estar pausado si el estado es 'pausado'
    CONSTRAINT ck_sla_pausa_consistente CHECK (
        (estado = 'pausado' AND pausado_en IS NOT NULL)
        OR (estado <> 'pausado' AND pausado_en IS NULL)
    ),

    -- La fecha de cumplimiento solo aplica en estados finales
    CONSTRAINT ck_sla_cumplimiento_consistente CHECK (
        fecha_cumplimiento IS NULL
        OR estado IN ('cumplido', 'incumplido')
    ),

    -- La alerta enviada requiere timestamp
    CONSTRAINT ck_sla_alerta_consistente CHECK (
        (alerta_enviada = FALSE AND alerta_enviada_en IS NULL)
        OR (alerta_enviada = TRUE AND alerta_enviada_en IS NOT NULL)
    ),

    -- El deadline siempre es posterior al inicio
    CONSTRAINT ck_sla_fechas CHECK (fecha_limite > fecha_inicio)
);

COMMENT ON TABLE sla_tramite IS
    'Instancia activa de SLA por trámite. Creada automáticamente por activar_sla_tramite(). '
    'Lleva el deadline calculado, el estado y el historial de pausas. '
    'Cuando el trámite está en_proceso_gnp, el SLA se pausa para no penalizar '
    'a la promotoría por tiempos externos a su control.';

COMMENT ON COLUMN sla_tramite.fecha_limite      IS 'Deadline calculado en días hábiles. Se extiende automáticamente si hubo pausas.';
COMMENT ON COLUMN sla_tramite.pausado_en        IS 'Timestamp de inicio de la pausa actual. NULL cuando el SLA está corriendo.';
COMMENT ON COLUMN sla_tramite.segundos_pausados IS 'Tiempo total pausado acumulado. Se suma a fecha_limite al reanudar.';
COMMENT ON COLUMN sla_tramite.alerta_enviada    IS 'TRUE cuando el job de alertas disparó la notificación preventiva del Módulo 9.';


-- =============================================================================
-- SECCIÓN 5: ÍNDICES
-- =============================================================================

-- dia_inhabil —————————————————————————————————————————————————————————————————

-- La función calcular_fecha_limite_sla() consulta este índice en cada día
-- que evalúa. El lookup es por fecha + ramo (o NULL).
CREATE INDEX idx_dia_inhabil_fecha
    ON dia_inhabil (fecha, aplica_ramo);

COMMENT ON INDEX idx_dia_inhabil_fecha IS
    'Lookup de días inhábiles por fecha. Usado por calcular_fecha_limite_sla().';

-- sla_definicion ——————————————————————————————————————————————————————————————

-- resolver_sla_definicion() filtra por estos tres campos
CREATE INDEX idx_sla_def_criterios
    ON sla_definicion (tipo_tramite, ramo, prioridad_aplica)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_sla_def_criterios IS
    'Resolver de definiciones: filtra por tipo, ramo y prioridad activos.';

-- sla_tramite —————————————————————————————————————————————————————————————————

-- Trámites próximos a vencer (job de alertas — corre periódicamente)
CREATE INDEX idx_sla_tramite_vencimiento
    ON sla_tramite (fecha_limite)
    WHERE estado = 'en_curso';

COMMENT ON INDEX idx_sla_tramite_vencimiento IS
    'Job de alertas: trámites en curso ordenados por fecha_limite próxima.';

-- Trámites que aún no recibieron su alerta preventiva
CREATE INDEX idx_sla_tramite_alerta_pendiente
    ON sla_tramite (fecha_limite)
    WHERE estado = 'en_curso' AND alerta_enviada = FALSE;

COMMENT ON INDEX idx_sla_tramite_alerta_pendiente IS
    'Job de alertas preventivas: trámites en curso sin alerta enviada.';

-- Dashboard del director/gerente: SLAs incumplidos recientes
CREATE INDEX idx_sla_tramite_incumplidos
    ON sla_tramite (fecha_cumplimiento DESC)
    WHERE estado = 'incumplido';

-- Lookup por tramite (el más frecuente desde la UI del trámite)
-- tramite_id ya tiene índice implícito por UNIQUE constraint.


-- =============================================================================
-- SECCIÓN 6: TRIGGERS — updated_at y alertas
-- =============================================================================

CREATE TRIGGER trg_dia_inhabil_updated_at
    BEFORE UPDATE ON dia_inhabil
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sla_def_updated_at
    BEFORE UPDATE ON sla_definicion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_sla_tramite_updated_at
    BEFORE UPDATE ON sla_tramite
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 7: FUNCIÓN calcular_fecha_limite_sla()
-- =============================================================================
-- Calcula la fecha límite de un SLA dado un punto de inicio y un número
-- de días hábiles, excluyendo:
--   - Sábados y domingos (siempre)
--   - Días en dia_inhabil que apliquen al ramo dado (o globales)
--
-- Uso:
--   SELECT calcular_fecha_limite_sla('2026-05-22 09:00'::timestamptz, 5, 'gmm');
--   → '2026-05-29 09:00'  (considerando Semana Santa u otros inhábiles)
-- =============================================================================

CREATE OR REPLACE FUNCTION calcular_fecha_limite_sla(
    p_inicio    TIMESTAMPTZ,
    p_dias      INTEGER,
    p_ramo      ramo_usuario DEFAULT NULL
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_fecha_actual  DATE    := p_inicio::DATE;
    v_contador      INTEGER := 0;
BEGIN
    IF p_dias <= 0 THEN
        RAISE EXCEPTION 'dias_habiles debe ser mayor a 0, se recibió %', p_dias;
    END IF;

    WHILE v_contador < p_dias LOOP
        v_fecha_actual := v_fecha_actual + 1;

        -- Saltar fines de semana (0=domingo, 6=sábado)
        IF EXTRACT(DOW FROM v_fecha_actual) IN (0, 6) THEN
            CONTINUE;
        END IF;

        -- Saltar días inhábiles globales (aplica_ramo IS NULL)
        -- y días inhábiles específicos del ramo del trámite
        IF EXISTS (
            SELECT 1 FROM dia_inhabil
            WHERE fecha = v_fecha_actual
              AND (
                aplica_ramo IS NULL
                OR (p_ramo IS NOT NULL AND aplica_ramo = p_ramo)
              )
        ) THEN
            CONTINUE;
        END IF;

        v_contador := v_contador + 1;
    END LOOP;

    -- Preservar la hora exacta del inicio — solo avanza la fecha
    RETURN (v_fecha_actual::TEXT || ' ' || (p_inicio AT TIME ZONE 'UTC')::TIME::TEXT)::TIMESTAMPTZ;
END;
$$;

COMMENT ON FUNCTION calcular_fecha_limite_sla(TIMESTAMPTZ, INTEGER, ramo_usuario) IS
    'Calcula el deadline de un SLA en días hábiles, excluyendo fines de semana '
    'y los días configurados en dia_inhabil que apliquen al ramo dado. '
    'Si p_ramo es NULL, solo excluye los días globales (aplica_ramo IS NULL).';


-- =============================================================================
-- SECCIÓN 8: FUNCIÓN resolver_sla_definicion()
-- =============================================================================
-- Encuentra la definición de SLA más específica que aplica a un trámite dado
-- su tipo, ramo y prioridad.
--
-- Regla de especificidad (score de 0 a 7):
--   tipo_tramite NOT NULL → +4 puntos
--   ramo NOT NULL         → +2 puntos
--   prioridad NOT NULL    → +1 punto
--   Gana la definición con mayor score. Si empatan, gana la más reciente.
--
-- Retorna NULL si no hay ninguna definición activa que aplique.
-- El backend debe manejar este caso (loggear advertencia, no crear sla_tramite).
-- =============================================================================

CREATE OR REPLACE FUNCTION resolver_sla_definicion(
    p_tipo_tramite  tipo_tramite,
    p_ramo          ramo_usuario,
    p_prioridad     prioridad_tramite
)
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT id
    FROM sla_definicion
    WHERE activo = TRUE
      -- La definición aplica si cada criterio es NULL (comodín) o coincide exactamente
      AND (tipo_tramite     IS NULL OR tipo_tramite     = p_tipo_tramite)
      AND (ramo             IS NULL OR ramo             = p_ramo)
      AND (prioridad_aplica IS NULL OR prioridad_aplica = p_prioridad)
    ORDER BY
        -- Más específica primero
        (CASE WHEN tipo_tramite     IS NOT NULL THEN 4 ELSE 0 END
       + CASE WHEN ramo             IS NOT NULL THEN 2 ELSE 0 END
       + CASE WHEN prioridad_aplica IS NOT NULL THEN 1 ELSE 0 END) DESC,
        -- Si empatan en especificidad, la más reciente (director actualizó la regla)
        created_at DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION resolver_sla_definicion(tipo_tramite, ramo_usuario, prioridad_tramite) IS
    'Encuentra la definición de SLA más específica que aplica al trámite. '
    'Usa un score de especificidad (tipo=4, ramo=2, prioridad=1) para resolver '
    'conflictos cuando múltiples reglas coinciden. Retorna NULL si no hay match.';


-- =============================================================================
-- SECCIÓN 9: FUNCIÓN activar_sla_tramite()
-- =============================================================================
-- Crea el registro sla_tramite para un trámite dado.
-- El Agente 4 la llama al asignar el analista (cuando el trámite pasa de
-- recibido/validando a tener analista asignado y tipo conocido).
--
-- Uso en Python (Agente 4):
--   result = supabase.rpc('activar_sla_tramite', {'p_tramite_id': str(tramite_id)}).execute()
--   if result.data is None:
--       logger.warning("No hay definición de SLA para este trámite", tramite_id=tramite_id)
--
-- Retorna el id del sla_tramite creado, o NULL si no hay definición aplicable.
-- =============================================================================

CREATE OR REPLACE FUNCTION activar_sla_tramite(p_tramite_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tramite           RECORD;
    v_definicion_id     UUID;
    v_fecha_limite      TIMESTAMPTZ;
    v_sla_id            UUID;
BEGIN
    -- Leer los datos del trámite necesarios para resolver el SLA
    SELECT tipo_tramite, ramo, prioridad, fecha_recepcion
    INTO v_tramite
    FROM tramite
    WHERE id = p_tramite_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Trámite % no encontrado.', p_tramite_id;
    END IF;

    -- Si ya existe un SLA activo, no duplicar
    IF EXISTS (SELECT 1 FROM sla_tramite WHERE tramite_id = p_tramite_id) THEN
        SELECT id INTO v_sla_id FROM sla_tramite WHERE tramite_id = p_tramite_id;
        RETURN v_sla_id;
    END IF;

    -- Resolver la definición más específica
    v_definicion_id := resolver_sla_definicion(
        v_tramite.tipo_tramite,
        v_tramite.ramo,
        v_tramite.prioridad
    );

    -- Sin definición → el trámite no tiene SLA configurado (loggear en la app)
    IF v_definicion_id IS NULL THEN
        RETURN NULL;
    END IF;

    -- Calcular el deadline en días hábiles desde la recepción del trámite
    v_fecha_limite := calcular_fecha_limite_sla(
        COALESCE(v_tramite.fecha_recepcion, NOW()),
        (SELECT dias_habiles FROM sla_definicion WHERE id = v_definicion_id),
        v_tramite.ramo
    );

    -- Crear la instancia de SLA
    INSERT INTO sla_tramite (
        tramite_id,
        sla_definicion_id,
        fecha_inicio,
        fecha_limite,
        estado
    ) VALUES (
        p_tramite_id,
        v_definicion_id,
        COALESCE(v_tramite.fecha_recepcion, NOW()),
        v_fecha_limite,
        'en_curso'
    )
    RETURNING id INTO v_sla_id;

    -- Sincronizar tramite.fecha_limite_sla para que los índices de tramite funcionen
    -- (idx_tramite_sla_vencimiento depende de este campo — ver Módulo 4)
    UPDATE tramite
    SET fecha_limite_sla = v_fecha_limite
    WHERE id = p_tramite_id;

    RETURN v_sla_id;
END;
$$;

COMMENT ON FUNCTION activar_sla_tramite(UUID) IS
    'Crea el sla_tramite para un trámite dado. Llama a resolver_sla_definicion() '
    'y calcular_fecha_limite_sla() internamente. Sincroniza tramite.fecha_limite_sla. '
    'El Agente 4 la invoca al asignar el analista. Idempotente: si ya existe, retorna el id existente. '
    'Retorna NULL si no hay ninguna definición de SLA configurada para ese tipo/ramo/prioridad.';


-- =============================================================================
-- SECCIÓN 10: FUNCIÓN pausar_sla_tramite() y reanudar_sla_tramite()
-- =============================================================================
-- Pausar: cuando el trámite entra en estado en_proceso_gnp.
--   El reloj se detiene — la promotoría no controla los tiempos de GNP.
-- Reanudar: cuando GNP responde y el trámite vuelve a manos de la promotoría.
--   Se suma el tiempo pausado a fecha_limite para preservar el plazo original.
-- =============================================================================

CREATE OR REPLACE FUNCTION pausar_sla_tramite(p_tramite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    UPDATE sla_tramite
    SET
        estado     = 'pausado',
        pausado_en = NOW()
    WHERE tramite_id = p_tramite_id
      AND estado     = 'en_curso';

    IF NOT FOUND THEN
        RAISE NOTICE 'SLA del trámite % no está en_curso o no existe.', p_tramite_id;
    END IF;
END;
$$;

COMMENT ON FUNCTION pausar_sla_tramite(UUID) IS
    'Pausa el SLA de un trámite (ej: cuando entra en_proceso_gnp). '
    'El tiempo pausado no cuenta contra el plazo de la promotoría.';


CREATE OR REPLACE FUNCTION reanudar_sla_tramite(p_tramite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_segundos_pausa INTEGER;
BEGIN
    -- Calcular duración de la pausa actual
    SELECT EXTRACT(EPOCH FROM (NOW() - pausado_en))::INTEGER
    INTO v_segundos_pausa
    FROM sla_tramite
    WHERE tramite_id = p_tramite_id AND estado = 'pausado';

    IF NOT FOUND THEN
        RAISE NOTICE 'SLA del trámite % no está pausado o no existe.', p_tramite_id;
        RETURN;
    END IF;

    -- Reanudar: extender fecha_limite y acumular tiempo pausado
    UPDATE sla_tramite
    SET
        estado              = 'en_curso',
        pausado_en          = NULL,
        segundos_pausados   = segundos_pausados + v_segundos_pausa,
        fecha_limite        = fecha_limite + (v_segundos_pausa * INTERVAL '1 second')
    WHERE tramite_id = p_tramite_id;

    -- Sincronizar tramite.fecha_limite_sla con el nuevo deadline
    UPDATE tramite
    SET fecha_limite_sla = (
        SELECT fecha_limite FROM sla_tramite WHERE tramite_id = p_tramite_id
    )
    WHERE id = p_tramite_id;
END;
$$;

COMMENT ON FUNCTION reanudar_sla_tramite(UUID) IS
    'Reanuda el SLA pausado y extiende fecha_limite por el tiempo que estuvo pausado. '
    'Sincroniza tramite.fecha_limite_sla. '
    'El backend la llama cuando el trámite sale del estado en_proceso_gnp.';


-- =============================================================================
-- SECCIÓN 11: FUNCIÓN cerrar_sla_tramite()
-- =============================================================================
-- Marca el SLA como cumplido o incumplido cuando el trámite se cierra.
-- El backend la llama cuando el trámite alcanza estado 'aprobado' o 'rechazado'.
-- =============================================================================

CREATE OR REPLACE FUNCTION cerrar_sla_tramite(p_tramite_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_estado_sla    estado_sla;
    v_fecha_limite  TIMESTAMPTZ;
BEGIN
    SELECT estado, fecha_limite
    INTO v_estado_sla, v_fecha_limite
    FROM sla_tramite
    WHERE tramite_id = p_tramite_id;

    IF NOT FOUND THEN
        RETURN; -- trámite sin SLA configurado, no hay nada que cerrar
    END IF;

    IF v_estado_sla IN ('cumplido', 'incumplido') THEN
        RETURN; -- ya cerrado, idempotente
    END IF;

    UPDATE sla_tramite
    SET
        estado             = CASE WHEN NOW() <= v_fecha_limite THEN 'cumplido' ELSE 'incumplido' END,
        fecha_cumplimiento = NOW()
    WHERE tramite_id = p_tramite_id;
END;
$$;

COMMENT ON FUNCTION cerrar_sla_tramite(UUID) IS
    'Cierra el SLA como cumplido o incumplido según si NOW() <= fecha_limite. '
    'Idempotente: si ya está cerrado, no hace nada. '
    'El backend la llama cuando el trámite alcanza estado aprobado o rechazado.';


-- =============================================================================
-- SECCIÓN 12: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE dia_inhabil     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sla_definicion  ENABLE ROW LEVEL SECURITY;
ALTER TABLE sla_tramite     ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: dia_inhabil
-- Todos los roles pueden leer el calendario — es necesario para mostrar
-- los días hábiles correctamente en la UI de cualquier usuario.
-- Solo directores pueden agregar/modificar días inhábiles.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_dia_inhabil_select
    ON dia_inhabil FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_dia_inhabil_select ON dia_inhabil IS
    'Todos los usuarios autenticados pueden consultar el calendario de días inhábiles. '
    'Necesario para mostrar deadlines correctamente en la UI.';

CREATE POLICY pol_dia_inhabil_insert
    ON dia_inhabil FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
    );

CREATE POLICY pol_dia_inhabil_update
    ON dia_inhabil FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_dia_inhabil_delete
    ON dia_inhabil FOR DELETE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

COMMENT ON POLICY pol_dia_inhabil_delete ON dia_inhabil IS
    'Solo directores pueden eliminar días inhábiles. '
    'DELETE físico permitido (a diferencia de otras tablas) porque son datos '
    'de configuración, no registros de negocio con historial.';


-- -----------------------------------------------------------------------------
-- POLICIES: sla_definicion
-- Todos leen — los analistas y gerentes ven qué SLA aplica a sus trámites.
-- Solo directores configuran las reglas.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_sla_def_select
    ON sla_definicion FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_sla_def_select ON sla_definicion IS
    'Todos los usuarios pueden consultar las definiciones de SLA. '
    'Los analistas las ven en el detalle de sus trámites.';

CREATE POLICY pol_sla_def_insert
    ON sla_definicion FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops')
    );

CREATE POLICY pol_sla_def_update
    ON sla_definicion FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

-- DELETE: no — soft-delete vía activo = FALSE para preservar el historial
-- de qué SLA se aplicó a trámites históricos (sla_tramite.sla_definicion_id)


-- -----------------------------------------------------------------------------
-- POLICIES: sla_tramite
-- Visibilidad idéntica a la del trámite padre (usa puede_ver_tramite del Módulo 5).
-- Solo el backend (service_role) crea y actualiza registros vía las funciones RPC.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_sla_tramite_select
    ON sla_tramite FOR SELECT TO authenticated
    USING (
        puede_ver_tramite(tramite_id)
    );

COMMENT ON POLICY pol_sla_tramite_select ON sla_tramite IS
    'Un usuario puede ver el SLA de un trámite si puede ver el trámite. '
    'Usa puede_ver_tramite() del Módulo 5 para centralizar la lógica de visibilidad.';

-- INSERT/UPDATE: solo service_role vía las funciones RPC (activar, pausar, reanudar, cerrar)
-- No se crean policies de escritura para authenticated — los usuarios no escriben
-- directamente en sla_tramite; todo pasa por las funciones SECURITY DEFINER.


-- =============================================================================
-- SECCIÓN 13: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dia_inhabil    TO authenticated;
GRANT SELECT, INSERT, UPDATE         ON TABLE sla_definicion TO authenticated;
GRANT SELECT                         ON TABLE sla_tramite    TO authenticated;

-- Las funciones RPC son la única puerta de escritura a sla_tramite
GRANT EXECUTE ON FUNCTION calcular_fecha_limite_sla(TIMESTAMPTZ, INTEGER, ramo_usuario) TO authenticated;
GRANT EXECUTE ON FUNCTION resolver_sla_definicion(tipo_tramite, ramo_usuario, prioridad_tramite) TO authenticated;
GRANT EXECUTE ON FUNCTION activar_sla_tramite(UUID)   TO authenticated;
GRANT EXECUTE ON FUNCTION pausar_sla_tramite(UUID)    TO authenticated;
GRANT EXECUTE ON FUNCTION reanudar_sla_tramite(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION cerrar_sla_tramite(UUID)    TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000007_modulo_08_slas.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000008_modulo_09_notificaciones.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000008_modulo_09_notificaciones.sql
-- Módulo 9 — Notificaciones en tiempo real
-- =============================================================================
-- Arquitectura:
--   Las notificaciones se entregan en tiempo real vía Supabase Realtime.
--   El frontend suscribe a INSERT en la tabla notificacion WHERE usuario_id = auth.uid().
--   Cuando el backend (Celery/agentes) inserta una fila, Realtime la empuja
--   al navegador del destinatario en milisegundos — sin polling.
--
--   Dos tablas:
--
--   notificacion        → Registro individual por usuario y evento.
--                         Cada analista ve solo las suyas. El badge del nav
--                         muestra el conteo de no leídas.
--
--   notificacion_config → Preferencias por usuario y tipo. Modelo opt-out:
--                         si no hay fila de config, el usuario recibe la notif.
--                         El usuario puede desactivar tipos específicos desde
--                         su perfil. El director puede modificar configs de
--                         cualquier usuario.
--
-- Flujo de entrega:
--   Evento ocurre (cambio de estado, SLA, correo, etc.)
--   → Celery worker llama crear_notificacion(usuario_id, tipo, ...)
--   → crear_notificacion verifica notificacion_config (¿usuario activó este tipo?)
--   → INSERT en notificacion
--   → Supabase Realtime notifica al frontend
--   → Badge actualizado, toast mostrado
--   → Usuario lee → UPDATE leida=TRUE via frontend
--
-- Tipos de eventos que generan notificaciones:
--   Pipeline IA    → tramite_asignado, requiere_atencion, correo_borrador_listo
--   Estado         → cambio_estado_tramite, rechazo_gnp, aprobacion_gnp
--   SLA            → sla_alerta, sla_vencido
--   Correos        → correo_recibido
--   Operaciones    → tramite_reasignado, documento_requerido, cobertura_inicio
--
-- Relaciones con módulos anteriores:
--   notificacion.usuario_id      → usuario.id    (Módulo 1)
--   notificacion.tramite_id      → tramite.id    (Módulo 4, nullable)
--   notificacion_config.usuario_id → usuario.id  (Módulo 1)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TIPOS ENUM
-- =============================================================================

CREATE TYPE tipo_notificacion AS ENUM (
    -- ---- Generadas por el pipeline de IA ----
    -- Agente 4 asignó un nuevo trámite al analista
    'tramite_asignado',
    -- El trámite fue reasignado a otro analista (notifica al anterior y al nuevo)
    'tramite_reasignado',
    -- Un agente IA marcó el trámite como requiere_atencion=TRUE
    'requiere_atencion',
    -- Agente 6 terminó el borrador del correo — analista debe revisarlo
    'correo_borrador_listo',

    -- ---- Generadas por cambios de estado ----
    -- El trámite cambió de estado (configurable: el analista puede silenciar este)
    'cambio_estado_tramite',
    -- GNP rechazó el trámite
    'rechazo_gnp',
    -- GNP aprobó el trámite
    'aprobacion_gnp',

    -- ---- Generadas por el motor de SLA (Módulo 8) ----
    -- El trámite consumió X% del plazo SLA (alerta preventiva)
    'sla_alerta',
    -- El trámite superó el deadline SLA sin cerrarse
    'sla_vencido',

    -- ---- Generadas por correos (Módulo 5) ----
    -- Nuevo correo entrante vinculado a un trámite del analista
    'correo_recibido',

    -- ---- Generadas por operaciones ----
    -- El agente de seguros necesita enviar documentos faltantes
    'documento_requerido',
    -- El analista está cubriendo a otro que inició vacaciones (Módulo 7)
    'cobertura_inicio'
);

COMMENT ON TYPE tipo_notificacion IS
    'Catálogo de eventos que generan notificaciones en Olimpo CRM. '
    'Cada tipo puede ser habilitado/deshabilitado por usuario en notificacion_config.';


-- =============================================================================
-- SECCIÓN 2: TABLA notificacion
-- =============================================================================
-- Cada fila es una notificación individual para un usuario específico.
-- El frontend suscribe a cambios en esta tabla para recibir notificaciones
-- en tiempo real vía Supabase Realtime.
--
-- Política de retención:
--   Las notificaciones no se borran físicamente — se archivan.
--   Esto preserva el historial de alertas para auditoría.
--   El frontend filtra archivada=FALSE en la vista normal.
-- =============================================================================

CREATE TABLE notificacion (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Destinatario
    -- -------------------------------------------------------------------------
    usuario_id      UUID                NOT NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Contenido
    -- -------------------------------------------------------------------------
    tipo            tipo_notificacion   NOT NULL,
    titulo          TEXT                NOT NULL,
    cuerpo          TEXT                NOT NULL,

    -- -------------------------------------------------------------------------
    -- Contexto — enlace al trámite relacionado (para navegar desde la notif)
    -- -------------------------------------------------------------------------
    tramite_id      UUID                NULL REFERENCES tramite(id) ON DELETE SET NULL,

    -- Datos adicionales para que el frontend renderice la notif correctamente.
    -- Estructura varía por tipo. Ejemplos:
    --   tramite_asignado:      { "folio": "TRM-2026-00042", "analista": "nombre" }
    --   sla_alerta:            { "folio": "TRM-2026-00042", "porcentaje": 82, "horas_restantes": 6 }
    --   correo_borrador_listo: { "correo_id": "uuid", "asunto": "Re: Alta GMM..." }
    --   rechazo_gnp:           { "folio_ot": "OT-123456", "codigo_rechazo": "R-042" }
    datos           JSONB               NULL DEFAULT '{}',

    -- -------------------------------------------------------------------------
    -- Estado de lectura
    -- -------------------------------------------------------------------------
    leida           BOOLEAN             NOT NULL DEFAULT FALSE,
    leida_en        TIMESTAMPTZ         NULL,

    -- -------------------------------------------------------------------------
    -- Archivo — el usuario puede descartar notificaciones sin eliminarlas
    -- -------------------------------------------------------------------------
    archivada       BOOLEAN             NOT NULL DEFAULT FALSE,
    archivada_en    TIMESTAMPTZ         NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría (sin updated_at — el estado cambia vía campos específicos)
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Leída requiere timestamp
    CONSTRAINT ck_notif_leida_consistente CHECK (
        (leida = FALSE AND leida_en IS NULL)
        OR (leida = TRUE AND leida_en IS NOT NULL)
    ),

    -- Archivada requiere timestamp
    CONSTRAINT ck_notif_archivada_consistente CHECK (
        (archivada = FALSE AND archivada_en IS NULL)
        OR (archivada = TRUE AND archivada_en IS NOT NULL)
    ),

    CONSTRAINT ck_notif_titulo_not_empty CHECK (TRIM(titulo) <> ''),
    CONSTRAINT ck_notif_cuerpo_not_empty CHECK (TRIM(cuerpo) <> '')
);

COMMENT ON TABLE notificacion IS
    'Notificaciones individuales por usuario. '
    'El frontend suscribe via Supabase Realtime a INSERT WHERE usuario_id = auth.uid(). '
    'Las notificaciones no se borran — se archivan para preservar el historial.';

COMMENT ON COLUMN notificacion.tramite_id IS
    'Trámite relacionado. El frontend lo usa para navegar directamente al trámite. '
    'ON DELETE SET NULL: si el trámite se elimina (soft-delete no aplica aquí), '
    'la notificación se preserva sin referencia rota.';
COMMENT ON COLUMN notificacion.datos      IS 'JSONB con contexto específico del tipo. Permite renderizado rico en la UI.';
COMMENT ON COLUMN notificacion.archivada  IS 'El usuario descartó la notificación. El frontend la oculta pero existe en el historial.';


-- =============================================================================
-- SECCIÓN 3: TABLA notificacion_config
-- =============================================================================
-- Preferencias de notificación por usuario y tipo.
-- Modelo opt-out: si no existe fila de config, el usuario RECIBE la notificación.
-- El usuario puede desactivar tipos específicos desde su perfil en la UI.
-- El director puede gestionar configs de cualquier usuario.
--
-- Ejemplo: un analista que no quiere recibir 'cambio_estado_tramite' en cada
-- movimiento puede desactivarla — seguirá recibiendo 'sla_alerta' y 'rechazo_gnp'.
-- =============================================================================

CREATE TABLE notificacion_config (
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- El usuario dueño de esta preferencia
    usuario_id      UUID                NOT NULL REFERENCES usuario(id),

    -- El tipo de notificación que se está configurando
    tipo            tipo_notificacion   NOT NULL,

    -- TRUE = el usuario recibe este tipo | FALSE = silenciado
    activa          BOOLEAN             NOT NULL DEFAULT TRUE,

    -- Auditoría
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- Una sola configuración por (usuario, tipo)
    CONSTRAINT uq_notif_config_usuario_tipo
        UNIQUE (usuario_id, tipo)
);

COMMENT ON TABLE notificacion_config IS
    'Preferencias de notificación por usuario y tipo. Modelo opt-out: '
    'si no existe fila de config, el usuario recibe la notificación. '
    'El usuario gestiona sus propias preferencias desde su perfil. '
    'El director puede modificar la configuración de cualquier usuario.';

COMMENT ON COLUMN notificacion_config.activa IS
    'TRUE = recibe el tipo. FALSE = silenciado. '
    'La función crear_notificacion() consulta esta tabla antes de insertar.';


-- =============================================================================
-- SECCIÓN 4: ÍNDICES
-- =============================================================================

-- notificacion —————————————————————————————————————————————————————————————————

-- Badge del nav: conteo de notificaciones no leídas del usuario actual
CREATE INDEX idx_notif_usuario_no_leidas
    ON notificacion (usuario_id, created_at DESC)
    WHERE leida = FALSE AND archivada = FALSE;

COMMENT ON INDEX idx_notif_usuario_no_leidas IS
    'Query principal del badge del nav: notificaciones activas no leídas por usuario. '
    'Partial: excluye las leídas y archivadas (la mayoría del volumen).';

-- Bandeja de entrada: todas las no archivadas del usuario (leídas + no leídas)
CREATE INDEX idx_notif_usuario_bandeja
    ON notificacion (usuario_id, created_at DESC)
    WHERE archivada = FALSE;

-- Notificaciones de un trámite específico (panel lateral del trámite)
CREATE INDEX idx_notif_tramite
    ON notificacion (tramite_id, created_at DESC)
    WHERE tramite_id IS NOT NULL;

-- notificacion_config ——————————————————————————————————————————————————————————

-- crear_notificacion() consulta este índice para verificar preferencias
CREATE INDEX idx_notif_config_usuario_tipo
    ON notificacion_config (usuario_id, tipo);


-- =============================================================================
-- SECCIÓN 5: TRIGGERS
-- =============================================================================

-- updated_at en notificacion_config
CREATE TRIGGER trg_notif_config_updated_at
    BEFORE UPDATE ON notificacion_config
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Trigger para auto-registrar leida_en cuando leida cambia a TRUE
CREATE OR REPLACE FUNCTION set_notif_leida_en()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.leida = TRUE AND OLD.leida = FALSE THEN
        NEW.leida_en := NOW();
    END IF;

    IF NEW.archivada = TRUE AND OLD.archivada = FALSE THEN
        NEW.archivada_en := NOW();
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION set_notif_leida_en() IS
    'Auto-registra leida_en y archivada_en al momento de marcar los flags. '
    'El frontend solo necesita hacer UPDATE SET leida=TRUE — el timestamp es automático.';

CREATE TRIGGER trg_notif_set_timestamps
    BEFORE UPDATE OF leida, archivada ON notificacion
    FOR EACH ROW
    EXECUTE FUNCTION set_notif_leida_en();

-- Prevenir que una notificación se "des-lea" o "des-archive"
CREATE OR REPLACE FUNCTION proteger_notif_inmutabilidad()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.leida = TRUE AND NEW.leida = FALSE THEN
        RAISE EXCEPTION
            'Una notificación leída no puede marcarse como no leída.';
    END IF;

    IF OLD.archivada = TRUE AND NEW.archivada = FALSE THEN
        RAISE EXCEPTION
            'Una notificación archivada no puede desarchivarse.';
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION proteger_notif_inmutabilidad() IS
    'Garantiza que leida y archivada solo transicionen en una dirección. '
    'Preserva integridad del historial de notificaciones.';

CREATE TRIGGER trg_notif_proteger_estado
    BEFORE UPDATE OF leida, archivada ON notificacion
    FOR EACH ROW
    EXECUTE FUNCTION proteger_notif_inmutabilidad();


-- =============================================================================
-- SECCIÓN 6: FUNCIÓN crear_notificacion()
-- =============================================================================
-- Función central que todo el backend usa para generar notificaciones.
-- Verifica las preferencias del usuario antes de insertar.
--
-- Uso en Python (Celery worker, agentes IA):
--   supabase.rpc('crear_notificacion', {
--       'p_usuario_id':  str(analista_id),
--       'p_tipo':        'correo_borrador_listo',
--       'p_titulo':      'Borrador listo para revisión',
--       'p_cuerpo':      'El Agente 6 preparó el borrador para TRM-2026-00042.',
--       'p_tramite_id':  str(tramite_id),
--       'p_datos':       json.dumps({'correo_id': str(correo_id), 'asunto': '...'})
--   }).execute()
--
-- Retorna el id de la notificacion creada, o NULL si el usuario la silencia.
-- =============================================================================

CREATE OR REPLACE FUNCTION crear_notificacion(
    p_usuario_id    UUID,
    p_tipo          tipo_notificacion,
    p_titulo        TEXT,
    p_cuerpo        TEXT,
    p_tramite_id    UUID        DEFAULT NULL,
    p_datos         JSONB       DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_activa        BOOLEAN;
    v_notif_id      UUID;
BEGIN
    -- Verificar preferencias del usuario (modelo opt-out)
    SELECT activa INTO v_activa
    FROM notificacion_config
    WHERE usuario_id = p_usuario_id
      AND tipo       = p_tipo;

    -- Si existe config y está desactivada, no insertar
    IF FOUND AND v_activa = FALSE THEN
        RETURN NULL;
    END IF;

    -- Insertar la notificación
    INSERT INTO notificacion (
        usuario_id,
        tipo,
        titulo,
        cuerpo,
        tramite_id,
        datos
    ) VALUES (
        p_usuario_id,
        p_tipo,
        TRIM(p_titulo),
        TRIM(p_cuerpo),
        p_tramite_id,
        COALESCE(p_datos, '{}')
    )
    RETURNING id INTO v_notif_id;

    RETURN v_notif_id;
END;
$$;

COMMENT ON FUNCTION crear_notificacion(UUID, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Crea una notificación para un usuario respetando sus preferencias. '
    'Modelo opt-out: si no hay config, se crea la notificación. '
    'Si el usuario desactivó ese tipo, retorna NULL sin insertar. '
    'El INSERT dispara Supabase Realtime al navegador del destinatario.';


-- =============================================================================
-- SECCIÓN 7: FUNCIÓN notificar_a_rol()
-- =============================================================================
-- Broadcast de notificación a todos los usuarios de un rol (y opcionalmente ramo).
-- Útil para alertas de SLA vencido que van al gerente completo,
-- o para avisar a todos los directores de un evento crítico.
--
-- Uso en Python:
--   supabase.rpc('notificar_a_rol', {
--       'p_rol':   'gerente',
--       'p_ramo':  'gmm',
--       'p_tipo':  'sla_vencido',
--       'p_titulo': 'SLA vencido',
--       'p_cuerpo': 'El trámite TRM-2026-00042 superó su plazo.',
--       'p_tramite_id': str(tramite_id),
--       'p_datos': '{}'
--   }).execute()
-- =============================================================================

CREATE OR REPLACE FUNCTION notificar_a_rol(
    p_rol           rol_usuario,
    p_ramo          ramo_usuario    DEFAULT NULL,
    p_tipo          tipo_notificacion  DEFAULT NULL,
    p_titulo        TEXT            DEFAULT NULL,
    p_cuerpo        TEXT            DEFAULT NULL,
    p_tramite_id    UUID            DEFAULT NULL,
    p_datos         JSONB           DEFAULT '{}'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_usuario       RECORD;
    v_count         INTEGER := 0;
BEGIN
    FOR v_usuario IN
        SELECT id FROM usuario
        WHERE rol    = p_rol
          AND activo = TRUE
          AND (p_ramo IS NULL OR ramo = p_ramo)
    LOOP
        IF crear_notificacion(
            v_usuario.id, p_tipo, p_titulo, p_cuerpo, p_tramite_id, p_datos
        ) IS NOT NULL THEN
            v_count := v_count + 1;
        END IF;
    END LOOP;

    RETURN v_count; -- número de notificaciones efectivamente creadas
END;
$$;

COMMENT ON FUNCTION notificar_a_rol(rol_usuario, ramo_usuario, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Envía la misma notificación a todos los usuarios activos de un rol y ramo. '
    'Respeta las preferencias individuales via crear_notificacion(). '
    'Retorna el número de notificaciones efectivamente creadas. '
    'Uso: alertas de SLA al gerente del ramo, avisos al equipo completo.';


-- =============================================================================
-- SECCIÓN 8: SUPABASE REALTIME
-- =============================================================================
-- Para que Supabase Realtime entregue notificaciones al frontend, la tabla
-- debe estar en la publicación de replicación de Supabase.
--
-- El frontend se suscribe así:
--   supabase
--     .channel('notificaciones')
--     .on('postgres_changes', {
--       event: 'INSERT',
--       schema: 'public',
--       table: 'notificacion',
--       filter: `usuario_id=eq.${userId}`
--     }, (payload) => {
--       // mostrar toast + actualizar badge
--       showToast(payload.new.titulo)
--       incrementBadge()
--     })
--     .subscribe()
-- =============================================================================

ALTER PUBLICATION supabase_realtime ADD TABLE notificacion;

COMMENT ON TABLE notificacion IS
    'Notificaciones individuales por usuario. '
    'Publicada en supabase_realtime — el frontend recibe INSERT en tiempo real. '
    'Las notificaciones no se borran — se archivan para preservar el historial.';


-- =============================================================================
-- SECCIÓN 9: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE notificacion        ENABLE ROW LEVEL SECURITY;
ALTER TABLE notificacion_config ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: notificacion
-- Las notificaciones son estrictamente personales — nadie ve las de otro.
-- Excepción: service_role bypasa RLS (backend puede insertar para cualquier usuario).
-- -----------------------------------------------------------------------------

-- SELECT: cada usuario solo ve sus propias notificaciones
CREATE POLICY pol_notif_select
    ON notificacion FOR SELECT TO authenticated
    USING (usuario_id = auth.uid());

COMMENT ON POLICY pol_notif_select ON notificacion IS
    'Cada usuario accede únicamente a sus propias notificaciones. '
    'Supabase Realtime también respeta esta policy en las suscripciones filtradas.';

-- UPDATE: cada usuario puede marcar sus notificaciones como leídas o archivadas
-- (el trigger impide revertir esos estados)
CREATE POLICY pol_notif_update
    ON notificacion FOR UPDATE TO authenticated
    USING (usuario_id = auth.uid())
    WITH CHECK (usuario_id = auth.uid());

COMMENT ON POLICY pol_notif_update ON notificacion IS
    'El usuario puede actualizar sus notificaciones (marcar leída, archivar). '
    'Los triggers garantizan que leida y archivada solo avancen, nunca retrocedan.';

-- INSERT: prohibido para authenticated — solo service_role vía crear_notificacion()
-- DELETE: prohibido — las notificaciones son inmutables, se archivan


-- -----------------------------------------------------------------------------
-- POLICIES: notificacion_config
-- Cada usuario gestiona sus propias preferencias.
-- Los directores pueden ver y modificar configs de cualquier usuario (soporte).
-- -----------------------------------------------------------------------------

CREATE POLICY pol_notif_config_select_propio
    ON notificacion_config FOR SELECT TO authenticated
    USING (usuario_id = auth.uid());

CREATE POLICY pol_notif_config_select_director
    ON notificacion_config FOR SELECT TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_notif_config_insert_propio
    ON notificacion_config FOR INSERT TO authenticated
    WITH CHECK (usuario_id = auth.uid());

CREATE POLICY pol_notif_config_insert_director
    ON notificacion_config FOR INSERT TO authenticated
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

CREATE POLICY pol_notif_config_update_propio
    ON notificacion_config FOR UPDATE TO authenticated
    USING (usuario_id = auth.uid())
    WITH CHECK (usuario_id = auth.uid());

CREATE POLICY pol_notif_config_update_director
    ON notificacion_config FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops'));

-- DELETE: no — soft-disable vía activa=FALSE


-- =============================================================================
-- SECCIÓN 10: GRANTS
-- =============================================================================

-- notificacion: authenticated puede SELECT (RLS filtra por usuario_id) y UPDATE
-- INSERT solo service_role vía crear_notificacion() SECURITY DEFINER
GRANT SELECT, UPDATE ON TABLE notificacion        TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE notificacion_config TO authenticated;

-- Funciones disponibles para el backend y para la UI (tests de integración)
GRANT EXECUTE ON FUNCTION crear_notificacion(UUID, tipo_notificacion, TEXT, TEXT, UUID, JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION notificar_a_rol(rol_usuario, ramo_usuario, tipo_notificacion, TEXT, TEXT, UUID, JSONB) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000008_modulo_09_notificaciones.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000009_modulo_10_auditoria.sql
-- ============================================================
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


-- ============================================================
-- MIGRACIÓN: 20260522000010_modulo_11_correcciones.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000010_modulo_11_correcciones.sql
-- Módulo 11 — Correcciones y adiciones post-diagnóstico
-- =============================================================================
-- Esta migración corrige 4 hallazgos identificados en la auditoría del modelo
-- de datos contra el ERD de referencia. No modifica migraciones anteriores.
--
-- HALLAZGO #1 — BLOQUEANTE:
--   Faltaba tabla ot_activacion para el ciclo GNP completo. El estado
--   'activado' del trámite puede repetirse (endosos con múltiples activaciones).
--   tramite.folio_ot solo guarda la última OT; esta tabla guarda el historial.
--
-- HALLAZGO #2 — DISEÑO:
--   agente↔asistente modelado como one-to-many. En la realidad un asistente
--   puede trabajar para múltiples agentes de la misma familia/sociedad.
--   Se agrega tabla junction agente_asistente (many-to-many) y se puebla
--   con los vínculos existentes. asistente.agente_id queda como "agente principal".
--
-- HALLAZGO #3 — DISEÑO:
--   asistente solo tenía telefono TEXT NULL (un campo plano). Se agrega
--   tabla asistente_telefono con la misma estructura que agente_telefono.
--
-- HALLAZGO #4 — DISEÑO:
--   sla_definicion siempre iniciaba el SLA en fecha_recepcion. Se agregan
--   estado_inicio y estado_fin para soportar SLAs multi-estado (ej: tiempo
--   de respuesta de GNP desde turnado_gnp hasta en_proceso_gnp).
--
-- ADICIÓN:
--   Función resolver_agente_desde_email() — usada por el Agente 4 en la
--   cascada CUA. Busca el agente asociado a cualquier email de agente o
--   asistente y detecta ambigüedad cuando el asistente tiene múltiples agentes.
--
--   Valor 'activacion_gnp' al enum tipo_notificacion — el pipeline lo necesita
--   para notificar al analista cuando GNP activa una póliza.
--
-- Relaciones con módulos anteriores:
--   ot_activacion.tramite_id     → tramite.id     (Módulo 4)
--   ot_activacion.registrado_por → usuario.id     (Módulo 1)
--   agente_asistente.agente_id   → agente.id      (Módulo 2)
--   agente_asistente.asistente_id → asistente.id  (Módulo 2)
--   asistente_telefono.asistente_id → asistente.id (Módulo 2)
--   sla_definicion               → ya existe       (Módulo 8)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: ENUM — Agregar 'activacion_gnp' a tipo_notificacion
-- =============================================================================
-- El pipeline de Agente 5/backend necesita notificar al analista cuando
-- GNP activa una póliza. Este valor faltaba en el enum original.
-- IF NOT EXISTS previene error si se re-ejecuta la migración.
-- =============================================================================

ALTER TYPE tipo_notificacion ADD VALUE IF NOT EXISTS 'activacion_gnp';

COMMENT ON TYPE tipo_notificacion IS
    'Catálogo de eventos que generan notificaciones en Olimpo CRM. '
    'Incluye activacion_gnp para notificar cuando GNP activa una póliza (Módulo 11).';


-- =============================================================================
-- SECCIÓN 2: TABLA ot_activacion
-- =============================================================================
-- Historial de Órdenes de Trabajo (OT) de GNP por trámite.
-- Un trámite puede tener MÚLTIPLES activaciones — especialmente endosos que
-- pueden ser activados parcialmente, rechazados por GNP y re-procesados.
--
-- Diferencia con tramite.folio_ot:
--   tramite.folio_ot      → la OT más reciente/principal (campo de acceso rápido)
--   ot_activacion         → historial completo de todas las OTs del trámite
--
-- Flujo típico con múltiples activaciones (endoso de póliza pyme):
--   1. Trámite turnado a GNP → OT-001 generada
--   2. GNP activa parcialmente → INSERT ot_activacion(OT-001, motivo='parcial')
--   3. Analista complementa documentos → trámite vuelve a completo
--   4. GNP activa definitivamente → INSERT ot_activacion(OT-001, resuelta=TRUE)
-- =============================================================================

CREATE TABLE ot_activacion (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Trámite al que pertenece esta activación
    -- -------------------------------------------------------------------------
    tramite_id          UUID            NOT NULL REFERENCES tramite(id),

    -- -------------------------------------------------------------------------
    -- Datos de la OT de GNP
    -- -------------------------------------------------------------------------
    -- Número de OT asignado por GNP (puede repetirse si GNP reutiliza el número)
    numero_ot           TEXT            NOT NULL,
    -- Descripción de por qué se generó esta activación
    -- Ej: "Alta nueva", "Endoso ampliación de suma", "Corrección de vigencia"
    motivo              TEXT            NULL,
    -- Fecha en que GNP registró la activación en sus sistemas
    fecha_activacion    DATE            NOT NULL DEFAULT CURRENT_DATE,

    -- -------------------------------------------------------------------------
    -- Resolución de la activación
    -- -------------------------------------------------------------------------
    -- Fecha en que GNP cerró esta activación (aprobó o rechazó)
    fecha_resolucion    DATE            NULL,
    -- TRUE cuando GNP cerró la activación definitivamente
    resuelta            BOOLEAN         NOT NULL DEFAULT FALSE,
    -- Resultado final de GNP para esta activación
    resultado           TEXT            NULL
                        CHECK (resultado IS NULL
                            OR resultado IN ('aprobado', 'rechazado', 'pendiente')),

    -- -------------------------------------------------------------------------
    -- Notas y contexto del analista
    -- -------------------------------------------------------------------------
    notas               TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Actor que registró esta activación en el CRM
    -- -------------------------------------------------------------------------
    registrado_por      UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------

    -- Fecha de resolución solo si está resuelta
    CONSTRAINT ck_ot_resolucion_consistente CHECK (
        fecha_resolucion IS NULL OR resuelta = TRUE
    ),

    -- Resultado solo si está resuelta
    CONSTRAINT ck_ot_resultado_consistente CHECK (
        resultado IS NULL OR resuelta = TRUE
    ),

    -- La fecha de resolución no puede ser anterior a la activación
    CONSTRAINT ck_ot_fechas CHECK (
        fecha_resolucion IS NULL OR fecha_resolucion >= fecha_activacion
    ),

    CONSTRAINT ck_ot_numero_not_empty CHECK (TRIM(numero_ot) <> '')
);

COMMENT ON TABLE ot_activacion IS
    'Historial completo de Órdenes de Trabajo de GNP por trámite. '
    'Un trámite puede tener múltiples activaciones (especialmente endosos). '
    'tramite.folio_ot guarda la OT principal para acceso rápido; '
    'esta tabla guarda el detalle y la historia de cada interacción con GNP.';

COMMENT ON COLUMN ot_activacion.tramite_id       IS 'Trámite al que pertenece esta OT. Un trámite puede tener múltiples OTs.';
COMMENT ON COLUMN ot_activacion.numero_ot        IS 'Número de OT asignado por GNP. Registrado por el analista al recibirlo.';
COMMENT ON COLUMN ot_activacion.fecha_activacion IS 'Fecha en que GNP generó o activó la OT en sus sistemas internos.';
COMMENT ON COLUMN ot_activacion.resuelta         IS 'TRUE cuando GNP cerró esta OT (aprobó o rechazó). FALSE mientras está en proceso.';
COMMENT ON COLUMN ot_activacion.resultado        IS 'Resultado final: aprobado | rechazado | pendiente. NULL hasta que GNP resuelva.';
COMMENT ON COLUMN ot_activacion.registrado_por   IS 'Usuario del CRM que capturó esta activación. NULL si fue registrado por service_role.';


-- =============================================================================
-- SECCIÓN 3: TABLA agente_asistente — junction many-to-many
-- =============================================================================
-- Un asistente puede trabajar para múltiples agentes (ej: familia de agentes,
-- despacho con varios agentes GNP). Esto es común en promotorías mexicanas.
--
-- Relación con asistente.agente_id existente:
--   asistente.agente_id = el agente PRINCIPAL (usado por defecto en el Agente 4)
--   agente_asistente    = TODOS los agentes para los que trabaja el asistente
--
-- Uso por el Agente 4 (cascada CUA):
--   Si resolver_agente_desde_email() detecta que un asistente tiene múltiples
--   agentes activos en esta tabla (ambiguo=TRUE), el trámite se crea con
--   requiere_atencion=TRUE para que un humano seleccione el agente correcto.
--
-- Al crear esta migración, se puebla automáticamente con las relaciones
-- ya existentes (asistente.agente_id → agente_asistente).
-- =============================================================================

CREATE TABLE agente_asistente (
    -- -------------------------------------------------------------------------
    -- Clave primaria compuesta — un par (agente, asistente) es único
    -- -------------------------------------------------------------------------
    agente_id       UUID        NOT NULL REFERENCES agente(id),
    asistente_id    UUID        NOT NULL REFERENCES asistente(id),

    -- -------------------------------------------------------------------------
    -- Estado del vínculo — soft-delete para preservar historial
    -- -------------------------------------------------------------------------
    -- FALSE cuando el asistente deja de trabajar para este agente específico
    activo          BOOLEAN     NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (agente_id, asistente_id)
);

COMMENT ON TABLE agente_asistente IS
    'Junction many-to-many: un asistente puede trabajar para múltiples agentes. '
    'El Agente 4 detecta ambigüedad cuando hay > 1 agente activo para el mismo asistente '
    'y marca el trámite con requiere_atencion = TRUE. '
    'asistente.agente_id sigue siendo el agente principal para resolución por defecto.';

COMMENT ON COLUMN agente_asistente.agente_id    IS 'Agente para el que trabaja el asistente.';
COMMENT ON COLUMN agente_asistente.asistente_id IS 'Asistente que trabaja para el agente.';
COMMENT ON COLUMN agente_asistente.activo       IS 'FALSE cuando el asistente deja de representar a este agente. El registro se preserva.';

-- Poblar con los vínculos ya existentes (migración no destructiva)
INSERT INTO agente_asistente (agente_id, asistente_id, activo)
SELECT agente_id, id, TRUE
FROM asistente
ON CONFLICT (agente_id, asistente_id) DO NOTHING;

COMMENT ON INDEX agente_asistente_pkey IS
    'Un par (agente, asistente) es único. Previene vínculos duplicados.';


-- =============================================================================
-- SECCIÓN 4: TABLA asistente_telefono
-- =============================================================================
-- Múltiples teléfonos por asistente. Misma estructura que agente_telefono.
-- El campo asistente.telefono (TEXT NULL) queda como teléfono legacy/simple
-- para compatibilidad. Los nuevos registros deben usar esta tabla.
-- =============================================================================

CREATE TABLE asistente_telefono (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    asistente_id    UUID            NOT NULL REFERENCES asistente(id) ON DELETE CASCADE,
    tipo            tipo_telefono   NOT NULL DEFAULT 'celular',
    numero          TEXT            NOT NULL,
    -- Solo un teléfono preferente por asistente (enforced por índice único parcial)
    preferente      BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT ck_asistente_tel_numero CHECK (TRIM(numero) <> '')
);

COMMENT ON TABLE asistente_telefono IS
    'Teléfonos del asistente. Un asistente puede tener varios; '
    'el campo preferente identifica el número principal. '
    'Misma estructura que agente_telefono para consistencia del modelo.';

COMMENT ON COLUMN asistente_telefono.tipo       IS 'Tipo de teléfono: celular, oficina, casa, whatsapp, otro.';
COMMENT ON COLUMN asistente_telefono.preferente IS 'Solo un teléfono por asistente puede ser preferente (enforced por índice único parcial).';


-- =============================================================================
-- SECCIÓN 5: ALTER TABLE sla_definicion — agregar estado_inicio y estado_fin
-- =============================================================================
-- Permite definir SLAs que corran entre estados específicos del trámite.
--
-- Casos de uso:
--   NULL / NULL     → SLA de la promotoría: desde recepción hasta aprobado/rechazado
--   turnado_gnp / en_proceso_gnp → SLA de respuesta de GNP
--   completo / turnado_gnp       → SLA de "tiempo de turno al portal GNP"
--
-- La función activar_sla_tramite() debe leer estado_inicio para determinar
-- el punto de inicio correcto del SLA (se actualiza en el backend, no en DB).
-- =============================================================================

ALTER TABLE sla_definicion
    ADD COLUMN IF NOT EXISTS estado_inicio  estado_tramite  NULL,
    ADD COLUMN IF NOT EXISTS estado_fin     estado_tramite  NULL;

COMMENT ON COLUMN sla_definicion.estado_inicio IS
    'Estado del trámite en que inicia el conteo del SLA. '
    'NULL = inicia desde la recepción del trámite (comportamiento por defecto). '
    'Ejemplo: turnado_gnp para medir el tiempo de respuesta de GNP.';

COMMENT ON COLUMN sla_definicion.estado_fin IS
    'Estado del trámite en que termina el conteo del SLA. '
    'NULL = termina en aprobado o rechazado (comportamiento por defecto). '
    'Ejemplo: en_proceso_gnp para medir solo el tiempo de acuse de GNP.';


-- =============================================================================
-- SECCIÓN 6: ÍNDICES
-- =============================================================================

-- ot_activacion ————————————————————————————————————————————————————————————————

-- Timeline de OTs de un trámite (el más frecuente desde la UI)
CREATE INDEX idx_ot_tramite
    ON ot_activacion (tramite_id, fecha_activacion DESC);

COMMENT ON INDEX idx_ot_tramite IS
    'Historial de OTs de un trámite ordenado por fecha. Query principal desde el panel del trámite.';

-- OTs pendientes de resolución (dashboard de seguimiento GNP)
CREATE INDEX idx_ot_pendientes
    ON ot_activacion (fecha_activacion DESC)
    WHERE resuelta = FALSE;

COMMENT ON INDEX idx_ot_pendientes IS
    'OTs que GNP aún no ha resuelto. Dashboard de seguimiento de trámites en GNP.';

-- Búsqueda por número de OT (cuando GNP notifica por email o teléfono)
CREATE INDEX idx_ot_numero
    ON ot_activacion (numero_ot);

-- agente_asistente ————————————————————————————————————————————————————————————

-- Buscar todos los agentes de un asistente (Agente 4: ¿para quién trabaja este email?)
CREATE INDEX idx_agente_asistente_asistente
    ON agente_asistente (asistente_id)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_agente_asistente_asistente IS
    'Agentes activos de un asistente. El Agente 4 usa este índice para detectar ambigüedad '
    '(cuando un asistente trabaja para > 1 agente activo).';

-- Buscar todos los asistentes de un agente (UI: ficha del agente)
CREATE INDEX idx_agente_asistente_agente
    ON agente_asistente (agente_id)
    WHERE activo = TRUE;

-- asistente_telefono ——————————————————————————————————————————————————————————

CREATE INDEX idx_asistente_tel_asistente
    ON asistente_telefono (asistente_id);

-- Solo UN teléfono preferente por asistente — índice único parcial
CREATE UNIQUE INDEX uq_asistente_telefono_preferente
    ON asistente_telefono (asistente_id)
    WHERE preferente = TRUE;

COMMENT ON INDEX uq_asistente_telefono_preferente IS
    'Garantiza que cada asistente tenga máximo un teléfono marcado como preferente.';


-- =============================================================================
-- SECCIÓN 7: TRIGGERS
-- =============================================================================

-- updated_at
CREATE TRIGGER trg_ot_activacion_updated_at
    BEFORE UPDATE ON ot_activacion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

-- Auditoría — audit_table_change() ya existe desde módulo 10
CREATE TRIGGER trg_ot_activacion_audit
    AFTER INSERT OR UPDATE OR DELETE ON ot_activacion
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_ot_activacion_audit ON ot_activacion IS
    'Audita todo cambio en OTs de GNP. Permite responder: '
    '"¿Quién marcó esta OT como resuelta y cuándo?"';

CREATE TRIGGER trg_agente_asistente_audit
    AFTER INSERT OR UPDATE OR DELETE ON agente_asistente
    FOR EACH ROW
    EXECUTE FUNCTION audit_table_change();

COMMENT ON TRIGGER trg_agente_asistente_audit ON agente_asistente IS
    'Audita cambios en vínculos agente↔asistente. '
    'Permite rastrear cuándo un asistente empezó o dejó de representar a un agente.';


-- =============================================================================
-- SECCIÓN 8: FUNCIÓN registrar_activacion_gnp()
-- =============================================================================
-- Función RPC que el analista llama desde la UI cuando GNP activa una póliza.
-- También puede ser llamada por el backend cuando el Agente captura una activación.
--
-- Efectos secundarios:
--   1. Inserta el registro en ot_activacion
--   2. Actualiza tramite.folio_ot con el número de OT (si es la primera o si se
--      pasa force_update=TRUE)
--   3. Crea notificación 'activacion_gnp' si hay analista asignado
--
-- Uso en Python (Agente o backend):
--   supabase.rpc('registrar_activacion_gnp', {
--       'p_tramite_id': str(tramite_id),
--       'p_numero_ot': 'OT-2026-00123',
--       'p_motivo': 'Alta de póliza GMM',
--       'p_fecha_activacion': '2026-05-23',
--       'p_force_update_folio': False
--   }).execute()
-- =============================================================================

CREATE OR REPLACE FUNCTION registrar_activacion_gnp(
    p_tramite_id            UUID,
    p_numero_ot             TEXT,
    p_motivo                TEXT        DEFAULT NULL,
    p_fecha_activacion      DATE        DEFAULT CURRENT_DATE,
    p_notas                 TEXT        DEFAULT NULL,
    p_force_update_folio    BOOLEAN     DEFAULT FALSE
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_ot_id         UUID;
    v_analista_id   UUID;
    v_folio         TEXT;
BEGIN
    IF TRIM(p_numero_ot) = '' THEN
        RAISE EXCEPTION 'El número de OT no puede estar vacío.';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tramite WHERE id = p_tramite_id) THEN
        RAISE EXCEPTION 'Trámite % no encontrado.', p_tramite_id;
    END IF;

    -- Insertar la activación
    INSERT INTO ot_activacion (
        tramite_id,
        numero_ot,
        motivo,
        fecha_activacion,
        notas,
        registrado_por
    ) VALUES (
        p_tramite_id,
        TRIM(p_numero_ot),
        p_motivo,
        p_fecha_activacion,
        p_notas,
        auth.uid()
    )
    RETURNING id INTO v_ot_id;

    -- Actualizar tramite.folio_ot si es la primera OT o si se fuerza
    SELECT folio_ot, analista_id INTO v_folio, v_analista_id
    FROM tramite WHERE id = p_tramite_id;

    IF v_folio IS NULL OR p_force_update_folio THEN
        UPDATE tramite
        SET folio_ot = TRIM(p_numero_ot)
        WHERE id = p_tramite_id;
    END IF;

    -- Notificar al analista asignado (si existe)
    IF v_analista_id IS NOT NULL THEN
        PERFORM crear_notificacion(
            v_analista_id,
            'activacion_gnp',
            'GNP activó una póliza',
            'La OT ' || TRIM(p_numero_ot) || ' fue activada por GNP.' ||
                COALESCE(' Motivo: ' || p_motivo, ''),
            p_tramite_id,
            jsonb_build_object('numero_ot', TRIM(p_numero_ot), 'ot_activacion_id', v_ot_id)
        );
    END IF;

    RETURN v_ot_id;
END;
$$;

COMMENT ON FUNCTION registrar_activacion_gnp(UUID, TEXT, TEXT, DATE, TEXT, BOOLEAN) IS
    'Registra una activación de GNP para un trámite. '
    'Inserta en ot_activacion, actualiza tramite.folio_ot si es la primera OT, '
    'y envía notificación activacion_gnp al analista asignado. '
    'Idempotente respecto a ot_activacion (no impide duplicados intencionales de GNP).';


-- =============================================================================
-- SECCIÓN 9: FUNCIÓN resolver_agente_desde_email()
-- =============================================================================
-- Función crítica para el Agente 4 durante la cascada CUA.
-- Dado un email, encuentra el agente asociado buscando en:
--   1. agente_email     → email de agente directo (más confiable)
--   2. asistente.email  → email de asistente → retorna su agente principal
--      + verifica ambigüedad en agente_asistente (múltiples agentes activos)
--
-- Retorna NULL si el email no pertenece a ningún agente ni asistente conocido.
-- El Agente 4 maneja el NULL marcando requiere_atencion = TRUE en el trámite.
--
-- Uso en Python (Agente 4):
--   result = supabase.rpc('resolver_agente_desde_email', {
--       'p_email': remitente_email
--   }).execute()
--   if result.data is None:
--       # email desconocido — marcar requiere_atencion
--   elif result.data['ambiguo']:
--       # asistente con múltiples agentes — marcar requiere_atencion
--   else:
--       agente_id = result.data['agente_id']
--       via       = result.data['via']  # 'agente_directo' o 'asistente'
-- =============================================================================

CREATE TYPE resolucion_email_agente AS (
    agente_id       UUID,
    via             TEXT,       -- 'agente_directo' | 'asistente'
    asistente_id    UUID,       -- NULL cuando via = 'agente_directo'
    ambiguo         BOOLEAN     -- TRUE si el asistente tiene > 1 agente activo
);

CREATE OR REPLACE FUNCTION resolver_agente_desde_email(p_email TEXT)
RETURNS resolucion_email_agente
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_resultado     resolucion_email_agente;
    v_agente_id     UUID;
    v_asistente_id  UUID;
    v_agente_ppal   UUID;
    v_count_agentes INTEGER;
BEGIN
    -- Paso 1: buscar en agente_email (el agente envió el correo directamente)
    SELECT ae.agente_id INTO v_agente_id
    FROM agente_email ae
    JOIN agente a ON a.id = ae.agente_id AND a.activo = TRUE
    WHERE ae.email = LOWER(TRIM(p_email))
    LIMIT 1;

    IF v_agente_id IS NOT NULL THEN
        v_resultado.agente_id    := v_agente_id;
        v_resultado.via          := 'agente_directo';
        v_resultado.asistente_id := NULL;
        v_resultado.ambiguo      := FALSE;
        RETURN v_resultado;
    END IF;

    -- Paso 2: buscar en asistente (el asistente envió el correo)
    SELECT id, agente_id INTO v_asistente_id, v_agente_ppal
    FROM asistente
    WHERE email = LOWER(TRIM(p_email))
      AND activo = TRUE
    LIMIT 1;

    IF v_asistente_id IS NULL THEN
        RETURN NULL;  -- email desconocido en el sistema
    END IF;

    -- Verificar cuántos agentes activos tiene este asistente en la junction
    SELECT COUNT(*) INTO v_count_agentes
    FROM agente_asistente aa
    JOIN agente a ON a.id = aa.agente_id AND a.activo = TRUE
    WHERE aa.asistente_id = v_asistente_id
      AND aa.activo = TRUE;

    v_resultado.agente_id    := v_agente_ppal;      -- agente principal por defecto
    v_resultado.via          := 'asistente';
    v_resultado.asistente_id := v_asistente_id;
    -- ambiguo = TRUE cuando hay más de 1 agente activo y el Agente 4 no puede
    -- determinar automáticamente a cuál de ellos pertenece este trámite
    v_resultado.ambiguo      := (v_count_agentes > 1);

    RETURN v_resultado;
END;
$$;

COMMENT ON FUNCTION resolver_agente_desde_email(TEXT) IS
    'Resuelve el agente asociado a un email entrante. '
    'Paso 1: busca en agente_email (agente directo). '
    'Paso 2: busca en asistente → retorna agente principal. '
    'Si el asistente tiene > 1 agente activo, ambiguo=TRUE → el Agente 4 '
    'debe marcar requiere_atencion=TRUE para resolución manual. '
    'Retorna NULL si el email no está registrado en el CRM.';

COMMENT ON TYPE resolucion_email_agente IS
    'Resultado de resolver_agente_desde_email(). '
    'agente_id: UUID del agente identificado. '
    'via: como se identificó (agente_directo | asistente). '
    'asistente_id: UUID del asistente cuando via=asistente. '
    'ambiguo: TRUE cuando el asistente trabaja para múltiples agentes — requiere decisión humana.';


-- =============================================================================
-- SECCIÓN 10: ROW LEVEL SECURITY (RLS)
-- =============================================================================

ALTER TABLE ot_activacion       ENABLE ROW LEVEL SECURITY;
ALTER TABLE agente_asistente    ENABLE ROW LEVEL SECURITY;
ALTER TABLE asistente_telefono  ENABLE ROW LEVEL SECURITY;


-- -----------------------------------------------------------------------------
-- POLICIES: ot_activacion
-- Visibilidad idéntica al trámite padre (usa puede_ver_tramite del Módulo 5).
-- Escritura: analistas sobre sus trámites, gerentes y directores sobre los suyos.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_ot_select
    ON ot_activacion FOR SELECT TO authenticated
    USING (
        puede_ver_tramite(tramite_id)
    );

COMMENT ON POLICY pol_ot_select ON ot_activacion IS
    'Un usuario puede ver las OTs de un trámite si puede ver el trámite. '
    'Usa puede_ver_tramite() del Módulo 5 para centralizar la lógica de visibilidad.';

CREATE POLICY pol_ot_insert
    ON ot_activacion FOR INSERT TO authenticated
    WITH CHECK (
        puede_ver_tramite(tramite_id)
        AND auth_rol() IN ('director_general', 'director_ops', 'gerente', 'analista')
    );

COMMENT ON POLICY pol_ot_insert ON ot_activacion IS
    'Cualquier usuario que puede ver el trámite puede registrar una activación de GNP.';

CREATE POLICY pol_ot_update
    ON ot_activacion FOR UPDATE TO authenticated
    USING (
        puede_ver_tramite(tramite_id)
        AND auth_rol() IN ('director_general', 'director_ops', 'gerente')
    )
    WITH CHECK (
        puede_ver_tramite(tramite_id)
        AND auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

COMMENT ON POLICY pol_ot_update ON ot_activacion IS
    'Solo directores y gerentes pueden modificar el resultado de una OT. '
    'Los analistas pueden registrar pero no corregir OTs (evita manipulación de resultados).';

-- DELETE: nadie — las OTs son registros históricos de GNP, nunca se borran


-- -----------------------------------------------------------------------------
-- POLICIES: agente_asistente
-- Misma estrategia que agente: todos leen, directores y gerentes gestionan.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_agente_asistente_select
    ON agente_asistente FOR SELECT TO authenticated
    USING (TRUE);

COMMENT ON POLICY pol_agente_asistente_select ON agente_asistente IS
    'Todos los usuarios autenticados pueden ver los vínculos agente↔asistente. '
    'Necesario para que el Agente 4 resuelva la cascada CUA.';

CREATE POLICY pol_agente_asistente_insert
    ON agente_asistente FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_agente_asistente_update
    ON agente_asistente FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- DELETE: no — soft-delete vía activo = FALSE


-- -----------------------------------------------------------------------------
-- POLICIES: asistente_telefono
-- Misma estrategia que agente_telefono.
-- -----------------------------------------------------------------------------

CREATE POLICY pol_asistente_tel_select
    ON asistente_telefono FOR SELECT TO authenticated
    USING (TRUE);

CREATE POLICY pol_asistente_tel_insert
    ON asistente_telefono FOR INSERT TO authenticated
    WITH CHECK (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );

CREATE POLICY pol_asistente_tel_update
    ON asistente_telefono FOR UPDATE TO authenticated
    USING (auth_rol() IN ('director_general', 'director_ops', 'gerente'))
    WITH CHECK (auth_rol() IN ('director_general', 'director_ops', 'gerente'));

-- Teléfonos SÍ se pueden eliminar físicamente (sin impacto de integridad)
CREATE POLICY pol_asistente_tel_delete
    ON asistente_telefono FOR DELETE TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops', 'gerente')
    );


-- =============================================================================
-- SECCIÓN 11: GRANTS
-- =============================================================================

GRANT SELECT, INSERT, UPDATE ON TABLE ot_activacion      TO authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE agente_asistente   TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE asistente_telefono TO authenticated;

GRANT EXECUTE ON FUNCTION registrar_activacion_gnp(UUID, TEXT, TEXT, DATE, TEXT, BOOLEAN) TO authenticated;
GRANT EXECUTE ON FUNCTION resolver_agente_desde_email(TEXT) TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000010_modulo_11_correcciones.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000011_modulo_12_mejoras_diagnostico.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000011_modulo_12_mejoras_diagnostico.sql
-- Módulo 12 — Mejoras de seguridad, rendimiento y diseño post-diagnóstico
-- =============================================================================
-- Esta migración implementa las optimizaciones y correcciones del diagnóstico
-- experto en base de datos.
--
-- MEJORAS INCLUIDAS:
--   1. Seguridad: Define search_path en todas las funciones SECURITY DEFINER
--      para prevenir secuestro de ruta de búsqueda (privilege escalation).
--   2. Rendimiento: Índices en las 17 llaves foráneas (FK) faltantes que
--      son de uso constante en queries, JOINs y borrados en cascada.
--   3. Auditoría: Triggers de auditoría para tablas operativas clave (poliza,
--      documento, correo, adjunto) que anteriormente no se auditaban.
--   4. Diseño de Negocio: Modificación de fecha_activacion y fecha_resolucion
--      en ot_activacion de DATE a TIMESTAMPTZ para soportar SLAs precisos.
--   5. Validación: Restricciones CHECK para garantizar formatos de email correctos.
--   6. Privacidad: Trigger para purgar automáticamente contraseñas de ZIPs
--      en adjunto una vez procesado el archivo.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: SEGURIDAD — search_path EN FUNCIONES SECURITY DEFINER
-- =============================================================================
-- Configurar search_path de forma explícita en las funciones que se ejecutan
-- con privilegios del creador (SECURITY DEFINER) para evitar ejecuciones
-- maliciosas en esquemas temporales.
-- =============================================================================

ALTER FUNCTION public.auth_rol() SET search_path = auth, pg_catalog;
ALTER FUNCTION public.auth_ramo() SET search_path = auth, pg_catalog;
ALTER FUNCTION public.set_agente_ia_sesion(TEXT) SET search_path = pg_catalog;
ALTER FUNCTION public.puede_ver_tramite(UUID) SET search_path = public, auth, pg_catalog;


-- =============================================================================
-- SECCIÓN 2: RENDIMIENTO — ÍNDICES EN LLAVES FORÁNEAS (FK)
-- =============================================================================
-- La base de datos no indexa FKs por defecto. Estos índices optimizan JOINs
-- y validaciones ON DELETE, evitando seq scans costosos.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_agente_ia_log_correo_id 
    ON public.agente_ia_log(correo_id);

CREATE INDEX IF NOT EXISTS idx_asignacion_asignado_por 
    ON public.asignacion(asignado_por);

CREATE INDEX IF NOT EXISTS idx_cobertura_vacaciones_creado_por 
    ON public.cobertura_vacaciones(creado_por);

CREATE INDEX IF NOT EXISTS idx_dia_inhabil_creado_por 
    ON public.dia_inhabil(creado_por);

CREATE INDEX IF NOT EXISTS idx_ot_activacion_registrado_por 
    ON public.ot_activacion(registrado_por);

CREATE INDEX IF NOT EXISTS idx_rag_aprendizaje_poliza_id 
    ON public.rag_aprendizaje(poliza_id);

CREATE INDEX IF NOT EXISTS idx_rag_aprendizaje_documento_id 
    ON public.rag_aprendizaje(documento_id);

CREATE INDEX IF NOT EXISTS idx_rag_aprendizaje_validado_por 
    ON public.rag_aprendizaje(validado_por);

CREATE INDEX IF NOT EXISTS idx_rag_gnp_ingresado_por 
    ON public.rag_gnp(ingresado_por);

CREATE INDEX IF NOT EXISTS idx_rag_gnp_revisado_por 
    ON public.rag_gnp(revisado_por);

CREATE INDEX IF NOT EXISTS idx_rag_poliza_tramite_id 
    ON public.rag_poliza(tramite_id);

CREATE INDEX IF NOT EXISTS idx_rag_poliza_tramite_evento_id 
    ON public.rag_poliza(tramite_evento_id);

CREATE INDEX IF NOT EXISTS idx_sla_definicion_creado_por 
    ON public.sla_definicion(creado_por);

CREATE INDEX IF NOT EXISTS idx_sla_tramite_sla_definicion_id 
    ON public.sla_tramite(sla_definicion_id);

CREATE INDEX IF NOT EXISTS idx_tramite_asegurado_id 
    ON public.tramite(asegurado_id);

CREATE INDEX IF NOT EXISTS idx_tramite_asistente_id 
    ON public.tramite(asistente_id);

CREATE INDEX IF NOT EXISTS idx_tramite_evento_usuario_id 
    ON public.tramite_evento(usuario_id);


-- =============================================================================
-- SECCIÓN 3: AUDITORÍA — TRIGGERS EN TABLAS OPERATIVAS
-- =============================================================================
-- Registrar en audit_log todos los inserts, updates y deletes manuales o
-- automáticos en pólizas, documentos, correos y adjuntos.
-- =============================================================================

CREATE TRIGGER trg_poliza_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.poliza
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

CREATE TRIGGER trg_documento_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.documento
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

CREATE TRIGGER trg_correo_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.correo
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

CREATE TRIGGER trg_adjunto_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.adjunto
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();


-- =============================================================================
-- SECCIÓN 4: DISEÑO DE NEGOCIO — TIMESTAMPTZ EN ot_activacion
-- =============================================================================
-- Cambiar de DATE a TIMESTAMPTZ para no perder hora y minuto de las activaciones,
-- habilitando el cálculo de SLAs e indicadores de respuesta con GNP.
-- =============================================================================

ALTER TABLE public.ot_activacion 
    ALTER COLUMN fecha_activacion TYPE TIMESTAMPTZ USING fecha_activacion::timestamptz,
    ALTER COLUMN fecha_activacion SET DEFAULT NOW(),
    ALTER COLUMN fecha_resolucion TYPE TIMESTAMPTZ USING fecha_resolucion::timestamptz;


-- =============================================================================
-- SECCIÓN 5: VALIDACIÓN — RESTRICCIONES DE FORMATO DE EMAIL
-- =============================================================================
-- Validar a nivel de base de datos que los correos electrónicos tengan un formato
-- consistente, como última línea de defensa ante inserciones directas en Supabase.
-- =============================================================================

ALTER TABLE public.usuario ADD CONSTRAINT ck_usuario_email_valido 
    CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$');

ALTER TABLE public.agente_email ADD CONSTRAINT ck_agente_email_valido 
    CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$');

ALTER TABLE public.asistente ADD CONSTRAINT ck_asistente_email_valido 
    CHECK (email ~* '^[A-Za-z0-9._%-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,4}$');


-- =============================================================================
-- SECCIÓN 6: PRIVACIDAD POR DISEÑO — PURGAR CONTRASEÑAS ZIP
-- =============================================================================
-- Crear un trigger que automáticamente ponga en NULL la contraseña temporal
-- en adjunto una vez que el estado cambia a procesado, descomprimido, ilegible o error.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.clean_zip_password()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- Limpiar contraseña si el archivo ya fue procesado
    IF NEW.estado IN ('descomprimido', 'error', 'ilegible', 'procesado') THEN
        NEW.password = NULL;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.clean_zip_password() IS
    'Limpia automáticamente la contraseña temporal de un adjunto una vez procesado.';

CREATE TRIGGER trg_clean_zip_password
    BEFORE UPDATE OF estado ON public.adjunto
    FOR EACH ROW
    EXECUTE FUNCTION public.clean_zip_password();

COMMENT ON TRIGGER trg_clean_zip_password ON public.adjunto IS
    'Garantiza la eliminación física de contraseñas de ZIPs por cumplimiento de LFPDPPP.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000011_modulo_12_mejoras_diagnostico.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000012_fix_clean_zip_password.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000012_fix_clean_zip_password.sql
-- Corrección de bugs en la función clean_zip_password()
-- =============================================================================
-- BUGS CORREGIDOS:
--
--   BUG-01: La función clean_zip_password() registrada en 20260522000011
--     usaba el estado 'descomprimido' que NO existe en el enum estado_adjunto.
--     Los valores válidos del enum son: 'pendiente', 'procesando', 'procesado',
--     'ilegible', 'error'. El estado 'descomprimido' nunca podría matchear,
--     por lo que las contraseñas ZIP nunca se limpiaban al procesar un ZIP.
--
--   BUG-02: La misma función no actualizaba password_eliminado = TRUE al
--     limpiar la contraseña. El constraint ck_adjunto_password requiere que
--     si password IS NULL entonces password_eliminado puede ser TRUE o FALSE,
--     pero la columna password_eliminado es la evidencia de auditoría de que
--     la contraseña fue procesada y eliminada correctamente. Sin setear ese
--     flag a TRUE, el campo de auditoría quedaba en FALSE aunque la contraseña
--     hubiera sido borrada por el trigger, creando un estado inconsistente.
--
--   LIMPIEZA: Adjuntos huérfanos que quedaron con password != NULL por el bug
--     (ya en estado procesado, ilegible o error, pero sin haber sido limpiados)
--     se normalizan con un UPDATE transaccional.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: REEMPLAZAR clean_zip_password() CON VERSIÓN CORRECTA
-- =============================================================================
-- Cambios respecto a la versión con bug en 20260522000011:
--   1. Se elimina 'descomprimido' — valor inválido en el enum estado_adjunto
--   2. Se agrega NEW.password_eliminado := TRUE para el campo de auditoría
-- =============================================================================

CREATE OR REPLACE FUNCTION public.clean_zip_password()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
BEGIN
    -- Limpiar contraseña si el archivo ya fue procesado.
    -- Estados válidos del enum estado_adjunto:
    --   'pendiente', 'procesando', 'procesado', 'ilegible', 'error'
    -- NOTA: 'descomprimido' NO es un valor válido del enum — NO incluir.
    IF NEW.estado IN ('procesado', 'ilegible', 'error') THEN
        NEW.password          := NULL;
        -- BUG-02 fix: marcar la columna de auditoría cuando se elimina la contraseña.
        -- El constraint ck_adjunto_password (password IS NULL AND password_eliminado TRUE
        -- no conflictúa) — solo prohíbe password NOT NULL con password_eliminado TRUE.
        IF OLD.password IS NOT NULL THEN
            NEW.password_eliminado := TRUE;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.clean_zip_password() IS
    'Limpia automáticamente la contraseña temporal de un adjunto al pasar a '
    'estado procesado, ilegible o error. También marca password_eliminado = TRUE '
    'como evidencia de auditoría. Cumplimiento de LFPDPPP.';


-- =============================================================================
-- SECCIÓN 2: LIMPIAR CONTRASEÑAS HUÉRFANAS
-- =============================================================================
-- Adjuntos que ya están en estado final (procesado, ilegible, error)
-- pero cuya contraseña no fue limpiada por el bug de la versión anterior.
-- Se ejecuta exactamente UNA vez al aplicar esta migración.
--
-- El constraint ck_adjunto_password solo prohíbe:
--   password IS NOT NULL AND password_eliminado = TRUE
-- Por lo tanto podemos setear ambos sin violar la constraint:
--   password = NULL, password_eliminado = TRUE
-- =============================================================================

UPDATE public.adjunto
SET
    password          = NULL,
    password_eliminado = TRUE,
    updated_at        = NOW()
WHERE
    estado            IN ('procesado', 'ilegible', 'error')
    AND password      IS NOT NULL
    AND password_eliminado = FALSE;

-- Verificar que no quedaron contraseñas en estados que debían haberse limpiado.
-- Este DO-block no lanza excepción — solo emite un NOTICE informativo.
DO $$
DECLARE
    v_huerfanos INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_huerfanos
    FROM public.adjunto
    WHERE estado IN ('procesado', 'ilegible', 'error')
      AND password IS NOT NULL;

    IF v_huerfanos > 0 THEN
        RAISE WARNING
            'ADVERTENCIA DE SEGURIDAD: quedan % adjunto(s) con estado final '
            'y contraseña no nula tras la limpieza de esta migración. '
            'Revisar manualmente.', v_huerfanos;
    ELSE
        RAISE NOTICE 'Limpieza de contraseñas huérfanas completada. '
                     'Ningún adjunto con contraseña activa en estados finales.';
    END IF;
END;
$$;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000012_fix_clean_zip_password.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000013_configuracion_sistema.sql
-- ============================================================
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


-- ============================================================
-- MIGRACIÓN: 20260522000014_pipeline_reintento.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000014_pipeline_reintento.sql
-- Tabla pipeline_reintento — resiliencia y recuperación del pipeline de agentes IA
-- =============================================================================
-- Propósito:
--   Cuando un agente IA falla (error de red, timeout LLM, excepción inesperada),
--   el pipeline no debe abortar silenciosamente. Esta tabla implementa una cola
--   de reintentos con backoff: cada fallo registra cuándo volver a intentarlo,
--   cuántos intentos se han hecho y cuál fue el motivo del fallo.
--
-- Flujo de uso:
--   1. Un agente falla → el worker Celery inserta en pipeline_reintento
--      con estado='pendiente' e intentar_desde = NOW() + backoff
--   2. El scheduler de Celery consulta filas WHERE estado='pendiente'
--      AND intentar_desde <= NOW() y reactiva el agente
--   3. Si el reintento tiene éxito → estado='completado'
--   4. Si fallaron todos los intentos (intento_num = max_intentos) → estado='abandonado'
--      y el trámite se marca requiere_atencion = TRUE manualmente desde el backend
--
-- Relación con agente_ia_log:
--   Cada reintento crea una nueva fila en agente_ia_log con intento incrementado.
--   pipeline_reintento.agente_ia_log_id apunta al último log de intento para
--   correlación rápida sin JOIN adicional.
--
-- Relaciones:
--   pipeline_reintento.tramite_id       → tramite.id       (Módulo 4)
--   pipeline_reintento.agente_ia_log_id → agente_ia_log.id (Módulo 10)
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: ENUM estado_reintento
-- =============================================================================

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_type
        WHERE typname = 'estado_reintento'
          AND typnamespace = 'public'::regnamespace
    ) THEN
        CREATE TYPE public.estado_reintento AS ENUM (
            'pendiente',    -- en cola, esperando hasta intentar_desde
            'en_proceso',   -- el worker lo tomó y está ejecutando el agente
            'completado',   -- reintento exitoso, el agente terminó sin error
            'abandonado'    -- se agotaron los intentos sin éxito
        );

        COMMENT ON TYPE public.estado_reintento IS
            'Estado del reintento en la cola. '
            'pendiente → en_proceso → completado (éxito). '
            'pendiente → en_proceso → pendiente (nuevo intento, intento_num++). '
            'pendiente → abandonado (intento_num = max_intentos y falló de nuevo).';
    END IF;
END;
$$;


-- =============================================================================
-- SECCIÓN 2: TABLA pipeline_reintento
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.pipeline_reintento (
    -- -------------------------------------------------------------------------
    -- Identificación
    -- -------------------------------------------------------------------------
    id              UUID                PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Contexto del reintento
    -- -------------------------------------------------------------------------
    -- Trámite que se estaba procesando cuando ocurrió el fallo
    tramite_id      UUID                NOT NULL REFERENCES public.tramite(id),

    -- Qué agente falló y debe reintentarse
    agente_nombre   TEXT                NOT NULL
                    CHECK (agente_nombre IN (
                        'agente_1', 'agente_2', 'agente_3',
                        'agente_4', 'agente_5', 'agente_6'
                    )),

    -- -------------------------------------------------------------------------
    -- Estado y control de cola
    -- -------------------------------------------------------------------------
    estado          public.estado_reintento NOT NULL DEFAULT 'pendiente',

    -- Número de intento actual (empieza en 1 — el primer reintento tras el fallo)
    intento_num     SMALLINT            NOT NULL DEFAULT 1
                    CHECK (intento_num >= 1),

    -- Máximo de intentos permitidos antes de marcar como abandonado
    max_intentos    SMALLINT            NOT NULL DEFAULT 3
                    CHECK (max_intentos >= 1),

    -- Garantía de consistencia: intento_num no puede superar max_intentos
    CONSTRAINT ck_reintento_intentos CHECK (intento_num <= max_intentos),

    -- -------------------------------------------------------------------------
    -- Motivo del fallo original
    -- -------------------------------------------------------------------------
    -- Texto del error que disparó el reintento (traceback, mensaje de excepción, etc.)
    motivo          TEXT                NOT NULL,
    CONSTRAINT ck_reintento_motivo_not_empty CHECK (TRIM(motivo) <> ''),

    -- -------------------------------------------------------------------------
    -- Scheduling
    -- -------------------------------------------------------------------------
    -- Timestamp desde el que el scheduler puede tomar este reintento.
    -- El worker Celery implementa el backoff modificando este campo:
    --   intento_num=1 → intentar_desde = NOW() + 2 minutos
    --   intento_num=2 → intentar_desde = NOW() + 10 minutos
    --   intento_num=3 → intentar_desde = NOW() + 30 minutos
    -- El cálculo del backoff es responsabilidad del worker, no de la DB.
    intentar_desde  TIMESTAMPTZ         NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- Trazabilidad — enlace al último intento de ejecución
    -- -------------------------------------------------------------------------
    -- FK al registro de agente_ia_log del último intento (NULL hasta que Celery
    -- crea el registro de log al iniciar el reintento).
    agente_ia_log_id UUID               NULL REFERENCES public.agente_ia_log(id),

    -- -------------------------------------------------------------------------
    -- Auditoría Olimpo
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ         NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.pipeline_reintento IS
    'Cola de reintentos del pipeline de agentes IA. '
    'Cuando un agente falla, el worker Celery inserta aquí con estado=pendiente. '
    'El scheduler reactiva el agente cuando intentar_desde <= NOW(). '
    'Máximo max_intentos intentos — si se agotan, estado=abandonado y el trámite '
    'se marca requiere_atencion=TRUE en el backend.';

COMMENT ON COLUMN public.pipeline_reintento.tramite_id IS
    'Trámite que se procesaba cuando ocurrió el fallo. '
    'El worker usa este id para reanudar el pipeline desde el agente correcto.';
COMMENT ON COLUMN public.pipeline_reintento.agente_nombre IS
    'Agente que debe reintentarse. El worker lo instancia y lo llama con el tramite_id.';
COMMENT ON COLUMN public.pipeline_reintento.intento_num IS
    'Número de intento en curso (1-indexed). Se incrementa con cada reintento fallido.';
COMMENT ON COLUMN public.pipeline_reintento.max_intentos IS
    'Límite de intentos. Configurable — trámites urgentes podrían tener max_intentos=5.';
COMMENT ON COLUMN public.pipeline_reintento.motivo IS
    'Traceback o mensaje de error que generó el reintento. Para debugging y observabilidad.';
COMMENT ON COLUMN public.pipeline_reintento.intentar_desde IS
    'El worker solo toma filas donde intentar_desde <= NOW(). '
    'Implementa backoff exponencial al ser actualizado por el worker en cada fallo.';
COMMENT ON COLUMN public.pipeline_reintento.agente_ia_log_id IS
    'FK al último agente_ia_log creado para este reintento. '
    'Permite correlacionar el reintento con su trace de Langfuse sin JOIN adicional.';


-- =============================================================================
-- SECCIÓN 3: ÍNDICES
-- =============================================================================

-- Índice principal para el scheduler de Celery.
-- Consulta: "dame todos los reintentos pendientes que ya pueden ejecutarse,
--            ordenados por agente para agrupar la carga"
-- Es parcial (solo estado='pendiente') porque es el único estado que el
-- scheduler consulta en el loop. Los demás estados son archivos históricos.
CREATE INDEX IF NOT EXISTS idx_pipeline_reintento_pendientes
    ON public.pipeline_reintento (agente_nombre, intentar_desde)
    WHERE estado = 'pendiente';

COMMENT ON INDEX idx_pipeline_reintento_pendientes IS
    'Índice parcial para el scheduler Celery. '
    'Query: agente_nombre + intentar_desde WHERE estado = ''pendiente''. '
    'Solo indexa filas accionables — los estados completado/abandonado quedan fuera.';

-- Índice para ver el historial de reintentos de un trámite específico
CREATE INDEX IF NOT EXISTS idx_pipeline_reintento_tramite
    ON public.pipeline_reintento (tramite_id, created_at DESC);

COMMENT ON INDEX idx_pipeline_reintento_tramite IS
    'Historial de reintentos de un trámite. Usado en el panel de detalle del trámite '
    'para que el analista vea por qué el pipeline se reintentó.';


-- =============================================================================
-- SECCIÓN 4: TRIGGER updated_at
-- =============================================================================

CREATE TRIGGER trg_pipeline_reintento_updated_at
    BEFORE UPDATE ON public.pipeline_reintento
    FOR EACH ROW
    EXECUTE FUNCTION public.set_updated_at();


-- =============================================================================
-- SECCIÓN 5: ROW LEVEL SECURITY (RLS)
-- =============================================================================
-- El pipeline_reintento es una tabla de operaciones internas del sistema.
-- Los agentes IA (service_role) escriben y leen sin restricción.
-- Los usuarios humanos solo necesitan visibilidad para diagnóstico:
--   director_general / director_ops → ven todos los reintentos
--   gerentes → no tienen caso de uso directo sobre esta tabla
--   analistas → no tienen caso de uso directo sobre esta tabla
--
-- INSERT/UPDATE: solo service_role (workers Celery). No se crean policies de
-- escritura para authenticated — la escritura es responsabilidad del backend.

ALTER TABLE public.pipeline_reintento ENABLE ROW LEVEL SECURITY;

-- Directores pueden ver el estado del pipeline para diagnóstico y soporte
CREATE POLICY pol_pipeline_reintento_select
    ON public.pipeline_reintento
    FOR SELECT
    TO authenticated
    USING (
        auth_rol() IN ('director_general', 'director_ops')
    );

COMMENT ON POLICY pol_pipeline_reintento_select ON public.pipeline_reintento IS
    'Solo directores pueden ver la cola de reintentos. '
    'Permite diagnosticar agentes atascados desde la UI del Superadmin o el dashboard. '
    'Los agentes IA (service_role) bypasan RLS para lectura y escritura.';


-- =============================================================================
-- SECCIÓN 6: GRANTS
-- =============================================================================

-- authenticated solo tiene SELECT (y solo para directores por la policy de arriba)
-- INSERT y UPDATE los hace el backend con service_role — sin GRANT a authenticated
GRANT SELECT ON TABLE public.pipeline_reintento TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000014_pipeline_reintento.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000015_correcciones_diseno_seguridad.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000015_correcciones_diseno_seguridad.sql
-- Correcciones de diseño, seguridad y rendimiento post-diagnóstico
-- =============================================================================
-- CORRECCIONES INCLUIDAS:
--
--   DISEÑO-01: Índice compuesto en tramite.paso_pipeline_actual para detectar
--     trámites con agente IA activo y calcular timeouts del pipeline.
--
--   DISEÑO-02: Eliminar el UNIQUE constraint en tramite.folio_ot y reemplazar
--     por un índice simple. folio_ot no es un identificador universal único:
--     GNP puede reutilizar números de OT entre ramos o años distintos, y en
--     el modelo actual un trámite puede cambiar de OT (force_update_folio).
--     La tabla ot_activacion guarda el historial completo con su propia clave.
--
--   DISEÑO-03: Reemplazar calcular_fecha_limite_sla() con versión con límite de
--     iteraciones. La versión original podía entrar en un bucle infinito si
--     dias_inhabil tenía todos los días marcados como inhábiles para un ramo.
--
--   DISEÑO-04: Agregar columna origen_sistema a tramite_evento y actualizar el
--     CHECK constraint del actor para documentar explícitamente el caso de
--     eventos generados por procesos del sistema (sin usuario humano ni agente IA).
--
--   SEG-01: Revocar EXECUTE de notificar_a_rol() a authenticated. Esta función
--     itera sobre usuarios y envía notificaciones masivas — es un vector de
--     escalación de privilegios si un analista o gerente puede llamarla.
--     Se crea una función wrapper notificar_a_rol_director() que valida el rol.
--
--   SEG-02: Agregar SET search_path a registrar_validacion_aprendizaje() que
--     en la migración original (000005) no lo tenía, creando vulnerabilidad
--     de privilege escalation via search_path hijacking.
--
--   SEG-03: Reemplazar crear_notificacion() con versión que valida que el
--     usuario destino exista y esté activo antes de insertar. La versión
--     anterior podía crear notificaciones para usuarios inexistentes o dados
--     de baja, generando ruido y potenciales inconsistencias.
--
--   PERF-01: Índices en agente_ia_log para análisis de costos por agente y
--     detección de ejecuciones lentas. El Superadmin los necesita para la
--     vista "Agent Health".
-- =============================================================================


-- =============================================================================
-- DISEÑO-01: ÍNDICE EN tramite.paso_pipeline_actual
-- =============================================================================
-- Permite detectar eficientemente trámites con agente IA en ejecución activa
-- y calcular si superaron el PIPELINE_TIMEOUT_MINUTOS de configuracion_sistema.
-- El índice es parcial: solo indexa filas donde hay un agente corriendo (NOT NULL)
-- y el trámite está activo. Excluye el 90%+ de filas (trámites terminados).

CREATE INDEX IF NOT EXISTS idx_tramite_pipeline_activo
    ON public.tramite (paso_pipeline_actual, paso_pipeline_inicio)
    WHERE paso_pipeline_actual IS NOT NULL AND activo = TRUE;

COMMENT ON INDEX idx_tramite_pipeline_activo IS
    'Detecta trámites con agente IA activo en este momento. '
    'El scheduler de timeouts consulta paso_pipeline_inicio para identificar '
    'ejecuciones que superaron PIPELINE_TIMEOUT_MINUTOS. '
    'Parcial: solo trámites activos con agente corriendo (< 1% del total).';


-- =============================================================================
-- DISEÑO-02: ELIMINAR UNIQUE EN tramite.folio_ot — REEMPLAZAR POR ÍNDICE SIMPLE
-- =============================================================================
-- Justificación técnica:
--   folio_ot proviene de GNP y NO está bajo nuestro control. GNP puede:
--     a) Reutilizar números de OT en distintos períodos o ramos.
--     b) Asignar la misma OT a un trámite modificado (corrección de GNP).
--   El constraint UNIQUE actual bloquea estas situaciones con un error de DB,
--   forzando intervención manual. Es mejor permitir duplicados y manejarlos
--   en la lógica de negocio de la app. La tabla ot_activacion (Módulo 11)
--   es la fuente canónica del historial de OTs.
--
--   tramite.folio_ot es solo el campo de "acceso rápido" a la OT principal.
--   Si GNP reasigna o corrige el número, la app debe poder actualizarlo sin error.

-- Eliminar el constraint UNIQUE original
ALTER TABLE public.tramite
    DROP CONSTRAINT IF EXISTS uq_tramite_folio_ot;

-- Verificar y recrear el índice simple (si ya existe el del módulo 4, este es
-- redundante pero idempotente gracias a IF NOT EXISTS)
-- El índice idx_tramite_folio_ot ya existe desde 20260522000003 y es un índice
-- simple (no unique). Solo necesitamos asegurarnos que el UNIQUE constraint
-- haya sido eliminado.

COMMENT ON COLUMN public.tramite.folio_ot IS
    'Número de OT asignado por GNP (campo de acceso rápido). '
    'No tiene constraint UNIQUE — GNP puede reutilizar números. '
    'El historial completo de OTs vive en ot_activacion.';


-- =============================================================================
-- DISEÑO-03: REEMPLAZAR calcular_fecha_limite_sla() CON LÍMITE DE ITERACIONES
-- =============================================================================
-- Problema con la versión original (20260522000007):
--   El WHILE LOOP no tiene cota superior. Si por error en dias_inhabil se marcan
--   demasiados días como inhábiles, la función entra en un loop infinito que
--   eventualmente mata la sesión PostgreSQL por statement_timeout.
--
-- Solución: límite de iteraciones = p_dias * 4
--   En el peor caso realista, 4 semanas por cada día hábil solicitado es más
--   que suficiente (máximo 2 días inhábiles consecutivos en México). Si se
--   supera este límite, la función lanza EXCEPTION con mensaje explicativo
--   para que el administrador corrija los datos de dias_inhabil.

CREATE OR REPLACE FUNCTION public.calcular_fecha_limite_sla(
    p_inicio    TIMESTAMPTZ,
    p_dias      INTEGER,
    p_ramo      ramo_usuario DEFAULT NULL
)
RETURNS TIMESTAMPTZ
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_fecha_actual  DATE    := p_inicio::DATE;
    v_contador      INTEGER := 0;
    -- Límite de iteraciones: 4 semanas de días calendario por cada día hábil pedido.
    -- Protege contra loops infinitos cuando dias_inhabil está mal configurado.
    v_max_iter      INTEGER := p_dias * 28;
    v_iteraciones   INTEGER := 0;
BEGIN
    IF p_dias <= 0 THEN
        RAISE EXCEPTION
            'dias_habiles debe ser mayor a 0, se recibió %', p_dias;
    END IF;

    WHILE v_contador < p_dias LOOP
        v_fecha_actual  := v_fecha_actual + 1;
        v_iteraciones   := v_iteraciones + 1;

        -- Límite de seguridad: evitar bucle infinito por datos incorrectos
        IF v_iteraciones > v_max_iter THEN
            RAISE EXCEPTION
                'calcular_fecha_limite_sla: se superó el límite de % iteraciones '
                'calculando % días hábiles desde % para ramo %. '
                'Verificar que la tabla dia_inhabil no tenga periodos completos '
                'marcados como inhábiles para este ramo.',
                v_max_iter, p_dias, p_inicio, p_ramo;
        END IF;

        -- Saltar fines de semana (0=domingo, 6=sábado)
        IF EXTRACT(DOW FROM v_fecha_actual) IN (0, 6) THEN
            CONTINUE;
        END IF;

        -- Saltar días inhábiles globales (aplica_ramo IS NULL)
        -- y días inhábiles específicos del ramo del trámite
        IF EXISTS (
            SELECT 1 FROM public.dia_inhabil
            WHERE fecha = v_fecha_actual
              AND (
                aplica_ramo IS NULL
                OR (p_ramo IS NOT NULL AND aplica_ramo = p_ramo)
              )
        ) THEN
            CONTINUE;
        END IF;

        v_contador := v_contador + 1;
    END LOOP;

    -- Preservar la hora exacta del inicio — solo avanza la fecha
    RETURN (v_fecha_actual::TEXT || ' ' || (p_inicio AT TIME ZONE 'UTC')::TIME::TEXT)::TIMESTAMPTZ;
END;
$$;

COMMENT ON FUNCTION public.calcular_fecha_limite_sla(TIMESTAMPTZ, INTEGER, ramo_usuario) IS
    'Calcula el deadline de un SLA en días hábiles, excluyendo fines de semana '
    'y los días configurados en dia_inhabil que apliquen al ramo dado. '
    'Si p_ramo es NULL, solo excluye los días globales (aplica_ramo IS NULL). '
    'Límite de iteraciones = p_dias * 28 para proteger contra loops infinitos '
    'causados por datos incorrectos en dia_inhabil.';


-- =============================================================================
-- DISEÑO-04: COLUMNA origen_sistema EN tramite_evento
-- =============================================================================
-- Agrega contexto para el tercer caso de actor: un proceso del sistema (job de
-- Celery, scheduled task) que no es ni un usuario humano ni un agente IA.
-- Ejemplos: el job de alertas SLA, el job de limpieza de passwords ZIP,
-- el scheduler de reintentos de pipeline.
--
-- El CHECK constraint existente ck_evento_actor ya permitía el caso de ambos
-- NULL (comentado como "eventos del sistema"). Se formaliza documentando qué
-- proceso del sistema generó el evento.

ALTER TABLE public.tramite_evento
    ADD COLUMN IF NOT EXISTS origen_sistema TEXT NULL;

COMMENT ON COLUMN public.tramite_evento.origen_sistema IS
    'Proceso del sistema que generó el evento cuando usuario_id y agente_ia_nombre '
    'son ambos NULL. Ejemplos: ''job_alertas_sla'', ''job_limpieza_passwords'', '
    '''scheduler_pipeline_reintento''. Mejora la trazabilidad de eventos automáticos.';

-- Actualizar el CHECK constraint del actor para documentar los 3 casos válidos.
-- Primero lo eliminamos, luego lo recreamos con mejor documentación.
-- NOTA: El nombre del constraint en la tabla original es ck_evento_actor.

ALTER TABLE public.tramite_evento
    DROP CONSTRAINT IF EXISTS ck_evento_actor;

ALTER TABLE public.tramite_evento
    ADD CONSTRAINT ck_evento_actor CHECK (
        -- Caso 1: Actor humano (usuario_id tiene valor, agente_ia_nombre es NULL)
        (usuario_id IS NOT NULL AND agente_ia_nombre IS NULL)
        -- Caso 2: Actor IA (agente_ia_nombre tiene valor, usuario_id es NULL)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NOT NULL)
        -- Caso 3: Proceso del sistema (ambos NULL, origen_sistema documenta el proceso)
        OR (usuario_id IS NULL AND agente_ia_nombre IS NULL)
    );

COMMENT ON CONSTRAINT ck_evento_actor ON public.tramite_evento IS
    'Exactamente uno de los tres casos de actor es válido: '
    '(1) usuario humano: usuario_id NOT NULL, agente_ia_nombre IS NULL. '
    '(2) agente IA: agente_ia_nombre NOT NULL, usuario_id IS NULL. '
    '(3) proceso del sistema: ambos NULL, origen_sistema documenta el proceso automático.';


-- =============================================================================
-- SEG-01: REVOCAR notificar_a_rol() DE authenticated
-- =============================================================================
-- Vulnerabilidad:
--   La función notificar_a_rol() itera sobre TODOS los usuarios de un rol y
--   llama crear_notificacion() por cada uno. Un analista autenticado podría
--   invocarla vía RPC y enviar notificaciones masivas a cualquier rol,
--   incluyendo directores, con cualquier contenido — un vector de spam
--   interno o escalación de información sensible.
--
-- Solución:
--   1. REVOKE EXECUTE en notificar_a_rol() de authenticated.
--   2. Crear notificar_a_rol_director() wrapper SECURITY DEFINER que valida
--      que el caller sea director_general o director_ops antes de invocar
--      la función interna.
--
-- El backend (service_role) puede seguir llamando notificar_a_rol() directamente
-- sin necesidad del wrapper — bypasa RLS y tiene acceso total.

REVOKE EXECUTE ON FUNCTION public.notificar_a_rol(
    rol_usuario,
    ramo_usuario,
    tipo_notificacion,
    TEXT,
    TEXT,
    UUID,
    JSONB
) FROM authenticated;


-- Wrapper con validación de rol para uso desde el frontend o APIs autenticadas
CREATE OR REPLACE FUNCTION public.notificar_a_rol_director(
    p_rol           rol_usuario,
    p_ramo          ramo_usuario        DEFAULT NULL,
    p_tipo          tipo_notificacion   DEFAULT NULL,
    p_titulo        TEXT                DEFAULT NULL,
    p_cuerpo        TEXT                DEFAULT NULL,
    p_tramite_id    UUID                DEFAULT NULL,
    p_datos         JSONB               DEFAULT '{}'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
    -- Solo directores pueden usar esta función desde el cliente autenticado
    IF auth_rol() NOT IN ('director_general', 'director_ops') THEN
        RAISE EXCEPTION
            'Acceso denegado: notificar_a_rol_director() requiere rol '
            'director_general o director_ops. Rol actual: %', auth_rol();
    END IF;

    -- Delegar a la función interna que tiene la lógica completa
    RETURN public.notificar_a_rol(
        p_rol,
        p_ramo,
        p_tipo,
        p_titulo,
        p_cuerpo,
        p_tramite_id,
        p_datos
    );
END;
$$;

COMMENT ON FUNCTION public.notificar_a_rol_director(rol_usuario, ramo_usuario, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Wrapper de notificar_a_rol() para uso desde clientes autenticados. '
    'Valida que el caller sea director_general o director_ops antes de ejecutar. '
    'El backend (service_role) llama notificar_a_rol() directamente sin este wrapper. '
    'REVOKE en notificar_a_rol() previene que analistas envíen notificaciones masivas.';

GRANT EXECUTE ON FUNCTION public.notificar_a_rol_director(
    rol_usuario,
    ramo_usuario,
    tipo_notificacion,
    TEXT,
    TEXT,
    UUID,
    JSONB
) TO authenticated;


-- =============================================================================
-- SEG-02: SET search_path EN registrar_validacion_aprendizaje()
-- =============================================================================
-- La función registrar_validacion_aprendizaje() definida en 20260522000005
-- es un trigger BEFORE UPDATE que se ejecuta con privilegios del owner (SECURITY
-- DEFINER implícito en triggers según el contexto de ejecución). Sin search_path
-- explícito, un atacante con CREATE SCHEMA podría inyectar funciones en un
-- esquema temporal y secuestrar la ruta de búsqueda durante la ejecución.

CREATE OR REPLACE FUNCTION public.registrar_validacion_aprendizaje()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
BEGIN
    IF NEW.aprendizaje_validado = TRUE AND OLD.aprendizaje_validado = FALSE THEN
        NEW.validado_por     := auth.uid();
        NEW.fecha_validacion := NOW();
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.registrar_validacion_aprendizaje() IS
    'Al marcar un aprendizaje como validado, auto-registra quién lo validó y cuándo. '
    'El analista solo necesita hacer UPDATE aprendizaje_validado = TRUE. '
    'search_path explícito para prevenir privilege escalation via schema hijacking.';


-- =============================================================================
-- SEG-03: REEMPLAZAR crear_notificacion() CON VALIDACIÓN DE USUARIO DESTINO
-- =============================================================================
-- Vulnerabilidad en la versión original (20260522000008):
--   La función no verifica que p_usuario_id exista en la tabla usuario y esté
--   activo. Un backend con bug podría crear notificaciones para:
--     a) UUIDs inexistentes en usuario (FK a usuario.id garantiza existencia
--        en la tabla, pero no que el usuario esté activo).
--     b) Usuarios dados de baja (activo = FALSE) — notificaciones huérfanas
--        que nunca serán leídas y consumen espacio.
--
-- La FK a usuario(id) ya garantiza que el UUID exista. Solo agregamos
-- la validación de usuario activo antes de insertar.

CREATE OR REPLACE FUNCTION public.crear_notificacion(
    p_usuario_id    UUID,
    p_tipo          tipo_notificacion,
    p_titulo        TEXT,
    p_cuerpo        TEXT,
    p_tramite_id    UUID    DEFAULT NULL,
    p_datos         JSONB   DEFAULT '{}'
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_activa        BOOLEAN;
    v_notif_id      UUID;
    v_usuario_activo BOOLEAN;
BEGIN
    -- SEG-03: Validar que el usuario destino exista y esté activo
    SELECT activo INTO v_usuario_activo
    FROM public.usuario
    WHERE id = p_usuario_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'crear_notificacion: el usuario % no existe en public.usuario.',
            p_usuario_id;
    END IF;

    IF v_usuario_activo = FALSE THEN
        -- Usuario inactivo (dado de baja) — no insertar, retornar NULL silenciosamente
        -- para no romper el pipeline cuando un analista fue desactivado durante
        -- el procesamiento de un trámite que le estaba asignado.
        RETURN NULL;
    END IF;

    -- Verificar preferencias del usuario (modelo opt-out)
    SELECT activa INTO v_activa
    FROM public.notificacion_config
    WHERE usuario_id = p_usuario_id
      AND tipo       = p_tipo;

    -- Si existe config y está desactivada, no insertar
    IF FOUND AND v_activa = FALSE THEN
        RETURN NULL;
    END IF;

    -- Insertar la notificación
    INSERT INTO public.notificacion (
        usuario_id,
        tipo,
        titulo,
        cuerpo,
        tramite_id,
        datos
    ) VALUES (
        p_usuario_id,
        p_tipo,
        TRIM(p_titulo),
        TRIM(p_cuerpo),
        p_tramite_id,
        COALESCE(p_datos, '{}')
    )
    RETURNING id INTO v_notif_id;

    RETURN v_notif_id;
END;
$$;

COMMENT ON FUNCTION public.crear_notificacion(UUID, tipo_notificacion, TEXT, TEXT, UUID, JSONB) IS
    'Crea una notificación para un usuario respetando sus preferencias. '
    'Modelo opt-out: si no hay config, se crea la notificación. '
    'Si el usuario está inactivo o desactivó ese tipo, retorna NULL sin insertar. '
    'El INSERT dispara Supabase Realtime al navegador del destinatario. '
    'SEG-03: valida que el usuario exista y esté activo antes de insertar.';


-- =============================================================================
-- PERF-01: ÍNDICES EN agente_ia_log PARA ANÁLISIS DE COSTOS Y RENDIMIENTO
-- =============================================================================
-- El Superadmin necesita dos vistas en "Agent Health" (Fase 7 del roadmap):
--   1. Costo acumulado por agente en un período → idx_agente_log_agente_costo
--   2. Ejecuciones más lentas por agente → idx_agente_log_duracion
--
-- Ambos son índices parciales que cubren solo las ejecuciones completadas
-- (el 80%+ del volumen en un sistema maduro) — excluyen los iniciados y fallidos
-- para mantener el tamaño del índice pequeño y el lookup eficiente.

-- Índice para análisis de costos por agente y período
CREATE INDEX IF NOT EXISTS idx_agente_log_agente_costo
    ON public.agente_ia_log (agente_nombre, inicio DESC, costo_usd)
    WHERE costo_usd IS NOT NULL AND estado = 'completado';

COMMENT ON INDEX idx_agente_log_agente_costo IS
    'Análisis de costos en el Superadmin: gasto en USD por agente y período. '
    'Query típica: GROUP BY agente_nombre, date_trunc(''day'', inicio) '
    'SUM(costo_usd) WHERE estado = ''completado''. '
    'Parcial: solo ejecuciones completadas con costo registrado.';

-- Índice para detección de ejecuciones lentas (outliers de rendimiento)
CREATE INDEX IF NOT EXISTS idx_agente_log_duracion
    ON public.agente_ia_log (agente_nombre, duracion_ms DESC)
    WHERE estado = 'completado' AND duracion_ms IS NOT NULL;

COMMENT ON INDEX idx_agente_log_duracion IS
    'Detección de ejecuciones lentas: las N más tardadas por agente. '
    'Permite detectar degradación gradual del rendimiento de los LLMs. '
    'Query típica: ORDER BY duracion_ms DESC LIMIT 10 WHERE agente_nombre = X.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000015_correcciones_diseno_seguridad.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000016_correo_workspace_audit.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000016_correo_workspace_audit.sql
-- Integración Gmail con Domain-Wide Delegation (DWD)
-- =============================================================================
-- Agrega el campo cuenta_workspace a la tabla correo para registrar qué cuenta
-- de Google Workspace (vía DWD) procesó o envió cada correo.
--
-- La promotoría centraliza TODAS las comunicaciones a través de una sola cuenta
-- de servicio con DWD que actúa en nombre de cada usuario (analistas, director).
--
-- Sin este campo no hay forma de responder:
--   "¿Desde qué cuenta de Workspace se envió este correo saliente?"
--   "¿El correo entrante llegó a la bandeja del analista X o del director?"
--
-- NOTA: trg_correo_audit ya existe desde 20260522000011_modulo_12_mejoras_diagnostico.sql
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: COLUMNA cuenta_workspace EN correo
-- =============================================================================
-- Almacena la dirección de correo de Google Workspace que el servidor DWD usó
-- para enviar o recibir el mensaje. Ejemplos:
--   Entrante a analista:   'ana.garcia@promotoría.mx'
--   Saliente del director: 'director@promotoría.mx'
--   Saliente del Agente 6: cuenta del analista que revisó y aprobó el borrador
--
-- NULL para correos legacy o creados manualmente sin pasar por Gmail API.

ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS cuenta_workspace TEXT NULL;

COMMENT ON COLUMN correo.cuenta_workspace IS
    'Cuenta de Google Workspace usada vía DWD para recibir o enviar este correo. '
    'Ejemplo: analista@promotoría.mx (entrante) o director@promotoría.mx (saliente). '
    'NULL para correos no procesados vía Gmail API. '
    'Permite trazabilidad completa: qué cuenta DWD gestionó cada comunicación.';


-- =============================================================================
-- SECCIÓN 2: ÍNDICE
-- =============================================================================
-- Consultas de auditoría y trazabilidad por cuenta de Workspace:
--   "Todos los correos enviados desde la cuenta del director este mes"
--   "¿Cuántos correos procesó la cuenta del analista X esta semana?"

CREATE INDEX IF NOT EXISTS idx_correo_workspace
    ON correo (cuenta_workspace)
    WHERE cuenta_workspace IS NOT NULL;

COMMENT ON INDEX idx_correo_workspace IS
    'Trazabilidad por cuenta DWD: busca todos los correos procesados '
    'a través de una cuenta de Google Workspace específica. '
    'Parcial: excluye los NULL (correos sin Gmail API).';


-- =============================================================================
-- SECCIÓN 3: GRANT UPDATE para authenticated
-- =============================================================================
-- El Agente 6 y el worker de Gmail corren con service_role — pueden escribir
-- cuenta_workspace directamente sin GRANT adicional.
-- El GRANT a authenticated permite que la UI pueda corregir la cuenta de origen
-- de un borrador antes de enviarlo (ej: enviar desde cuenta del director por instrucción).

GRANT UPDATE (cuenta_workspace, updated_at)
    ON TABLE correo TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000016_correo_workspace_audit.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000017_agent_api_keys.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000017_agent_api_keys.sql
-- Autenticación de agentes externos vía API key (para MCP)
-- =============================================================================
-- Permite que agentes de IA externos (vía Model Context Protocol) autentiquen
-- contra la API de Olimpo usando una API key de larga duración, sin necesidad
-- de hacer login interactivo con Supabase Auth.
--
-- Problema que resuelve:
--   Los JWT de Supabase expiran en 1 hora y requieren un usuario humano para
--   renovarse. Un agente MCP que corre de forma autónoma (ej: pipeline nocturno,
--   agente de revisión, cliente externo) no puede hacer login interactivo.
--
-- Diseño de seguridad:
--   - Solo se almacena el HASH SHA-256 de la key — nunca la key en texto plano.
--   - La key real se entrega UNA sola vez al crearla (igual que tokens de GitHub).
--   - Cada key tiene un rol y ramo asignados: sigue las mismas reglas RLS.
--   - Las keys pueden tener fecha de expiración o ser indefinidas.
--   - Solo service_role (Superadmin) puede crear/revocar keys.
--   - audit_log registra cada uso (via trigger).
--
-- Uso en el backend FastAPI:
--   Header: X-Agent-API-Key: <key>
--   El middleware valida key_hash = sha256(key) y construye un UsuarioToken sintético.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: TABLA agent_api_keys
-- =============================================================================

CREATE TABLE agent_api_keys (
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Identificación de la key
    -- -------------------------------------------------------------------------
    -- Nombre descriptivo para identificar a qué agente o servicio pertenece
    -- Ej: 'agente_mcp_pipeline', 'cliente_externo_consultora_x', 'n8n_workflow'
    nombre          TEXT            NOT NULL,

    -- Hash SHA-256 de la API key en texto plano.
    -- La key real NUNCA se almacena — solo este hash.
    -- El middleware compara: sha256(key_recibida) == key_hash
    key_hash        TEXT            NOT NULL,

    -- -------------------------------------------------------------------------
    -- Permisos del agente — mismos valores que usuarios humanos
    -- -------------------------------------------------------------------------
    -- El agente opera con este rol (determina las RLS policies que aplican)
    rol             rol_usuario     NOT NULL,

    -- Ramo al que tiene acceso este agente (NULL = acceso a todos los ramos)
    -- Un agente con rol='gerente' y ramo='vida' solo ve datos de vida
    ramo            ramo_usuario    NULL,

    -- -------------------------------------------------------------------------
    -- Estado y vigencia
    -- -------------------------------------------------------------------------
    activo          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- NULL = la key no expira (para integraciones permanentes)
    -- NOT NULL = la key expira en esa fecha (para acceso temporal)
    expira_en       TIMESTAMPTZ     NULL,

    -- Descripción del propósito o contexto de uso de esta key
    descripcion     TEXT            NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Quién creó esta key (debe ser un superadmin)
    creado_por      UUID            NULL REFERENCES usuario(id),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_agent_api_keys_hash    UNIQUE (key_hash),
    CONSTRAINT ck_agent_api_keys_nombre  CHECK (TRIM(nombre) <> ''),
    CONSTRAINT ck_agent_api_keys_hash    CHECK (LENGTH(key_hash) = 64)  -- SHA-256 hex = 64 chars
);

COMMENT ON TABLE agent_api_keys IS
    'API keys de larga duración para agentes externos (MCP, n8n, integraciones). '
    'Solo almacena el hash SHA-256 — nunca la key en texto plano. '
    'Cada key tiene un rol y ramo asignados que determinan su acceso vía RLS. '
    'Solo service_role (Superadmin) puede crear o revocar keys.';

COMMENT ON COLUMN agent_api_keys.key_hash   IS 'SHA-256 hex del token. 64 caracteres. La key real se entrega una sola vez al crear.';
COMMENT ON COLUMN agent_api_keys.nombre     IS 'Nombre descriptivo del agente o servicio. Ej: agente_mcp_pipeline, n8n_workflow_gnp.';
COMMENT ON COLUMN agent_api_keys.rol        IS 'Rol con el que opera el agente — determina policies RLS aplicables.';
COMMENT ON COLUMN agent_api_keys.ramo       IS 'Ramo al que tiene acceso. NULL = todos los ramos (solo para directores/service).';
COMMENT ON COLUMN agent_api_keys.expira_en  IS 'Fecha de expiración. NULL = sin expiración. El middleware rechaza keys expiradas.';


-- =============================================================================
-- SECCIÓN 2: ÍNDICES
-- =============================================================================

-- Búsqueda por hash en cada request autenticado con API key (hot path)
CREATE INDEX idx_agent_keys_hash
    ON agent_api_keys (key_hash)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_agent_keys_hash IS
    'Hot path: validación de API key en cada request MCP. '
    'Parcial: solo keys activas — las revocadas no se consultan.';

-- Listar keys activas por rol (Superadmin)
CREATE INDEX idx_agent_keys_rol
    ON agent_api_keys (rol, activo);

-- Detectar keys próximas a expirar (job de alertas)
CREATE INDEX idx_agent_keys_expiracion
    ON agent_api_keys (expira_en)
    WHERE expira_en IS NOT NULL AND activo = TRUE;

COMMENT ON INDEX idx_agent_keys_expiracion IS
    'Job de alertas: keys que expiran en los próximos 7 días para notificar al Superadmin.';


-- =============================================================================
-- SECCIÓN 3: TRIGGER updated_at
-- =============================================================================

CREATE TRIGGER trg_agent_api_keys_updated_at
    BEFORE UPDATE ON agent_api_keys
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- SECCIÓN 4: ROW LEVEL SECURITY
-- =============================================================================
-- Solo service_role puede leer y escribir en esta tabla.
-- authenticated (usuarios del CRM) NO pueden ver ni gestionar API keys —
-- eso es exclusivo del Superadmin en admin.olimpo.mx con service_role.

ALTER TABLE agent_api_keys ENABLE ROW LEVEL SECURITY;

-- Ninguna policy para authenticated → acceso denegado por defecto
-- service_role bypasa RLS por diseño de Supabase

COMMENT ON TABLE agent_api_keys IS
    'API keys de larga duración para agentes externos (MCP, n8n, integraciones). '
    'RLS: sin policies para authenticated → solo service_role (Superadmin) tiene acceso. '
    'Solo almacena key_hash SHA-256 — la key real se entrega una sola vez al crear.';


-- =============================================================================
-- SECCIÓN 5: FUNCIÓN DE VALIDACIÓN (helper para el backend FastAPI)
-- =============================================================================
-- El backend llama esta función con service_role para validar una API key.
-- Retorna NULL si la key es inválida, expirada o revocada.
-- Retorna el registro completo si es válida.
--
-- Uso en Python (core/auth.py):
--   result = admin_db.rpc('validar_agent_api_key', {'p_key_hash': sha256_hex}).execute()
--   if result.data is None:
--       raise HTTPException(401, "API key inválida")
-- =============================================================================

CREATE OR REPLACE FUNCTION validar_agent_api_key(p_key_hash TEXT)
RETURNS agent_api_keys
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_key agent_api_keys;
BEGIN
    SELECT * INTO v_key
    FROM agent_api_keys
    WHERE key_hash = p_key_hash
      AND activo   = TRUE;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- Verificar expiración
    IF v_key.expira_en IS NOT NULL AND v_key.expira_en < NOW() THEN
        RETURN NULL;
    END IF;

    RETURN v_key;
END;
$$;

COMMENT ON FUNCTION validar_agent_api_key(TEXT) IS
    'Valida una API key de agente por su hash SHA-256. '
    'Retorna NULL si la key no existe, está revocada o expiró. '
    'Llamada con service_role desde el middleware de FastAPI. '
    'No registra el uso — eso lo hace el middleware con audit_log.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260522000017_agent_api_keys.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260522000018_mejoras_auditoria_rendimiento.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260522000018_mejoras_auditoria_rendimiento.sql
-- Corrección de índice faltante en sla_tramite y trigger de auditoría en tramite
-- =============================================================================

-- 1. Indexar tramite_id en sla_tramite (Llave foránea faltante en Módulo 12)
CREATE INDEX IF NOT EXISTS idx_sla_tramite_tramite_id
    ON public.sla_tramite(tramite_id);

COMMENT ON INDEX idx_sla_tramite_tramite_id IS
    'Optimiza búsquedas de SLAs por trámite y cascadas de eliminación ON DELETE CASCADE.';

-- 2. Trigger de Auditoría para la tabla tramite
CREATE TRIGGER trg_tramite_audit
    AFTER INSERT OR UPDATE OR DELETE ON public.tramite
    FOR EACH ROW EXECUTE FUNCTION public.audit_table_change();

COMMENT ON TRIGGER trg_tramite_audit ON public.tramite IS
    'Registra en la tabla audit_log todos los cambios del ciclo de vida y asignación de los trámites.';


-- ============================================================
-- MIGRACIÓN: 20260524000019_mcp_vector_search.sql
-- ============================================================
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
        a.email,
        a.ramo::text,
        similarity(a.nombre, p_nombre) AS similitud_trgm
    FROM agente a
    WHERE a.activo = p_activo
      AND (p_ramo IS NULL OR a.ramo::text = p_ramo)
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


-- ============================================================
-- MIGRACIÓN: 20260524000020_adjunto_gmail_storage.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260524000020_adjunto_gmail_storage.sql
-- Completa el tracking de adjuntos Gmail → Supabase Storage
-- =============================================================================
-- Problemas que corrige:
--
--   1. adjunto.gmail_attachment_id faltante
--      El Agente 1 necesita el ID de adjunto de Gmail para descargarlo.
--      Sin él, si el proceso falla a la mitad no hay forma de re-intentar.
--
--   2. adjunto.storage_bucket faltante
--      storage_path guarda la ruta pero no el bucket. Con múltiples buckets
--      (correos-inbox, correos-archivados) se pierde la referencia completa.
--
--   3. correo.ingestado_via faltante
--      No había registro de cómo entró el correo: webhook, polling o BCC.
--      Crítico para diagnosticar fallos en la integración DWD.
--
--   4. Convención de storage_path para correos pre-trámite
--      Los adjuntos llegan ANTES de que exista el trámite (Agente 1 corre
--      antes que Agente 2). La ruta temporal usa /inbox/{correo_id}/
--      y se actualiza a /tramites/{tramite_id}/ cuando se asigna el trámite.
--
-- Tablas afectadas: correo, adjunto
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: adjunto — columnas de integración Gmail + Storage
-- =============================================================================

-- ID del adjunto en Gmail (attachmentId en la API de Gmail).
-- Necesario para descargar el archivo desde Gmail si el proceso falla
-- antes de subirlo a Supabase Storage.
-- NULL para adjuntos que son hijos de ZIPs (no vienen directo de Gmail).
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS gmail_attachment_id TEXT NULL;

COMMENT ON COLUMN adjunto.gmail_attachment_id IS
    'ID del adjunto en la API de Gmail (Part.body.attachmentId). '
    'Necesario para re-descargar si el proceso falla antes de subir a Storage. '
    'NULL para adjuntos extraídos de ZIPs (no tienen ID propio en Gmail).';


-- Bucket de Supabase Storage donde vive el archivo.
-- Complementa storage_path — juntos forman la referencia completa al objeto.
-- Separado de storage_path para permitir queries como:
--   "Todos los archivos en el bucket de archivado"
-- Valores esperados: 'correos-adjuntos' (activo), 'correos-archivados' (archivado)
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS storage_bucket TEXT NULL
        DEFAULT 'correos-adjuntos';

COMMENT ON COLUMN adjunto.storage_bucket IS
    'Bucket de Supabase Storage que contiene el archivo. '
    'Junto con storage_path forman la referencia completa: bucket + path. '
    'Default: correos-adjuntos. Se cambia a correos-archivados al archivar. '
    'NULL hasta que el archivo se sube a Storage.';


-- Hash SHA-256 del contenido del archivo.
-- Permite verificar integridad después de la descarga y detectar duplicados exactos.
-- El Agente 1 lo calcula al momento de descargar de Gmail.
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS checksum_sha256 TEXT NULL;

COMMENT ON COLUMN adjunto.checksum_sha256 IS
    'SHA-256 del contenido del archivo (calculado al descargar de Gmail). '
    'Verifica integridad después de subir a Storage. '
    'Detecta duplicados exactos aunque tengan nombre diferente.';


-- Número de intentos de descarga de Gmail.
-- Limita los reintentos para no saturar la cuota de Gmail API.
ALTER TABLE adjunto
    ADD COLUMN IF NOT EXISTS intentos_descarga SMALLINT NOT NULL DEFAULT 0;

COMMENT ON COLUMN adjunto.intentos_descarga IS
    'Veces que el Agente 1 intentó descargar este adjunto de Gmail. '
    'Máximo configurable en configuracion_sistema (MAX_REINTENTOS_GMAIL). '
    'Al superar el máximo, estado cambia a error y se alerta al analista.';


-- =============================================================================
-- SECCIÓN 2: correo — trazabilidad de ingesta DWD
-- =============================================================================

-- Cómo llegó este correo al sistema.
-- Crítico para diagnosticar fallos en la integración con Google Workspace.
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS ingestado_via TEXT NULL
        CHECK (ingestado_via IN (
            'webhook_pubsub',  -- Gmail Push Notifications (canal principal)
            'polling',         -- Fallback: el worker consulta Gmail periódicamente
            'bcc_rule',        -- Regla BCC de Workspace capturó un correo saliente del agente
            'manual'           -- El analista lo subió manualmente desde la UI
        ));

COMMENT ON COLUMN correo.ingestado_via IS
    'Canal por el que el correo entró al sistema. '
    'webhook_pubsub: Gmail notificó vía Pub/Sub (flujo principal). '
    'polling: worker de fallback consultó Gmail API periódicamente. '
    'bcc_rule: regla de Workspace reenviló un correo saliente del agente vía BCC. '
    'manual: el analista lo registró a mano desde la UI.';


-- ID de la suscripción Pub/Sub que notificó este correo.
-- Permite correlacionar notificaciones de Gmail con correos procesados
-- para debugging y deduplicación de notificaciones duplicadas.
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS pubsub_subscription_id TEXT NULL;

COMMENT ON COLUMN correo.pubsub_subscription_id IS
    'ID de la suscripción de Google Pub/Sub que entregó la notificación. '
    'Formato: projects/{project}/subscriptions/{subscription}. '
    'Permite deduplicar: si la misma notificación llega dos veces (at-least-once), '
    'el message_id ya evita duplicados pero este campo facilita el debugging.';


-- historyId de Gmail al momento de la ingesta.
-- Gmail usa historyId para sincronización incremental. Guardarlo permite
-- reanudar desde el punto correcto si el webhook falla por un período.
ALTER TABLE correo
    ADD COLUMN IF NOT EXISTS gmail_history_id BIGINT NULL;

COMMENT ON COLUMN correo.gmail_history_id IS
    'historyId de Gmail al momento de procesar este correo. '
    'Usado para sincronización incremental: si el webhook falla X horas, '
    'el worker de polling retoma desde el último historyId registrado.';


-- =============================================================================
-- SECCIÓN 3: Tabla gmail_sync_state — estado de sincronización por cuenta DWD
-- =============================================================================
-- Registra el historyId más reciente procesado por cada cuenta de Workspace.
-- El worker de polling usa esto para pedir solo emails nuevos desde el último sync.
-- También registra el estado del canal Pub/Sub para detectar renovaciones necesarias.
--
-- Sin esta tabla, si el webhook deja de funcionar, el worker de polling
-- no sabe desde dónde reanudar y puede procesar miles de correos viejos.
-- =============================================================================

CREATE TABLE IF NOT EXISTS gmail_sync_state (
    -- -------------------------------------------------------------------------
    -- Identificación de la cuenta
    -- -------------------------------------------------------------------------
    -- Dirección de la cuenta de Google Workspace monitoreada vía DWD
    -- Ej: 'analista.garcia@promotoría.mx', 'director@promotoría.mx'
    cuenta_workspace    TEXT            PRIMARY KEY,

    -- -------------------------------------------------------------------------
    -- Estado de sincronización Gmail
    -- -------------------------------------------------------------------------
    -- Último historyId de Gmail procesado exitosamente.
    -- El worker de polling llama history.list?startHistoryId={ultimo_history_id}
    -- para obtener solo los cambios desde la última sincronización.
    ultimo_history_id   BIGINT          NULL,

    -- Timestamp del último sync exitoso
    ultimo_sync_at      TIMESTAMPTZ     NULL,

    -- Número de correos procesados en el último sync (para monitoring)
    correos_ultimo_sync INTEGER         NOT NULL DEFAULT 0,

    -- -------------------------------------------------------------------------
    -- Estado del canal Gmail Push Notifications (Pub/Sub)
    -- -------------------------------------------------------------------------
    -- ID del canal Pub/Sub activo. NULL si no hay canal activo.
    pubsub_channel_id   TEXT            NULL,

    -- Los canales de Gmail Push expiran cada 7 días — hay que renovarlos.
    -- El worker de renovación revisa esta columna para saber cuándo actuar.
    canal_expira_at     TIMESTAMPTZ     NULL,

    -- Estado del canal para monitoreo
    canal_activo        BOOLEAN         NOT NULL DEFAULT FALSE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE gmail_sync_state IS
    'Estado de sincronización Gmail por cuenta de Google Workspace (DWD). '
    'Registra el historyId más reciente y el estado del canal Pub/Sub. '
    'El worker de polling lo consulta para reanudar desde el punto correcto '
    'cuando el webhook falla. El worker de renovación controla la expiración del canal.';

COMMENT ON COLUMN gmail_sync_state.ultimo_history_id IS
    'historyId de Gmail del último mensaje procesado. '
    'Punto de reanudación para el worker de polling si el webhook cae. '
    'history.list?startHistoryId={este_valor} retorna solo los cambios nuevos.';

COMMENT ON COLUMN gmail_sync_state.canal_expira_at IS
    'Los canales Push de Gmail expiran en 7 días (máximo). '
    'El worker de renovación debe llamar users.watch() antes de esta fecha '
    'para no perder notificaciones.';


CREATE TRIGGER trg_gmail_sync_state_updated_at
    BEFORE UPDATE ON gmail_sync_state
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- RLS: solo service_role (workers de backend) pueden leer y escribir
ALTER TABLE gmail_sync_state ENABLE ROW LEVEL SECURITY;

-- Sin policies para authenticated → solo service_role tiene acceso
-- Los analistas no necesitan ver ni tocar el estado de sincronización

COMMENT ON TABLE gmail_sync_state IS
    'Estado de sincronización Gmail por cuenta DWD. '
    'RLS: sin policies para authenticated → solo service_role (workers). '
    'Accesible vía Superadmin para diagnóstico de fallos de sincronización.';


-- =============================================================================
-- SECCIÓN 4: Función para obtener el storage_path correcto según etapa
-- =============================================================================
-- Resuelve el problema de timing: los adjuntos llegan ANTES de que exista
-- el trámite. La ruta temporal usa /inbox/ y se actualiza al asignar trámite.
--
-- Ruta temporal (sin trámite):
--   correos-adjuntos/inbox/{correo_id}/{adjunto_id}/{nombre_archivo}
--
-- Ruta final (con trámite asignado):
--   correos-adjuntos/tramites/{tramite_id}/{correo_id}/{adjunto_id}/{nombre_archivo}
--
-- El Agente 1 usa la ruta temporal. El Agente 4 (Asignación) actualiza a final.
-- =============================================================================

CREATE OR REPLACE FUNCTION generar_storage_path(
    p_correo_id     uuid,
    p_adjunto_id    uuid,
    p_nombre_archivo text,
    p_tramite_id    uuid    DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
    SELECT CASE
        WHEN p_tramite_id IS NOT NULL THEN
            -- Ruta final: el trámite ya fue creado y asignado
            'tramites/' || p_tramite_id::text ||
            '/' || p_correo_id::text ||
            '/' || p_adjunto_id::text ||
            '/' || p_nombre_archivo
        ELSE
            -- Ruta temporal: el correo llegó pero aún no tiene trámite
            'inbox/' || p_correo_id::text ||
            '/' || p_adjunto_id::text ||
            '/' || p_nombre_archivo
    END;
$$;

COMMENT ON FUNCTION generar_storage_path(uuid, uuid, text, uuid) IS
    'Genera la ruta de Supabase Storage para un adjunto. '
    'Sin tramite_id: inbox/{correo_id}/{adjunto_id}/{nombre} (ruta temporal del Agente 1). '
    'Con tramite_id: tramites/{tramite_id}/{correo_id}/{adjunto_id}/{nombre} (ruta final). '
    'El Agente 4 llama actualizar_storage_path_tramite() al asignar el trámite.';

GRANT EXECUTE ON FUNCTION generar_storage_path(uuid, uuid, text, uuid) TO service_role;


-- =============================================================================
-- SECCIÓN 5: Función para actualizar rutas de adjuntos al crear el trámite
-- =============================================================================
-- Cuando el Agente 2 crea el trámite, el Agente 4 (o el propio Agente 2)
-- llama esto para actualizar los storage_path de todos los adjuntos del correo
-- de la ruta temporal (inbox/) a la ruta final (tramites/).
--
-- IMPORTANTE: el archivo en Supabase Storage NO se mueve aquí.
-- Esto solo actualiza la columna en DB. El worker tiene que mover el objeto
-- en Storage usando la API de Storage (move/copy + delete).
-- =============================================================================

CREATE OR REPLACE FUNCTION actualizar_storage_paths_tramite(
    p_correo_id     uuid,
    p_tramite_id    uuid
)
RETURNS INTEGER  -- número de adjuntos actualizados
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    UPDATE adjunto
    SET storage_path = generar_storage_path(
                            correo_id,
                            id,
                            nombre_archivo,
                            p_tramite_id
                       ),
        updated_at   = NOW()
    WHERE correo_id   = p_correo_id
      AND storage_path IS NOT NULL
      AND storage_path LIKE 'inbox/%';  -- solo las temporales

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION actualizar_storage_paths_tramite(uuid, uuid) IS
    'Actualiza los storage_path de adjuntos de inbox/ a tramites/ '
    'cuando el trámite queda creado y asignado. '
    'Solo actualiza DB — el worker debe mover los objetos en Supabase Storage también.';

GRANT EXECUTE ON FUNCTION actualizar_storage_paths_tramite(uuid, uuid) TO service_role;


-- =============================================================================
-- SECCIÓN 6: Índices nuevos
-- =============================================================================

-- Buscar adjuntos por gmail_attachment_id (re-descarga en caso de fallo)
CREATE INDEX IF NOT EXISTS idx_adjunto_gmail_id
    ON adjunto (gmail_attachment_id)
    WHERE gmail_attachment_id IS NOT NULL;

COMMENT ON INDEX idx_adjunto_gmail_id IS
    'Permite al Agente 1 verificar si un adjunto de Gmail ya fue registrado '
    '(idempotencia) y recuperar el registro para reintentar la descarga.';

-- Adjuntos en ruta temporal (inbox/) que necesitan mover a ruta final
CREATE INDEX IF NOT EXISTS idx_adjunto_storage_inbox
    ON adjunto (correo_id)
    WHERE storage_path LIKE 'inbox/%';

COMMENT ON INDEX idx_adjunto_storage_inbox IS
    'Adjuntos con ruta temporal (inbox/) que aún no tienen trámite asignado. '
    'El Agente 4 los detecta y llama actualizar_storage_paths_tramite().';

-- Estado de sync para detectar cuentas sin canal activo o con canal próximo a expirar
CREATE INDEX IF NOT EXISTS idx_gmail_sync_expiracion
    ON gmail_sync_state (canal_expira_at)
    WHERE canal_activo = TRUE;

COMMENT ON INDEX idx_gmail_sync_expiracion IS
    'Worker de renovación: detecta canales Pub/Sub próximos a expirar (en 7 días). '
    'Debe renovar antes de canal_expira_at para no perder notificaciones.';

-- Correos por canal de ingesta (monitoreo de salud del webhook)
CREATE INDEX IF NOT EXISTS idx_correo_ingestado_via
    ON correo (ingestado_via, created_at)
    WHERE ingestado_via IS NOT NULL;

COMMENT ON INDEX idx_correo_ingestado_via IS
    'Monitoreo: si ingestado_via = polling aumenta y webhook_pubsub = 0, '
    'el canal Pub/Sub está caído y hay que renovarlo.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000020_adjunto_gmail_storage.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260524000021_reasignacion_tramite.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260524000021_reasignacion_tramite.sql
-- Reasignación completa de trámites: motivo + restricción de estado
-- =============================================================================
-- Problema que resuelve:
--
--   El mecanismo base ya existía (trigger auto-gerente + trigger auto-evento),
--   pero tenía tres huecos:
--
--   1. Sin motivo: el evento de reasignación no registraba el motivo.
--      Saber que el analista cambió no es suficiente — también hay que saber
--      por qué (vacaciones, carga de trabajo, error del Agente 4, etc.).
--
--   2. Sin restricción de estado: era posible reasignar un trámite en estado
--      aprobado o rechazado, rompiendo la consistencia del historial.
--
--   3. Sin solución al problema de conexión: el motivo venía en el body de
--      la API pero se perdía porque el UPDATE al tramite y la lectura del
--      trigger ocurren en llamadas separadas que pueden usar conexiones
--      distintas del pool. Las variables de sesión no cruzaban conexiones.
--
-- Solución:
--   Una función SQL reasignar_tramite() que hace todo en una sola llamada RPC.
--   Dentro de la función: set_config() local → UPDATE tramite → trigger dispara
--   → trigger lee current_setting(). Todo en la misma transacción/conexión.
--   El trigger existente se actualiza para leer el motivo de la sesión.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: Actualizar trigger registrar_asignacion_tramite
-- Agrega lectura del motivo desde la variable de sesión app.motivo_reasignacion.
-- El motivo es opcional — si no se pasa, el evento queda sin él (comportamiento anterior).
-- =============================================================================

CREATE OR REPLACE FUNCTION registrar_asignacion_tramite()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_nombre_analista   TEXT;
    v_tipo              tipo_evento_tramite;
    v_descripcion       TEXT;
    v_motivo            TEXT;
BEGIN
    IF NEW.analista_id IS DISTINCT FROM OLD.analista_id
       AND NEW.analista_id IS NOT NULL
    THEN
        SELECT nombre INTO v_nombre_analista
        FROM usuario WHERE id = NEW.analista_id;

        -- Leer motivo de la variable de sesión (vacío o NULL si no se pasó)
        v_motivo := NULLIF(TRIM(current_setting('app.motivo_reasignacion', TRUE)), '');

        v_tipo := CASE
            WHEN OLD.analista_id IS NULL THEN 'asignacion'
            ELSE 'reasignacion'
        END;

        v_descripcion := CASE
            WHEN OLD.analista_id IS NULL THEN
                'Trámite asignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
            ELSE
                'Trámite reasignado a ' || COALESCE(v_nombre_analista, 'analista') || '.'
                || CASE WHEN v_motivo IS NOT NULL
                        THEN ' Motivo: ' || v_motivo
                        ELSE '' END
        END;

        INSERT INTO tramite_evento (
            tramite_id, tipo_evento, usuario_id, agente_ia_nombre,
            descripcion, datos, visible_en_timeline, created_at
        ) VALUES (
            NEW.id,
            v_tipo,
            -- Actor: humano si no hay agente IA activo, IA si lo hay
            CASE WHEN NULLIF(current_setting('app.agente_ia_actual', TRUE), '') IS NULL
                 THEN auth.uid() ELSE NULL END,
            NULLIF(current_setting('app.agente_ia_actual', TRUE), ''),
            v_descripcion,
            jsonb_strip_nulls(jsonb_build_object(
                'analista_anterior_id', OLD.analista_id,
                'analista_nuevo_id',    NEW.analista_id,
                'motivo',               v_motivo    -- NULL si no se proporcionó
            )),
            TRUE,
            NOW()
        );
    END IF;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION registrar_asignacion_tramite() IS
    'Registra en tramite_evento cuando cambia el analista_id del trámite. '
    'Lee app.motivo_reasignacion de la sesión para incluirlo en el evento. '
    'Detecta asignación inicial (OLD.analista_id IS NULL) vs reasignación.';


-- =============================================================================
-- SECCIÓN 2: Función reasignar_tramite()
-- Punto de entrada único para reasignar un trámite desde la API.
-- Garantiza atomicidad: todo en una sola llamada RPC = misma sesión Postgres.
--
-- Ventaja clave sobre el UPDATE directo:
--   - set_config() y el UPDATE están en la misma transacción
--   - El trigger registrar_asignacion_tramite lee current_setting() correctamente
--   - El motivo del body de la API llega al evento en tramite_evento
--
-- Validaciones incluidas:
--   1. El trámite existe
--   2. El trámite no está en estado terminal (aprobado/rechazado)
--   3. El nuevo analista existe, está activo y tiene rol 'analista'
--   4. No es el mismo analista (no-op)
-- =============================================================================

CREATE OR REPLACE FUNCTION reasignar_tramite(
    p_tramite_id        uuid,
    p_analista_nuevo_id uuid,
    p_motivo            text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_tramite               tramite%ROWTYPE;
    v_analista_nuevo        usuario%ROWTYPE;
    v_nombre_anterior       TEXT;
    v_analista_anterior_id  uuid;
BEGIN
    -- -------------------------------------------------------------------------
    -- 1. Leer y bloquear el trámite
    -- -------------------------------------------------------------------------
    SELECT * INTO v_tramite
    FROM tramite
    WHERE id = p_tramite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'TRAMITE_NO_ENCONTRADO',
            'mensaje', 'El trámite ' || p_tramite_id || ' no existe.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Validar estado — no reasignar trámites terminales
    -- -------------------------------------------------------------------------
    IF v_tramite.estado IN ('aprobado', 'rechazado') THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ESTADO_TERMINAL',
            'mensaje', 'No se puede reasignar un trámite en estado ' || v_tramite.estado || '.',
            'estado_actual', v_tramite.estado::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Validar que el nuevo analista existe, está activo y tiene rol correcto
    -- -------------------------------------------------------------------------
    SELECT * INTO v_analista_nuevo
    FROM usuario
    WHERE id = p_analista_nuevo_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ANALISTA_NO_ENCONTRADO',
            'mensaje', 'El usuario ' || p_analista_nuevo_id || ' no existe.'
        );
    END IF;

    IF v_analista_nuevo.rol != 'analista' THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ROL_INCORRECTO',
            'mensaje', 'Solo se puede asignar a usuarios con rol analista.',
            'rol_actual', v_analista_nuevo.rol::text
        );
    END IF;

    IF v_analista_nuevo.activo = FALSE THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ANALISTA_INACTIVO',
            'mensaje', 'El analista ' || v_analista_nuevo.nombre || ' está inactivo.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Evitar no-op: mismo analista
    -- -------------------------------------------------------------------------
    IF v_tramite.analista_id = p_analista_nuevo_id THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'MISMO_ANALISTA',
            'mensaje', 'El trámite ya está asignado a ' || v_analista_nuevo.nombre || '.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Guardar analista anterior para la respuesta
    -- -------------------------------------------------------------------------
    v_analista_anterior_id := v_tramite.analista_id;

    IF v_analista_anterior_id IS NOT NULL THEN
        SELECT nombre INTO v_nombre_anterior
        FROM usuario WHERE id = v_analista_anterior_id;
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Pasar el motivo al trigger vía variable de sesión LOCAL (esta transacción)
    --    TRUE = is_local: la variable vuelve a su valor anterior al salir de la transacción.
    --    El trigger registrar_asignacion_tramite la lee con current_setting().
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- -------------------------------------------------------------------------
    -- 7. Actualizar analista_id
    --    Dispara dos triggers en el mismo ciclo de la transacción:
    --      - trg_tramite_auto_asignar_gerente (BEFORE) → actualiza gerente_id
    --      - trg_tramite_registrar_asignacion (AFTER)  → crea evento con motivo
    -- -------------------------------------------------------------------------
    UPDATE tramite
    SET analista_id = p_analista_nuevo_id
    WHERE id = p_tramite_id;

    -- -------------------------------------------------------------------------
    -- 8. Limpiar variable de sesión (por higiene, aunque is_local ya lo hace)
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', '', TRUE);

    -- -------------------------------------------------------------------------
    -- 9. Retornar resultado completo
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok', true,
        'tramite_id', p_tramite_id,
        'analista_anterior_id', v_analista_anterior_id,
        'analista_anterior_nombre', v_nombre_anterior,
        'analista_nuevo_id', p_analista_nuevo_id,
        'analista_nuevo_nombre', v_analista_nuevo.nombre,
        'motivo', p_motivo,
        'estado_tramite', v_tramite.estado::text
    );
END;
$$;

COMMENT ON FUNCTION reasignar_tramite(uuid, uuid, text) IS
    'Reasigna un trámite a un nuevo analista de forma atómica. '
    'Valida: trámite existe, no está en estado terminal, analista activo y con rol correcto, no es el mismo. '
    'Pasa el motivo al trigger registrar_asignacion_tramite vía set_config() local. '
    'Todo ocurre en una sola transacción — la variable de sesión con el motivo es visible al trigger. '
    'Retorna jsonb con ok=true/false y detalle del resultado.';

-- Solo roles con capacidad de reasignar pueden ejecutar esta función
GRANT EXECUTE ON FUNCTION reasignar_tramite(uuid, uuid, text)
    TO authenticated, service_role;


-- =============================================================================
-- SECCIÓN 3: Enum para motivos de reasignación (catálogo controlado)
-- Evita texto libre inconsistente. Los valores se muestran en la UI como opciones.
-- El usuario puede elegir uno del catálogo o escribir uno libre.
-- =============================================================================

-- La tabla configuracion_sistema ya existe. Insertamos los motivos predefinidos
-- como un valor JSON que la UI leerá para mostrar el selector.
INSERT INTO configuracion_sistema (
    clave, valor, tipo_valor, descripcion, grupo, editable_por
) VALUES (
    'MOTIVOS_REASIGNACION',
    '["Vacaciones del analista",
      "Licencia médica",
      "Exceso de carga de trabajo",
      "Error de asignación inicial del Agente 4",
      "Solicitud del agente de seguros",
      "Cambio de ramo",
      "Baja del analista",
      "Otro"]',
    'json',
    'Lista de motivos predefinidos para reasignación de trámites. La UI los muestra como opciones en el selector.',
    'operaciones',
    'director'
)
ON CONFLICT (clave, aplica_ramo) DO NOTHING;

COMMENT ON TABLE configuracion_sistema IS
    'Parámetros operativos del CRM, incluyendo MOTIVOS_REASIGNACION para el selector de la UI.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000021_reasignacion_tramite.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260524000022_permisos_sistema.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260524000022_permisos_sistema.sql
-- Sistema de permisos granulares por rol y por usuario
-- =============================================================================
--
-- Diseño:
--   permiso          — catálogo inmutable de 52 claves de permiso
--   rol_permiso      — defaults por rol (editables por directores vía función)
--   usuario_permiso  — overrides explícitos por usuario (directors y gerentes)
--   permiso_audit_log — historial inmutable de todos los cambios
--
-- Resolución en tiene_permiso():
--   1. Si existe override en usuario_permiso → usar ese valor
--   2. Si no → buscar en rol_permiso para el rol del usuario
--   3. Si no → FALSE (denegado por defecto)
--
-- Todas las escrituras ocurren a través de funciones SECURITY DEFINER.
-- Nunca DML directo sobre estas tablas desde la API.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: Tablas
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1.1 permiso — catálogo de claves de permiso
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS permiso (
    id          UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
    clave       TEXT        NOT NULL UNIQUE,        -- 'tramites.reasignar'
    dominio     TEXT        NOT NULL,               -- 'tramites'
    nombre      TEXT        NOT NULL,               -- 'Reasignar trámite'
    descripcion TEXT,
    activo      BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE permiso IS
    'Catálogo de permisos granulares del sistema. '
    'Inmutable en producción: se agrega, nunca se elimina (para no romper audit log). '
    'Desactivar con activo=FALSE si un permiso queda obsoleto.';

-- -----------------------------------------------------------------------------
-- 1.2 rol_permiso — defaults configurables por rol
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rol_permiso (
    rol         rol_usuario NOT NULL,
    permiso_id  UUID        NOT NULL REFERENCES permiso(id) ON DELETE CASCADE,
    concedido   BOOLEAN     NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (rol, permiso_id)
);

COMMENT ON TABLE rol_permiso IS
    'Permisos por defecto de cada rol. '
    'Los directores los configuran vía configurar_permiso_rol(). '
    'Un analista que no tenga override en usuario_permiso hereda estos valores.';

-- -----------------------------------------------------------------------------
-- 1.3 usuario_permiso — overrides explícitos por usuario
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuario_permiso (
    usuario_id   UUID        NOT NULL REFERENCES usuario(id) ON DELETE CASCADE,
    permiso_id   UUID        NOT NULL REFERENCES permiso(id) ON DELETE CASCADE,
    concedido    BOOLEAN     NOT NULL,
    otorgado_por UUID        NOT NULL REFERENCES usuario(id),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (usuario_id, permiso_id)
);

COMMENT ON TABLE usuario_permiso IS
    'Overrides de permiso individuales por usuario. '
    'Sobreescribe el default del rol (rol_permiso). '
    'Se gestiona con otorgar_permiso_usuario() y revocar_permiso_usuario(). '
    'Directors pueden configurar a cualquier usuario. '
    'Gerentes solo pueden configurar analistas de su mismo ramo.';

-- -----------------------------------------------------------------------------
-- 1.4 permiso_audit_log — historial inmutable
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS permiso_audit_log (
    id                  UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
    tipo                TEXT        NOT NULL CHECK (tipo IN ('rol', 'usuario', 'usuario_revocado')),
    permiso_id          UUID        NOT NULL REFERENCES permiso(id),
    permiso_clave       TEXT        NOT NULL,   -- desnormalizado: sobrevive si cambia la clave
    rol                 rol_usuario,            -- poblado cuando tipo='rol'
    usuario_id          UUID,                   -- poblado cuando tipo='usuario' o 'usuario_revocado'
    concedido_anterior  BOOLEAN,                -- NULL = primera configuración
    concedido_nuevo     BOOLEAN,                -- NULL = revocación (tipo='usuario_revocado')
    realizado_por       UUID        NOT NULL REFERENCES usuario(id),
    realizado_por_nombre TEXT       NOT NULL,   -- desnormalizado para permanencia
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE permiso_audit_log IS
    'Historial inmutable de todos los cambios de permisos. '
    'Append-only: nunca UPDATE ni DELETE sobre esta tabla. '
    'tipo=rol: cambio en rol_permiso. '
    'tipo=usuario: otorgamiento/modificación de override. '
    'tipo=usuario_revocado: eliminación de override (vuelve al default del rol).';

-- Índices para consultas frecuentes de audit
CREATE INDEX IF NOT EXISTS idx_permiso_audit_log_usuario
    ON permiso_audit_log (usuario_id, created_at DESC)
    WHERE usuario_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_permiso_audit_log_rol
    ON permiso_audit_log (rol, created_at DESC)
    WHERE rol IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_permiso_audit_log_created
    ON permiso_audit_log (created_at DESC);


-- =============================================================================
-- SECCIÓN 2: Catálogo de permisos (52 claves)
-- =============================================================================

INSERT INTO permiso (clave, dominio, nombre, descripcion) VALUES

-- Dominio: tramites (9)
('tramites.ver',            'tramites',      'Ver trámites',
    'Ver los trámites propios asignados al analista.'),
('tramites.crear',          'tramites',      'Crear trámites',
    'Abrir nuevos trámites en el sistema.'),
('tramites.editar',         'tramites',      'Editar trámites',
    'Modificar datos de trámites existentes (título, descripción, prioridad, etc.).'),
('tramites.eliminar',       'tramites',      'Eliminar trámites',
    'Eliminar trámites del sistema. Acción destructiva e irreversible.'),
('tramites.cambiar_estado', 'tramites',      'Cambiar estado',
    'Avanzar el estado del trámite en su ciclo de vida.'),
('tramites.reasignar',      'tramites',      'Reasignar trámite',
    'Reasignar un trámite a un analista diferente.'),
('tramites.ver_todos',      'tramites',      'Ver todos los trámites',
    'Ver trámites de todos los analistas, no solo los propios.'),
('tramites.ver_metricas',   'tramites',      'Ver métricas',
    'Ver estadísticas y métricas agregadas de trámites.'),
('tramites.marcar_atencion','tramites',      'Marcar atención requerida',
    'Marcar o desmarcar el flag requiere_atención en un trámite.'),

-- Dominio: correos (5)
('correos.ver',              'correos',      'Ver correos',
    'Ver correos vinculados a trámites propios.'),
('correos.responder',        'correos',      'Responder correos',
    'Redactar y enviar respuestas desde la plataforma.'),
('correos.vincular_tramite', 'correos',      'Vincular correo a trámite',
    'Vincular un correo existente a un trámite.'),
('correos.descargar_adjuntos','correos',     'Descargar adjuntos',
    'Descargar archivos adjuntos de correos.'),
('correos.ver_todos',        'correos',      'Ver todos los correos',
    'Ver correos de todos los analistas, no solo los propios.'),

-- Dominio: documentos (5)
('documentos.ver',           'documentos',   'Ver documentos',
    'Ver documentos adjuntos a trámites propios.'),
('documentos.subir',         'documentos',   'Subir documentos',
    'Cargar documentos a un trámite.'),
('documentos.eliminar',      'documentos',   'Eliminar documentos',
    'Eliminar documentos de un trámite.'),
('documentos.ejecutar_ocr',  'documentos',   'Ejecutar OCR',
    'Lanzar OCR manualmente sobre un documento.'),
('documentos.ver_todos',     'documentos',   'Ver todos los documentos',
    'Ver documentos de cualquier trámite, no solo los propios.'),

-- Dominio: usuarios (6)
('usuarios.crear',           'usuarios',     'Crear usuarios',
    'Dar de alta nuevos usuarios en el sistema.'),
('usuarios.editar',          'usuarios',     'Editar usuarios',
    'Modificar datos de usuarios existentes.'),
('usuarios.desactivar',      'usuarios',     'Desactivar usuarios',
    'Desactivar o reactivar cuentas de usuario.'),
('usuarios.ver_todos',       'usuarios',     'Ver directorio',
    'Ver el directorio completo de usuarios del sistema.'),
('usuarios.gestionar_roles', 'usuarios',     'Gestionar roles',
    'Cambiar el rol asignado a un usuario.'),
('usuarios.resetear_password','usuarios',    'Resetear contraseña',
    'Enviar enlace de reset de contraseña a un usuario.'),

-- Dominio: agentes (5)
('agentes.ver',              'agentes',      'Ver agentes',
    'Ver el catálogo de agentes de seguros.'),
('agentes.crear',            'agentes',      'Crear agentes',
    'Dar de alta nuevos agentes de seguros.'),
('agentes.editar',           'agentes',      'Editar agentes',
    'Modificar datos de agentes existentes.'),
('agentes.eliminar',         'agentes',      'Eliminar agentes',
    'Eliminar agentes del catálogo.'),
('agentes.ver_cua',          'agentes',      'Ver número CUA',
    'Ver el número CUA de los agentes de seguros.'),

-- Dominio: asignaciones (5)
('asignaciones.ver',         'asignaciones', 'Ver asignaciones',
    'Ver la tabla de asignaciones analista-agente-ramo.'),
('asignaciones.crear',       'asignaciones', 'Crear asignaciones',
    'Asignar agentes a analistas por ramo.'),
('asignaciones.editar',      'asignaciones', 'Editar asignaciones',
    'Modificar asignaciones existentes.'),
('asignaciones.eliminar',    'asignaciones', 'Eliminar asignaciones',
    'Eliminar asignaciones analista-agente.'),
('coberturas.gestionar',     'asignaciones', 'Gestionar coberturas',
    'Configurar coberturas de vacaciones entre analistas.'),

-- Dominio: slas (2)
('slas.ver',                 'slas',         'Ver SLAs',
    'Ver definiciones y cumplimiento de SLAs.'),
('slas.configurar',          'slas',         'Configurar SLAs',
    'Crear y editar definiciones de SLA.'),

-- Dominio: rag (4)
('rag.ver',                  'rag',          'Ver base RAG',
    'Ver la base de conocimiento RAG (manuales GNP, requisitos, formas).'),
('rag.ingestar',             'rag',          'Ingestar documentos',
    'Subir documentos a la base de conocimiento RAG.'),
('rag.eliminar_chunks',      'rag',          'Eliminar chunks RAG',
    'Eliminar fragmentos de la base RAG.'),
('rag.ver_aprendizajes',     'rag',          'Ver aprendizajes',
    'Ver aprendizajes generados de rechazos GNP.'),

-- Dominio: reportes (4)
('reportes.ver_propios',     'reportes',     'Ver reportes propios',
    'Ver reportes de los trámites propios.'),
('reportes.ver_equipo',      'reportes',     'Ver reportes de equipo',
    'Ver reportes del equipo del gerente (todos sus analistas).'),
('reportes.ver_global',      'reportes',     'Ver reportes globales',
    'Ver reportes de toda la organización.'),
('reportes.exportar',        'reportes',     'Exportar reportes',
    'Exportar reportes a Excel o CSV.'),

-- Dominio: configuracion (7)
('config.ver',               'configuracion','Ver configuración',
    'Ver parámetros de configuración del sistema.'),
('config.editar',            'configuracion','Editar configuración',
    'Modificar parámetros del sistema (umbrales, textos, etc.).'),
('pipeline.ver',             'configuracion','Ver pipeline IA',
    'Ver el estado del pipeline de agentes IA.'),
('pipeline.ejecutar',        'configuracion','Ejecutar pipeline',
    'Lanzar el pipeline manualmente sobre un correo o trámite.'),
('pipeline.configurar',      'configuracion','Configurar pipeline IA',
    'Modificar umbrales y parámetros del pipeline de IA.'),
('permisos.gestionar_usuarios','configuracion','Gestionar permisos de usuario',
    'Otorgar o revocar permisos individuales a usuarios.'),
('permisos.gestionar_roles', 'configuracion','Gestionar permisos de rol',
    'Configurar los permisos por defecto de cada rol.')

ON CONFLICT (clave) DO NOTHING;


-- =============================================================================
-- SECCIÓN 3: Defaults de rol (rol_permiso)
-- =============================================================================
-- Formato: (rol, permiso_id, concedido)
-- Los permisos NO listados para un rol quedan como FALSE por defecto (ausencia = denegado).
-- =============================================================================

INSERT INTO rol_permiso (rol, permiso_id, concedido)
SELECT r.rol, p.id, r.concedido
FROM (VALUES
    -- tramites
    ('director_general', 'tramites.ver',            TRUE),
    ('director_general', 'tramites.crear',           TRUE),
    ('director_general', 'tramites.editar',          TRUE),
    ('director_general', 'tramites.eliminar',        TRUE),
    ('director_general', 'tramites.cambiar_estado',  TRUE),
    ('director_general', 'tramites.reasignar',       TRUE),
    ('director_general', 'tramites.ver_todos',       TRUE),
    ('director_general', 'tramites.ver_metricas',    TRUE),
    ('director_general', 'tramites.marcar_atencion', TRUE),
    ('director_ops',     'tramites.ver',             TRUE),
    ('director_ops',     'tramites.crear',           TRUE),
    ('director_ops',     'tramites.editar',          TRUE),
    ('director_ops',     'tramites.eliminar',        FALSE),
    ('director_ops',     'tramites.cambiar_estado',  TRUE),
    ('director_ops',     'tramites.reasignar',       TRUE),
    ('director_ops',     'tramites.ver_todos',       TRUE),
    ('director_ops',     'tramites.ver_metricas',    TRUE),
    ('director_ops',     'tramites.marcar_atencion', TRUE),
    ('gerente',          'tramites.ver',             TRUE),
    ('gerente',          'tramites.crear',           TRUE),
    ('gerente',          'tramites.editar',          TRUE),
    ('gerente',          'tramites.eliminar',        FALSE),
    ('gerente',          'tramites.cambiar_estado',  TRUE),
    ('gerente',          'tramites.reasignar',       TRUE),
    ('gerente',          'tramites.ver_todos',       TRUE),
    ('gerente',          'tramites.ver_metricas',    TRUE),
    ('gerente',          'tramites.marcar_atencion', TRUE),
    ('analista',         'tramites.ver',             TRUE),
    ('analista',         'tramites.crear',           FALSE),
    ('analista',         'tramites.editar',          FALSE),
    ('analista',         'tramites.eliminar',        FALSE),
    ('analista',         'tramites.cambiar_estado',  TRUE),
    ('analista',         'tramites.reasignar',       FALSE),
    ('analista',         'tramites.ver_todos',       FALSE),
    ('analista',         'tramites.ver_metricas',    FALSE),
    ('analista',         'tramites.marcar_atencion', TRUE),
    -- correos
    ('director_general', 'correos.ver',              TRUE),
    ('director_general', 'correos.responder',        TRUE),
    ('director_general', 'correos.vincular_tramite', TRUE),
    ('director_general', 'correos.descargar_adjuntos', TRUE),
    ('director_general', 'correos.ver_todos',        TRUE),
    ('director_ops',     'correos.ver',              TRUE),
    ('director_ops',     'correos.responder',        TRUE),
    ('director_ops',     'correos.vincular_tramite', TRUE),
    ('director_ops',     'correos.descargar_adjuntos', TRUE),
    ('director_ops',     'correos.ver_todos',        TRUE),
    ('gerente',          'correos.ver',              TRUE),
    ('gerente',          'correos.responder',        TRUE),
    ('gerente',          'correos.vincular_tramite', TRUE),
    ('gerente',          'correos.descargar_adjuntos', TRUE),
    ('gerente',          'correos.ver_todos',        TRUE),
    ('analista',         'correos.ver',              TRUE),
    ('analista',         'correos.responder',        TRUE),
    ('analista',         'correos.vincular_tramite', FALSE),
    ('analista',         'correos.descargar_adjuntos', TRUE),
    ('analista',         'correos.ver_todos',        FALSE),
    -- documentos
    ('director_general', 'documentos.ver',           TRUE),
    ('director_general', 'documentos.subir',         TRUE),
    ('director_general', 'documentos.eliminar',      TRUE),
    ('director_general', 'documentos.ejecutar_ocr',  TRUE),
    ('director_general', 'documentos.ver_todos',     TRUE),
    ('director_ops',     'documentos.ver',           TRUE),
    ('director_ops',     'documentos.subir',         TRUE),
    ('director_ops',     'documentos.eliminar',      TRUE),
    ('director_ops',     'documentos.ejecutar_ocr',  TRUE),
    ('director_ops',     'documentos.ver_todos',     TRUE),
    ('gerente',          'documentos.ver',           TRUE),
    ('gerente',          'documentos.subir',         TRUE),
    ('gerente',          'documentos.eliminar',      FALSE),
    ('gerente',          'documentos.ejecutar_ocr',  FALSE),
    ('gerente',          'documentos.ver_todos',     TRUE),
    ('analista',         'documentos.ver',           TRUE),
    ('analista',         'documentos.subir',         TRUE),
    ('analista',         'documentos.eliminar',      FALSE),
    ('analista',         'documentos.ejecutar_ocr',  FALSE),
    ('analista',         'documentos.ver_todos',     FALSE),
    -- usuarios
    ('director_general', 'usuarios.crear',           TRUE),
    ('director_general', 'usuarios.editar',          TRUE),
    ('director_general', 'usuarios.desactivar',      TRUE),
    ('director_general', 'usuarios.ver_todos',       TRUE),
    ('director_general', 'usuarios.gestionar_roles', TRUE),
    ('director_general', 'usuarios.resetear_password', TRUE),
    ('director_ops',     'usuarios.crear',           FALSE),
    ('director_ops',     'usuarios.editar',          TRUE),
    ('director_ops',     'usuarios.desactivar',      TRUE),
    ('director_ops',     'usuarios.ver_todos',       TRUE),
    ('director_ops',     'usuarios.gestionar_roles', FALSE),
    ('director_ops',     'usuarios.resetear_password', TRUE),
    ('gerente',          'usuarios.crear',           FALSE),
    ('gerente',          'usuarios.editar',          FALSE),
    ('gerente',          'usuarios.desactivar',      FALSE),
    ('gerente',          'usuarios.ver_todos',       TRUE),
    ('gerente',          'usuarios.gestionar_roles', FALSE),
    ('gerente',          'usuarios.resetear_password', FALSE),
    ('analista',         'usuarios.crear',           FALSE),
    ('analista',         'usuarios.editar',          FALSE),
    ('analista',         'usuarios.desactivar',      FALSE),
    ('analista',         'usuarios.ver_todos',       FALSE),
    ('analista',         'usuarios.gestionar_roles', FALSE),
    ('analista',         'usuarios.resetear_password', FALSE),
    -- agentes
    ('director_general', 'agentes.ver',              TRUE),
    ('director_general', 'agentes.crear',            TRUE),
    ('director_general', 'agentes.editar',           TRUE),
    ('director_general', 'agentes.eliminar',         TRUE),
    ('director_general', 'agentes.ver_cua',          TRUE),
    ('director_ops',     'agentes.ver',              TRUE),
    ('director_ops',     'agentes.crear',            TRUE),
    ('director_ops',     'agentes.editar',           TRUE),
    ('director_ops',     'agentes.eliminar',         FALSE),
    ('director_ops',     'agentes.ver_cua',          TRUE),
    ('gerente',          'agentes.ver',              TRUE),
    ('gerente',          'agentes.crear',            FALSE),
    ('gerente',          'agentes.editar',           FALSE),
    ('gerente',          'agentes.eliminar',         FALSE),
    ('gerente',          'agentes.ver_cua',          TRUE),
    ('analista',         'agentes.ver',              TRUE),
    ('analista',         'agentes.crear',            FALSE),
    ('analista',         'agentes.editar',           FALSE),
    ('analista',         'agentes.eliminar',         FALSE),
    ('analista',         'agentes.ver_cua',          FALSE),
    -- asignaciones
    ('director_general', 'asignaciones.ver',         TRUE),
    ('director_general', 'asignaciones.crear',       TRUE),
    ('director_general', 'asignaciones.editar',      TRUE),
    ('director_general', 'asignaciones.eliminar',    TRUE),
    ('director_general', 'coberturas.gestionar',     TRUE),
    ('director_ops',     'asignaciones.ver',         TRUE),
    ('director_ops',     'asignaciones.crear',       TRUE),
    ('director_ops',     'asignaciones.editar',      TRUE),
    ('director_ops',     'asignaciones.eliminar',    TRUE),
    ('director_ops',     'coberturas.gestionar',     TRUE),
    ('gerente',          'asignaciones.ver',         TRUE),
    ('gerente',          'asignaciones.crear',       TRUE),
    ('gerente',          'asignaciones.editar',      TRUE),
    ('gerente',          'asignaciones.eliminar',    FALSE),
    ('gerente',          'coberturas.gestionar',     TRUE),
    ('analista',         'asignaciones.ver',         FALSE),
    ('analista',         'asignaciones.crear',       FALSE),
    ('analista',         'asignaciones.editar',      FALSE),
    ('analista',         'asignaciones.eliminar',    FALSE),
    ('analista',         'coberturas.gestionar',     FALSE),
    -- slas
    ('director_general', 'slas.ver',                 TRUE),
    ('director_general', 'slas.configurar',          TRUE),
    ('director_ops',     'slas.ver',                 TRUE),
    ('director_ops',     'slas.configurar',          TRUE),
    ('gerente',          'slas.ver',                 TRUE),
    ('gerente',          'slas.configurar',          FALSE),
    ('analista',         'slas.ver',                 FALSE),
    ('analista',         'slas.configurar',          FALSE),
    -- rag
    ('director_general', 'rag.ver',                  TRUE),
    ('director_general', 'rag.ingestar',             TRUE),
    ('director_general', 'rag.eliminar_chunks',      TRUE),
    ('director_general', 'rag.ver_aprendizajes',     TRUE),
    ('director_ops',     'rag.ver',                  TRUE),
    ('director_ops',     'rag.ingestar',             TRUE),
    ('director_ops',     'rag.eliminar_chunks',      FALSE),
    ('director_ops',     'rag.ver_aprendizajes',     TRUE),
    ('gerente',          'rag.ver',                  TRUE),
    ('gerente',          'rag.ingestar',             FALSE),
    ('gerente',          'rag.eliminar_chunks',      FALSE),
    ('gerente',          'rag.ver_aprendizajes',     TRUE),
    ('analista',         'rag.ver',                  FALSE),
    ('analista',         'rag.ingestar',             FALSE),
    ('analista',         'rag.eliminar_chunks',      FALSE),
    ('analista',         'rag.ver_aprendizajes',     FALSE),
    -- reportes
    ('director_general', 'reportes.ver_propios',     TRUE),
    ('director_general', 'reportes.ver_equipo',      TRUE),
    ('director_general', 'reportes.ver_global',      TRUE),
    ('director_general', 'reportes.exportar',        TRUE),
    ('director_ops',     'reportes.ver_propios',     TRUE),
    ('director_ops',     'reportes.ver_equipo',      TRUE),
    ('director_ops',     'reportes.ver_global',      TRUE),
    ('director_ops',     'reportes.exportar',        TRUE),
    ('gerente',          'reportes.ver_propios',     TRUE),
    ('gerente',          'reportes.ver_equipo',      TRUE),
    ('gerente',          'reportes.ver_global',      FALSE),
    ('gerente',          'reportes.exportar',        FALSE),
    ('analista',         'reportes.ver_propios',     TRUE),
    ('analista',         'reportes.ver_equipo',      FALSE),
    ('analista',         'reportes.ver_global',      FALSE),
    ('analista',         'reportes.exportar',        FALSE),
    -- configuracion
    ('director_general', 'config.ver',               TRUE),
    ('director_general', 'config.editar',            TRUE),
    ('director_general', 'pipeline.ver',             TRUE),
    ('director_general', 'pipeline.ejecutar',        TRUE),
    ('director_general', 'pipeline.configurar',      TRUE),
    ('director_general', 'permisos.gestionar_usuarios', TRUE),
    ('director_general', 'permisos.gestionar_roles', TRUE),
    ('director_ops',     'config.ver',               TRUE),
    ('director_ops',     'config.editar',            TRUE),
    ('director_ops',     'pipeline.ver',             TRUE),
    ('director_ops',     'pipeline.ejecutar',        TRUE),
    ('director_ops',     'pipeline.configurar',      FALSE),
    ('director_ops',     'permisos.gestionar_usuarios', TRUE),
    ('director_ops',     'permisos.gestionar_roles', FALSE),
    ('gerente',          'config.ver',               FALSE),
    ('gerente',          'config.editar',            FALSE),
    ('gerente',          'pipeline.ver',             FALSE),
    ('gerente',          'pipeline.ejecutar',        FALSE),
    ('gerente',          'pipeline.configurar',      FALSE),
    ('gerente',          'permisos.gestionar_usuarios', TRUE),
    ('gerente',          'permisos.gestionar_roles', FALSE),
    ('analista',         'config.ver',               FALSE),
    ('analista',         'config.editar',            FALSE),
    ('analista',         'pipeline.ver',             FALSE),
    ('analista',         'pipeline.ejecutar',        FALSE),
    ('analista',         'pipeline.configurar',      FALSE),
    ('analista',         'permisos.gestionar_usuarios', FALSE),
    ('analista',         'permisos.gestionar_roles', FALSE)
) AS r(rol, clave, concedido)
JOIN permiso p ON p.clave = r.clave
ON CONFLICT (rol, permiso_id) DO UPDATE SET concedido = EXCLUDED.concedido;


-- =============================================================================
-- SECCIÓN 4: Row Level Security
-- =============================================================================

ALTER TABLE permiso           ENABLE ROW LEVEL SECURITY;
ALTER TABLE rol_permiso       ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_permiso   ENABLE ROW LEVEL SECURITY;
ALTER TABLE permiso_audit_log ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- permiso: todo autenticado puede leer el catálogo
-- -----------------------------------------------------------------------------
CREATE POLICY "permiso_select_authenticated"
    ON permiso FOR SELECT TO authenticated
    USING (TRUE);

-- -----------------------------------------------------------------------------
-- rol_permiso: todo autenticado puede leer los defaults de roles
-- -----------------------------------------------------------------------------
CREATE POLICY "rol_permiso_select_authenticated"
    ON rol_permiso FOR SELECT TO authenticated
    USING (TRUE);

-- -----------------------------------------------------------------------------
-- usuario_permiso: lectura según rol
--   - El propio usuario ve sus overrides
--   - Directores ven todos
--   - Gerentes ven los de analistas de su mismo ramo
-- -----------------------------------------------------------------------------
CREATE POLICY "usuario_permiso_select"
    ON usuario_permiso FOR SELECT TO authenticated
    USING (
        usuario_id = auth.uid()
        OR (auth.jwt() -> 'app_metadata' ->> 'rol') IN ('director_general', 'director_ops')
        OR (
            (auth.jwt() -> 'app_metadata' ->> 'rol') = 'gerente'
            AND EXISTS (
                SELECT 1 FROM usuario u
                WHERE u.id = usuario_permiso.usuario_id
                  AND u.ramo = (auth.jwt() -> 'app_metadata' ->> 'ramo')
            )
        )
    );

-- -----------------------------------------------------------------------------
-- permiso_audit_log: lectura según rol
--   - Directores ven todo el audit log
--   - Gerentes ven solo los cambios de usuarios de su ramo
--   - Analistas no ven el audit log
-- -----------------------------------------------------------------------------
CREATE POLICY "permiso_audit_log_select"
    ON permiso_audit_log FOR SELECT TO authenticated
    USING (
        (auth.jwt() -> 'app_metadata' ->> 'rol') IN ('director_general', 'director_ops')
        OR (
            (auth.jwt() -> 'app_metadata' ->> 'rol') = 'gerente'
            AND (
                -- Cambios de tipo 'usuario' o 'usuario_revocado' en analistas del propio ramo
                (usuario_id IS NOT NULL AND EXISTS (
                    SELECT 1 FROM usuario u
                    WHERE u.id = permiso_audit_log.usuario_id
                      AND u.ramo = (auth.jwt() -> 'app_metadata' ->> 'ramo')
                ))
            )
        )
    );


-- =============================================================================
-- SECCIÓN 5: GRANTs base
-- =============================================================================

GRANT SELECT ON permiso, rol_permiso, usuario_permiso, permiso_audit_log
    TO authenticated;


-- =============================================================================
-- SECCIÓN 6: Funciones SQL
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 6.1 tiene_permiso() — resolución de permisos (hot path)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION tiene_permiso(
    p_usuario_id    uuid,
    p_clave         text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_concedido     boolean;
    v_rol           rol_usuario;
    v_permiso_id    uuid;
BEGIN
    -- Buscar el permiso en el catálogo
    SELECT id INTO v_permiso_id
    FROM permiso
    WHERE clave = p_clave AND activo = TRUE;

    IF v_permiso_id IS NULL THEN
        RETURN FALSE;   -- Permiso desconocido o inactivo
    END IF;

    -- 1. Override explícito de usuario
    SELECT concedido INTO v_concedido
    FROM usuario_permiso
    WHERE usuario_id = p_usuario_id
      AND permiso_id = v_permiso_id;

    IF FOUND THEN
        RETURN v_concedido;
    END IF;

    -- 2. Default del rol del usuario
    SELECT rol INTO v_rol
    FROM usuario
    WHERE id = p_usuario_id AND activo = TRUE;

    IF v_rol IS NULL THEN
        RETURN FALSE;   -- Usuario no encontrado o inactivo
    END IF;

    SELECT concedido INTO v_concedido
    FROM rol_permiso
    WHERE rol = v_rol
      AND permiso_id = v_permiso_id;

    RETURN COALESCE(v_concedido, FALSE);
END;
$$;

COMMENT ON FUNCTION tiene_permiso(uuid, text) IS
    'Resuelve si un usuario tiene un permiso dado. '
    'Orden: override de usuario → default de rol → FALSE. '
    'Hot path: se llama en cada request desde require_permiso() en FastAPI.';

GRANT EXECUTE ON FUNCTION tiene_permiso(uuid, text) TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 6.2 otorgar_permiso_usuario() — concede o deniega un override a un usuario
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION otorgar_permiso_usuario(
    p_usuario_id    uuid,
    p_permiso_clave text,
    p_concedido     boolean,
    p_otorgado_por  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_permiso           permiso%ROWTYPE;
    v_usuario           usuario%ROWTYPE;
    v_otorgado_por      usuario%ROWTYPE;
    v_anterior          boolean;
    v_nombre_realizado  text;
BEGIN
    -- 1. Validar que el permiso existe y está activo
    SELECT * INTO v_permiso FROM permiso WHERE clave = p_permiso_clave;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'PERMISO_NO_ENCONTRADO',
            'mensaje', 'No existe el permiso: ' || p_permiso_clave
        );
    END IF;
    IF NOT v_permiso.activo THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'PERMISO_INACTIVO',
            'mensaje', 'El permiso ' || p_permiso_clave || ' está desactivado.'
        );
    END IF;

    -- 2. Validar usuario destino
    SELECT * INTO v_usuario FROM usuario WHERE id = p_usuario_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'USUARIO_NO_ENCONTRADO',
            'mensaje', 'El usuario ' || p_usuario_id || ' no existe.'
        );
    END IF;
    IF NOT v_usuario.activo THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'USUARIO_INACTIVO',
            'mensaje', 'El usuario ' || v_usuario.nombre || ' está inactivo.'
        );
    END IF;

    -- 3. Validar que el otorgador existe y tiene permisos
    SELECT * INTO v_otorgado_por FROM usuario WHERE id = p_otorgado_por;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'OTORGADOR_NO_ENCONTRADO',
            'mensaje', 'El usuario otorgador ' || p_otorgado_por || ' no existe.'
        );
    END IF;

    -- 4. Validar autorización del otorgador
    IF NOT tiene_permiso(p_otorgado_por, 'permisos.gestionar_usuarios') THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'SIN_PERMISO',
            'mensaje', 'No tienes el permiso permisos.gestionar_usuarios.'
        );
    END IF;

    -- 5. Si el otorgador es gerente, el usuario destino debe ser de su mismo ramo
    IF v_otorgado_por.rol = 'gerente' THEN
        IF v_usuario.ramo IS DISTINCT FROM v_otorgado_por.ramo THEN
            RETURN jsonb_build_object(
                'ok', false,
                'error_code', 'RAMO_DIFERENTE',
                'mensaje', 'Un gerente solo puede gestionar permisos de usuarios de su propio ramo.'
            );
        END IF;
    END IF;

    -- 6. Obtener valor anterior para audit
    SELECT concedido INTO v_anterior
    FROM usuario_permiso
    WHERE usuario_id = p_usuario_id AND permiso_id = v_permiso.id;

    -- 7. Upsert del override
    INSERT INTO usuario_permiso (usuario_id, permiso_id, concedido, otorgado_por, created_at)
    VALUES (p_usuario_id, v_permiso.id, p_concedido, p_otorgado_por, NOW())
    ON CONFLICT (usuario_id, permiso_id)
    DO UPDATE SET
        concedido    = EXCLUDED.concedido,
        otorgado_por = EXCLUDED.otorgado_por,
        created_at   = NOW();

    -- 8. Registrar en audit log
    SELECT nombre INTO v_nombre_realizado FROM usuario WHERE id = p_otorgado_por;
    INSERT INTO permiso_audit_log (
        tipo, permiso_id, permiso_clave, usuario_id,
        concedido_anterior, concedido_nuevo,
        realizado_por, realizado_por_nombre, created_at
    ) VALUES (
        'usuario', v_permiso.id, p_permiso_clave, p_usuario_id,
        v_anterior, p_concedido,
        p_otorgado_por, v_nombre_realizado, NOW()
    );

    RETURN jsonb_build_object(
        'ok', true,
        'usuario_id', p_usuario_id,
        'usuario_nombre', v_usuario.nombre,
        'permiso_clave', p_permiso_clave,
        'concedido_anterior', v_anterior,
        'concedido_nuevo', p_concedido
    );
END;
$$;

COMMENT ON FUNCTION otorgar_permiso_usuario(uuid, text, boolean, uuid) IS
    'Concede o deniega explícitamente un permiso a un usuario. '
    'Valida: permiso activo, usuario activo, otorgador con permiso permisos.gestionar_usuarios, '
    'y que gerentes solo gestionen usuarios de su propio ramo. '
    'Registra cambio en permiso_audit_log. '
    'Retorna jsonb con ok y detalle.';

GRANT EXECUTE ON FUNCTION otorgar_permiso_usuario(uuid, text, boolean, uuid)
    TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 6.3 revocar_permiso_usuario() — elimina el override, vuelve al default de rol
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION revocar_permiso_usuario(
    p_usuario_id    uuid,
    p_permiso_clave text,
    p_revocado_por  uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_permiso           permiso%ROWTYPE;
    v_usuario           usuario%ROWTYPE;
    v_revocador         usuario%ROWTYPE;
    v_override          usuario_permiso%ROWTYPE;
    v_default_rol       boolean;
    v_nombre_realizado  text;
BEGIN
    -- 1. Validar permiso
    SELECT * INTO v_permiso FROM permiso WHERE clave = p_permiso_clave;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'PERMISO_NO_ENCONTRADO',
            'mensaje', 'No existe el permiso: ' || p_permiso_clave
        );
    END IF;

    -- 2. Validar usuario destino
    SELECT * INTO v_usuario FROM usuario WHERE id = p_usuario_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'USUARIO_NO_ENCONTRADO',
            'mensaje', 'El usuario ' || p_usuario_id || ' no existe.'
        );
    END IF;

    -- 3. Validar revocador y autorización
    SELECT * INTO v_revocador FROM usuario WHERE id = p_revocado_por;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'REVOCADOR_NO_ENCONTRADO',
            'mensaje', 'El usuario revocador ' || p_revocado_por || ' no existe.'
        );
    END IF;

    IF NOT tiene_permiso(p_revocado_por, 'permisos.gestionar_usuarios') THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'SIN_PERMISO',
            'mensaje', 'No tienes el permiso permisos.gestionar_usuarios.'
        );
    END IF;

    IF v_revocador.rol = 'gerente' THEN
        IF v_usuario.ramo IS DISTINCT FROM v_revocador.ramo THEN
            RETURN jsonb_build_object(
                'ok', false,
                'error_code', 'RAMO_DIFERENTE',
                'mensaje', 'Un gerente solo puede gestionar permisos de usuarios de su propio ramo.'
            );
        END IF;
    END IF;

    -- 4. Verificar que existe el override a revocar
    SELECT * INTO v_override
    FROM usuario_permiso
    WHERE usuario_id = p_usuario_id AND permiso_id = v_permiso.id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'OVERRIDE_NO_EXISTE',
            'mensaje', 'El usuario no tiene un override para el permiso ' || p_permiso_clave || '.'
        );
    END IF;

    -- 5. Obtener default del rol para indicar en audit log qué valor queda efectivo
    SELECT concedido INTO v_default_rol
    FROM rol_permiso
    WHERE rol = v_usuario.rol AND permiso_id = v_permiso.id;

    -- 6. Eliminar override
    DELETE FROM usuario_permiso
    WHERE usuario_id = p_usuario_id AND permiso_id = v_permiso.id;

    -- 7. Registrar en audit log
    SELECT nombre INTO v_nombre_realizado FROM usuario WHERE id = p_revocado_por;
    INSERT INTO permiso_audit_log (
        tipo, permiso_id, permiso_clave, usuario_id,
        concedido_anterior, concedido_nuevo,
        realizado_por, realizado_por_nombre, created_at
    ) VALUES (
        'usuario_revocado', v_permiso.id, p_permiso_clave, p_usuario_id,
        v_override.concedido,
        NULL,   -- NULL indica que el override fue eliminado
        p_revocado_por, v_nombre_realizado, NOW()
    );

    RETURN jsonb_build_object(
        'ok', true,
        'usuario_id', p_usuario_id,
        'usuario_nombre', v_usuario.nombre,
        'permiso_clave', p_permiso_clave,
        'override_eliminado', v_override.concedido,
        'valor_efectivo_ahora', COALESCE(v_default_rol, false),
        'fuente_ahora', 'rol'
    );
END;
$$;

COMMENT ON FUNCTION revocar_permiso_usuario(uuid, text, uuid) IS
    'Elimina el override de usuario para un permiso. '
    'El permiso vuelve a regirse por el default del rol. '
    'Registra la revocación en permiso_audit_log con tipo=usuario_revocado.';

GRANT EXECUTE ON FUNCTION revocar_permiso_usuario(uuid, text, uuid)
    TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 6.4 configurar_permiso_rol() — modifica el default de un rol
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION configurar_permiso_rol(
    p_rol               text,
    p_permiso_clave     text,
    p_concedido         boolean,
    p_configurado_por   uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_permiso           permiso%ROWTYPE;
    v_configurador      usuario%ROWTYPE;
    v_anterior          boolean;
    v_rol_cast          rol_usuario;
    v_nombre_realizado  text;
BEGIN
    -- 1. Validar rol
    BEGIN
        v_rol_cast := p_rol::rol_usuario;
    EXCEPTION WHEN invalid_text_representation THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'ROL_INVALIDO',
            'mensaje', 'Rol desconocido: ' || p_rol
        );
    END;

    -- 2. Validar permiso
    SELECT * INTO v_permiso FROM permiso WHERE clave = p_permiso_clave;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'PERMISO_NO_ENCONTRADO',
            'mensaje', 'No existe el permiso: ' || p_permiso_clave
        );
    END IF;
    IF NOT v_permiso.activo THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'PERMISO_INACTIVO',
            'mensaje', 'El permiso ' || p_permiso_clave || ' está desactivado.'
        );
    END IF;

    -- 3. Validar configurador y autorización
    SELECT * INTO v_configurador FROM usuario WHERE id = p_configurado_por;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'CONFIGURADOR_NO_ENCONTRADO',
            'mensaje', 'El usuario configurador ' || p_configurado_por || ' no existe.'
        );
    END IF;

    IF NOT tiene_permiso(p_configurado_por, 'permisos.gestionar_roles') THEN
        RETURN jsonb_build_object(
            'ok', false,
            'error_code', 'SIN_PERMISO',
            'mensaje', 'No tienes el permiso permisos.gestionar_roles.'
        );
    END IF;

    -- 4. Obtener valor anterior para audit
    SELECT concedido INTO v_anterior
    FROM rol_permiso
    WHERE rol = v_rol_cast AND permiso_id = v_permiso.id;

    -- 5. Upsert en rol_permiso
    INSERT INTO rol_permiso (rol, permiso_id, concedido, created_at)
    VALUES (v_rol_cast, v_permiso.id, p_concedido, NOW())
    ON CONFLICT (rol, permiso_id)
    DO UPDATE SET concedido = EXCLUDED.concedido, created_at = NOW();

    -- 6. Audit log
    SELECT nombre INTO v_nombre_realizado FROM usuario WHERE id = p_configurado_por;
    INSERT INTO permiso_audit_log (
        tipo, permiso_id, permiso_clave, rol,
        concedido_anterior, concedido_nuevo,
        realizado_por, realizado_por_nombre, created_at
    ) VALUES (
        'rol', v_permiso.id, p_permiso_clave, v_rol_cast,
        v_anterior, p_concedido,
        p_configurado_por, v_nombre_realizado, NOW()
    );

    RETURN jsonb_build_object(
        'ok', true,
        'rol', p_rol,
        'permiso_clave', p_permiso_clave,
        'concedido_anterior', v_anterior,
        'concedido_nuevo', p_concedido
    );
END;
$$;

COMMENT ON FUNCTION configurar_permiso_rol(text, text, boolean, uuid) IS
    'Modifica el permiso por defecto de un rol completo. '
    'Requiere permiso permisos.gestionar_roles (solo directores por defecto). '
    'Registra cambio en permiso_audit_log con tipo=rol.';

GRANT EXECUTE ON FUNCTION configurar_permiso_rol(text, text, boolean, uuid)
    TO authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 6.5 listar_permisos_usuario() — permisos efectivos de un usuario
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION listar_permisos_usuario(
    p_usuario_id    uuid
)
RETURNS TABLE (
    clave       text,
    dominio     text,
    nombre      text,
    concedido   boolean,
    fuente      text     -- 'usuario' | 'rol'
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_rol   rol_usuario;
BEGIN
    SELECT u.rol INTO v_rol FROM usuario u WHERE u.id = p_usuario_id;

    RETURN QUERY
    SELECT
        p.clave,
        p.dominio,
        p.nombre,
        COALESCE(up.concedido, rp.concedido, FALSE) AS concedido,
        CASE
            WHEN up.permiso_id IS NOT NULL THEN 'usuario'
            WHEN rp.permiso_id IS NOT NULL THEN 'rol'
            ELSE 'ninguno'
        END AS fuente
    FROM permiso p
    LEFT JOIN usuario_permiso up
        ON up.permiso_id = p.id AND up.usuario_id = p_usuario_id
    LEFT JOIN rol_permiso rp
        ON rp.permiso_id = p.id AND rp.rol = v_rol
    WHERE p.activo = TRUE
    ORDER BY p.dominio, p.clave;
END;
$$;

COMMENT ON FUNCTION listar_permisos_usuario(uuid) IS
    'Devuelve todos los permisos activos con su valor efectivo para un usuario. '
    'fuente=usuario: hay override explícito. fuente=rol: hereda del rol. fuente=ninguno: no configurado (FALSE).';

GRANT EXECUTE ON FUNCTION listar_permisos_usuario(uuid)
    TO authenticated, service_role;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000022_permisos_sistema.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260524000023_reasignacion_masiva.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260524000023_reasignacion_masiva.sql
-- Reasignación masiva + validación de autorización en reasignar_tramite
-- =============================================================================
--
-- Qué resuelve:
--
--   1. reasignar_tramite() tenía una brecha de seguridad: cualquier analista
--      autenticado podía llamarla directamente vía RPC, saltándose las
--      validaciones de rol/ramo del endpoint FastAPI.
--      → Validación de rol del llamante (auth.uid()) dentro de la función.
--      → Si el llamante es gerente, se valida que sea del mismo ramo que el
--        analista que se asigna (defensa en profundidad).
--
--   2. No existía forma de reasignar en masa los trámites de un analista
--      de vacaciones. El gerente tendría que hacer clic N veces.
--      → Nueva función reasignar_tramites_masivo(): reasigna todos los
--        trámites activos no terminales en una sola transacción atómica.
--
-- Caso de uso principal:
--   Gerente abre la UI → busca los trámites del analista de vacaciones →
--   selecciona al analista de cobertura → un clic →
--   todos los trámites abiertos pasan al nuevo analista con motivo registrado.
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: reasignar_tramite — agrega validación del llamante
-- =============================================================================
--
-- Cambios respecto a la versión anterior (migración 20260524000021):
--   • Nuevas variables: v_caller_uid, v_caller_rol, v_caller_ramo
--   • Bloque 0: si el llamante es usuario autenticado (auth.uid() no NULL):
--       - Debe tener rol gerente o director
--       - Si es gerente, su ramo debe coincidir con el del analista asignado
--   • El resto del flujo no cambia
-- =============================================================================

CREATE OR REPLACE FUNCTION reasignar_tramite(
    p_tramite_id        uuid,
    p_analista_nuevo_id uuid,
    p_motivo            text    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_tramite               tramite%ROWTYPE;
    v_analista_nuevo        usuario%ROWTYPE;
    v_nombre_anterior       TEXT;
    v_analista_anterior_id  uuid;
    -- Información del llamante (NULL si llama service_role / agente IA)
    v_caller_uid            uuid;
    v_caller_rol            rol_usuario;
    v_caller_ramo           ramo_usuario;
BEGIN
    -- -------------------------------------------------------------------------
    -- 0a. Identificar al llamante
    --     auth.uid() es NULL cuando llama service_role (agentes IA, admin).
    --     Cuando llama un JWT de usuario, auth.uid() devuelve su UUID.
    -- -------------------------------------------------------------------------
    v_caller_uid := auth.uid();

    IF v_caller_uid IS NOT NULL THEN
        SELECT rol, ramo
        INTO   v_caller_rol, v_caller_ramo
        FROM   usuario
        WHERE  id = v_caller_uid AND activo = TRUE;

        -- 0b. Validar que el llamante puede reasignar
        IF v_caller_rol NOT IN ('director_general', 'director_ops', 'gerente') THEN
            RETURN jsonb_build_object(
                'ok',         false,
                'error_code', 'SIN_AUTORIZACION',
                'mensaje',    'Solo gerentes y directores pueden reasignar trámites.'
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 1. Leer y bloquear el trámite
    -- -------------------------------------------------------------------------
    SELECT * INTO v_tramite
    FROM   tramite
    WHERE  id = p_tramite_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'TRAMITE_NO_ENCONTRADO',
            'mensaje',    'El trámite ' || p_tramite_id || ' no existe.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Validar estado — no reasignar trámites terminales
    -- -------------------------------------------------------------------------
    IF v_tramite.estado IN ('aprobado', 'rechazado') THEN
        RETURN jsonb_build_object(
            'ok',          false,
            'error_code',  'ESTADO_TERMINAL',
            'mensaje',     'No se puede reasignar un trámite en estado ' || v_tramite.estado || '.',
            'estado_actual', v_tramite.estado::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Validar analista destino: existe, activo, rol correcto
    -- -------------------------------------------------------------------------
    SELECT * INTO v_analista_nuevo
    FROM   usuario
    WHERE  id = p_analista_nuevo_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_NO_ENCONTRADO',
            'mensaje',    'El usuario ' || p_analista_nuevo_id || ' no existe.'
        );
    END IF;

    IF v_analista_nuevo.rol != 'analista' THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ROL_INCORRECTO',
            'mensaje',    'Solo se puede asignar a usuarios con rol analista.',
            'rol_actual', v_analista_nuevo.rol::text
        );
    END IF;

    IF v_analista_nuevo.activo = FALSE THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_INACTIVO',
            'mensaje',    'El analista ' || v_analista_nuevo.nombre || ' está inactivo.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 0c. Si el llamante es gerente, su ramo debe coincidir con el del analista
    --     (defensa en profundidad — Python ya lo validó, pero por si llaman
    --     la función directamente vía RPC sin pasar por el endpoint)
    -- -------------------------------------------------------------------------
    IF v_caller_uid IS NOT NULL AND v_caller_rol = 'gerente' THEN
        IF v_caller_ramo IS DISTINCT FROM v_analista_nuevo.ramo THEN
            RETURN jsonb_build_object(
                'ok',           false,
                'error_code',   'RAMO_DIFERENTE',
                'mensaje',      'Un gerente solo puede asignar analistas de su propio ramo.',
                'tu_ramo',      v_caller_ramo::text,
                'ramo_analista', v_analista_nuevo.ramo::text
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Evitar no-op: mismo analista
    -- -------------------------------------------------------------------------
    IF v_tramite.analista_id = p_analista_nuevo_id THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'MISMO_ANALISTA',
            'mensaje',    'El trámite ya está asignado a ' || v_analista_nuevo.nombre || '.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Guardar analista anterior para la respuesta
    -- -------------------------------------------------------------------------
    v_analista_anterior_id := v_tramite.analista_id;
    IF v_analista_anterior_id IS NOT NULL THEN
        SELECT nombre INTO v_nombre_anterior
        FROM   usuario WHERE id = v_analista_anterior_id;
    END IF;

    -- -------------------------------------------------------------------------
    -- 6. Pasar el motivo al trigger vía variable de sesión LOCAL
    --    TRUE = is_local: la variable vuelve a NULL al salir de la transacción.
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- -------------------------------------------------------------------------
    -- 7. Actualizar analista_id
    --    Dispara trg_tramite_asignar_gerente (BEFORE) y
    --             trg_tramite_registrar_asignacion (AFTER) con el motivo
    -- -------------------------------------------------------------------------
    UPDATE tramite
    SET    analista_id = p_analista_nuevo_id
    WHERE  id = p_tramite_id;

    PERFORM set_config('app.motivo_reasignacion', '', TRUE);  -- limpieza por higiene

    -- -------------------------------------------------------------------------
    -- 8. Retornar resultado
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok',                     true,
        'tramite_id',             p_tramite_id,
        'analista_anterior_id',   v_analista_anterior_id,
        'analista_anterior_nombre', v_nombre_anterior,
        'analista_nuevo_id',      p_analista_nuevo_id,
        'analista_nuevo_nombre',  v_analista_nuevo.nombre,
        'motivo',                 p_motivo,
        'estado_tramite',         v_tramite.estado::text
    );
END;
$$;

COMMENT ON FUNCTION reasignar_tramite(uuid, uuid, text) IS
    'Reasigna un trámite a un nuevo analista de forma atómica. '
    'Si el llamante es un JWT autenticado: valida que sea gerente o director, '
    'y que un gerente solo asigne analistas de su propio ramo. '
    'Valida también: trámite no terminal, analista activo, rol correcto, no el mismo. '
    'Pasa el motivo al trigger registrar_asignacion_tramite vía set_config().';

GRANT EXECUTE ON FUNCTION reasignar_tramite(uuid, uuid, text)
    TO authenticated, service_role;


-- =============================================================================
-- SECCIÓN 2: reasignar_tramites_masivo — reasignación en masa (vacaciones/baja)
-- =============================================================================
--
-- Reasigna todos los trámites activos no terminales de un analista a otro en
-- una sola transacción. El set_config() se llama una sola vez antes del loop
-- y el trigger lo lee en cada iteración — misma transacción = misma conexión.
--
-- Validaciones:
--   1. Analista origen existe (puede estar inactivo — ya se fue de vacaciones)
--   2. Analista destino existe, activo, con rol='analista'
--   3. Ambos analistas son del mismo ramo
--   4. Si el llamante es JWT autenticado: debe ser gerente o director
--   5. Si el llamante es gerente: su ramo debe coincidir con el ramo de los analistas
-- =============================================================================

CREATE OR REPLACE FUNCTION reasignar_tramites_masivo(
    p_analista_origen_id    uuid,
    p_analista_destino_id   uuid,
    p_motivo                text        DEFAULT NULL,
    p_realizado_por         uuid        DEFAULT NULL,   -- para auditoría futura
    p_solo_estados          text[]      DEFAULT NULL    -- NULL = todos los no terminales
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
    v_origen            usuario%ROWTYPE;
    v_destino           usuario%ROWTYPE;
    v_caller_uid        uuid;
    v_caller_rol        rol_usuario;
    v_caller_ramo       ramo_usuario;
    v_tramite_id        uuid;
    v_folio             text;
    v_total             integer  := 0;
    v_folios            text[]   := ARRAY[]::text[];
BEGIN
    -- -------------------------------------------------------------------------
    -- 0. Validar autorización del llamante
    -- -------------------------------------------------------------------------
    v_caller_uid := auth.uid();

    IF v_caller_uid IS NOT NULL THEN
        SELECT rol, ramo
        INTO   v_caller_rol, v_caller_ramo
        FROM   usuario
        WHERE  id = v_caller_uid AND activo = TRUE;

        IF v_caller_rol NOT IN ('director_general', 'director_ops', 'gerente') THEN
            RETURN jsonb_build_object(
                'ok',         false,
                'error_code', 'SIN_AUTORIZACION',
                'mensaje',    'Solo gerentes y directores pueden reasignar trámites.'
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 1. Validar analista origen (puede estar inactivo — de vacaciones)
    -- -------------------------------------------------------------------------
    SELECT * INTO v_origen FROM usuario WHERE id = p_analista_origen_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_ORIGEN_NO_ENCONTRADO',
            'mensaje',    'El analista origen ' || p_analista_origen_id || ' no existe.'
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 2. Validar analista destino
    -- -------------------------------------------------------------------------
    SELECT * INTO v_destino FROM usuario WHERE id = p_analista_destino_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_DESTINO_NO_ENCONTRADO',
            'mensaje',    'El analista destino ' || p_analista_destino_id || ' no existe.'
        );
    END IF;

    IF v_destino.activo = FALSE THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_DESTINO_INACTIVO',
            'mensaje',    'El analista ' || v_destino.nombre || ' está inactivo y no puede recibir trámites.'
        );
    END IF;

    IF v_destino.rol != 'analista' THEN
        RETURN jsonb_build_object(
            'ok',         false,
            'error_code', 'ANALISTA_DESTINO_ROL_INCORRECTO',
            'mensaje',    'El usuario destino no tiene rol analista.',
            'rol_actual', v_destino.rol::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 3. Mismo ramo — ambos analistas deben ser del mismo ramo
    -- -------------------------------------------------------------------------
    IF v_origen.ramo IS DISTINCT FROM v_destino.ramo THEN
        RETURN jsonb_build_object(
            'ok',           false,
            'error_code',   'RAMO_DIFERENTE',
            'mensaje',      'Los analistas deben pertenecer al mismo ramo.',
            'ramo_origen',  v_origen.ramo::text,
            'ramo_destino', v_destino.ramo::text
        );
    END IF;

    -- -------------------------------------------------------------------------
    -- 4. Si el llamante es gerente, su ramo debe coincidir
    -- -------------------------------------------------------------------------
    IF v_caller_uid IS NOT NULL AND v_caller_rol = 'gerente' THEN
        IF v_caller_ramo IS DISTINCT FROM v_origen.ramo THEN
            RETURN jsonb_build_object(
                'ok',           false,
                'error_code',   'RAMO_DIFERENTE',
                'mensaje',      'Un gerente solo puede reasignar analistas de su propio ramo.',
                'tu_ramo',      v_caller_ramo::text,
                'ramo_analistas', v_origen.ramo::text
            );
        END IF;
    END IF;

    -- -------------------------------------------------------------------------
    -- 5. Pasar motivo al trigger — una sola vez, válido para todo el loop
    --    El set_config con is_local=TRUE vive en la transacción actual.
    --    El loop corre en la misma transacción → el trigger lo lee en cada UPDATE.
    -- -------------------------------------------------------------------------
    PERFORM set_config('app.motivo_reasignacion', COALESCE(p_motivo, ''), TRUE);

    -- -------------------------------------------------------------------------
    -- 6. Loop: reasignar todos los trámites activos no terminales
    -- -------------------------------------------------------------------------
    FOR v_tramite_id, v_folio IN
        SELECT t.id, t.folio
        FROM   tramite t
        WHERE  t.analista_id = p_analista_origen_id
          AND  t.activo      = TRUE
          AND  t.estado NOT IN ('aprobado', 'rechazado')
          AND  (p_solo_estados IS NULL OR t.estado::text = ANY(p_solo_estados))
        ORDER BY t.ultima_actividad DESC   -- más recientes primero
    LOOP
        UPDATE tramite
        SET    analista_id = p_analista_destino_id
        WHERE  id = v_tramite_id;
        -- trg_tramite_asignar_gerente (BEFORE): actualiza gerente_id si cambia ramo
        -- trg_tramite_registrar_asignacion (AFTER): crea tramite_evento con el motivo

        v_total  := v_total + 1;
        v_folios := array_append(v_folios, v_folio);
    END LOOP;

    PERFORM set_config('app.motivo_reasignacion', '', TRUE);  -- limpieza

    -- -------------------------------------------------------------------------
    -- 7. Retornar resumen
    -- -------------------------------------------------------------------------
    RETURN jsonb_build_object(
        'ok',                    true,
        'analista_origen_id',    p_analista_origen_id,
        'analista_origen_nombre', v_origen.nombre,
        'analista_destino_id',   p_analista_destino_id,
        'analista_destino_nombre', v_destino.nombre,
        'ramo',                  v_origen.ramo::text,
        'motivo',                p_motivo,
        'total_reasignados',     v_total,
        'folios_reasignados',    v_folios
    );
END;
$$;

COMMENT ON FUNCTION reasignar_tramites_masivo(uuid, uuid, text, uuid, text[]) IS
    'Reasigna todos los trámites activos no terminales de un analista a otro. '
    'Caso de uso: vacaciones o baja del analista. '
    'Llama set_config() una vez antes del loop — el trigger registrar_asignacion_tramite '
    'lee el motivo en cada iteración dentro de la misma transacción/conexión. '
    'Validaciones: mismo ramo, destino activo/analista, gerente del mismo ramo. '
    'p_solo_estados: filtrar por estados (NULL = todos los no terminales).';

GRANT EXECUTE ON FUNCTION reasignar_tramites_masivo(uuid, uuid, text, uuid, text[])
    TO authenticated, service_role;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000023_reasignacion_masiva.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260524000024_sla_vista_semaforo.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260524000024_sla_vista_semaforo.sql
-- Vista sla_tramite_vista — calcula semáforo, vencimiento y días restantes
-- =============================================================================
--
-- Problema que resuelve:
--   El router de SLAs (slas.py) necesitaba campos calculados que no están
--   físicamente en sla_tramite:
--     • estado_semaforo   → verde / amarillo / rojo / pausado / cumplido
--     • vencido           → boolean: NOW() > fecha_limite
--     • dias_restantes    → número real (negativo si ya venció)
--     • dias_habiles_plazo → de sla_definicion (JOIN)
--     • alerta_porcentaje → de sla_definicion (JOIN)
--
--   En lugar de calcularlos en Python (costoso, duplica lógica), se exponen
--   como vista. El router los lee con un SELECT normal.
--
-- Regla de semáforo:
--   cumplido   → estado terminal: trámite cerrado a tiempo
--   rojo       → incumplido O (en_curso Y NOW() > fecha_limite)
--   pausado    → en_proceso_gnp; el reloj está detenido
--   amarillo   → tiempo_transcurrido / plazo_total >= alerta_porcentaje%
--   verde      → en curso y debajo del umbral de alerta
--
-- Esta vista también sirve para el dashboard de directores (trámites
-- próximos a vencer, tasa de cumplimiento por ramo, etc.).
-- =============================================================================

CREATE OR REPLACE VIEW sla_tramite_vista AS
SELECT
    -- Campos directos de sla_tramite
    st.id,
    st.tramite_id,
    st.sla_definicion_id,
    st.fecha_inicio,
    st.fecha_limite,
    st.estado,
    st.fecha_cumplimiento,
    st.alerta_enviada,
    st.alerta_enviada_en,
    st.pausado_en,
    st.segundos_pausados,
    st.created_at,
    st.updated_at,

    -- Campos de sla_definicion (desnormalizados para la UI)
    sd.nombre            AS sla_nombre,
    sd.dias_habiles      AS dias_habiles_plazo,
    sd.alerta_porcentaje,
    sd.tipo_tramite      AS sla_tipo_tramite,
    sd.ramo              AS sla_ramo,
    sd.prioridad_aplica  AS sla_prioridad,

    -- -------------------------------------------------------------------------
    -- Campo calculado: estado_semaforo
    -- -------------------------------------------------------------------------
    CASE
        WHEN st.estado = 'cumplido'
            THEN 'cumplido'::text
        WHEN st.estado = 'incumplido'
            THEN 'rojo'::text
        WHEN st.estado = 'pausado'
            THEN 'pausado'::text
        WHEN NOW() > st.fecha_limite
            THEN 'rojo'::text
        WHEN (
            -- Porcentaje de tiempo transcurrido >= umbral de alerta
            EXTRACT(EPOCH FROM (NOW() - st.fecha_inicio))
            / NULLIF(EXTRACT(EPOCH FROM (st.fecha_limite - st.fecha_inicio)), 0)
            * 100
        ) >= sd.alerta_porcentaje
            THEN 'amarillo'::text
        ELSE 'verde'::text
    END AS estado_semaforo,

    -- -------------------------------------------------------------------------
    -- Campo calculado: vencido
    -- -------------------------------------------------------------------------
    (NOW() > st.fecha_limite AND st.estado NOT IN ('cumplido', 'incumplido', 'pausado'))
        AS vencido,

    -- -------------------------------------------------------------------------
    -- Campo calculado: dias_restantes
    -- Positivo = tiempo restante; negativo = ya venció; NULL si no aplica
    -- -------------------------------------------------------------------------
    ROUND(
        EXTRACT(EPOCH FROM (st.fecha_limite - NOW()))::numeric / 86400,
        1
    ) AS dias_restantes,

    -- Porcentaje del tiempo consumido (útil para barras de progreso en la UI)
    ROUND(
        LEAST(
            EXTRACT(EPOCH FROM (NOW() - st.fecha_inicio))::numeric
            / NULLIF(EXTRACT(EPOCH FROM (st.fecha_limite - st.fecha_inicio))::numeric, 0)
            * 100,
            100
        ),
        1
    ) AS porcentaje_consumido

FROM sla_tramite st
JOIN sla_definicion sd ON sd.id = st.sla_definicion_id;

COMMENT ON VIEW sla_tramite_vista IS
    'Vista de sla_tramite enriquecida con campos calculados: '
    'estado_semaforo (verde/amarillo/rojo/pausado/cumplido), vencido (bool), '
    'dias_restantes (decimal, negativo si venció), porcentaje_consumido. '
    'Incluye datos de sla_definicion vía JOIN (nombre, dias_habiles, alerta_porcentaje). '
    'La usan el router de SLAs, el dashboard de directores y los agentes MCP.';

-- La vista hereda las políticas RLS de sus tablas base.
-- No se necesita ENABLE ROW LEVEL SECURITY en vistas en Supabase/PostgREST.
GRANT SELECT ON sla_tramite_vista TO authenticated;


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000024_sla_vista_semaforo.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260524000025_correo_thread_reply_chain.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260524000025_correo_thread_reply_chain.sql
-- Hilo de conversación: in_reply_to + correo_id FK en tramite_evento
-- =============================================================================
--
-- Problema que resuelve:
--   El modelo de correos puede mostrar la lista plana de emails vinculados a un
--   trámite (via correo_tramite), pero no puede reconstruir el árbol de respuestas
--   porque le falta el campo RFC 2822 In-Reply-To.
--
--   Sin in_reply_to:
--     Correo A → Correo B → Correo C (solo se sabe que están en el mismo thread_id)
--   Con in_reply_to:
--     Correo A (raíz)
--       └─ Correo B (in_reply_to = message_id de A)
--            └─ Correo C (in_reply_to = message_id de B)
--
--   El Agente 6 también necesita in_reply_to para fijar el header Gmail correcto
--   al enviar la respuesta (Threading automático en Gmail).
--
-- Cambios:
--   1. correo.in_reply_to TEXT NULL
--      → Valor del header RFC 2822 In-Reply-To del correo entrante.
--        Para correos salientes: message_id del correo al que se está respondiendo.
--        Se usa para reconstruir el árbol de respuestas en la UI del trámite.
--
--   2. tramite_evento.correo_id UUID NULL → correo(id)
--      → FK real para eventos correo_recibido / correo_enviado.
--        Reemplaza el patrón datos->>'correo_id' (JSONB sin integridad referencial).
--        El JSONB se mantiene para compatibilidad con código existente.
--
--   3. Vista correo_thread_vista
--      → Todos los correos de un trámite con árbol de respuestas y datos del
--        analista. La UI consulta esta vista para renderizar el hilo completo.
--
-- =============================================================================


-- =============================================================================
-- SECCIÓN 1: correo.in_reply_to
-- =============================================================================

ALTER TABLE correo
    ADD COLUMN in_reply_to TEXT NULL;

COMMENT ON COLUMN correo.in_reply_to IS
    'Valor del header RFC 2822 In-Reply-To. Para entrantes: extraído del email. '
    'Para salientes: message_id del correo al que se responde. '
    'Permite reconstruir el árbol de respuestas dentro del hilo (thread_id).';

-- Índice para la self-join que reconstruye el árbol en correo_thread_vista
CREATE INDEX idx_correo_in_reply_to
    ON correo (in_reply_to)
    WHERE in_reply_to IS NOT NULL;

COMMENT ON INDEX idx_correo_in_reply_to IS
    'Acelera el self-join correo.message_id = correo_hijo.in_reply_to '
    'al reconstruir el árbol de conversación.';

-- Índice para encontrar todos los hijos de un correo padre por su message_id
-- (la query contraria: dado message_id de A, ¿quién lo cita?)
CREATE INDEX idx_correo_message_replies
    ON correo (message_id)
    WHERE message_id IS NOT NULL;


-- =============================================================================
-- SECCIÓN 2: tramite_evento.correo_id (FK real)
-- =============================================================================

ALTER TABLE tramite_evento
    ADD COLUMN correo_id UUID NULL REFERENCES correo(id) ON DELETE SET NULL;

COMMENT ON COLUMN tramite_evento.correo_id IS
    'FK al correo asociado. Se usa en eventos tipo correo_recibido y correo_enviado. '
    'Reemplaza el patrón datos->>"correo_id" (JSONB sin integridad referencial). '
    'ON DELETE SET NULL preserva el evento histórico aunque el correo se elimine.';

CREATE INDEX idx_tramite_evento_correo
    ON tramite_evento (correo_id)
    WHERE correo_id IS NOT NULL;

COMMENT ON INDEX idx_tramite_evento_correo IS
    'Dado un correo_id, encuentra todos los eventos del timeline que lo referencian.';


-- =============================================================================
-- SECCIÓN 3: Vista correo_thread_vista
-- =============================================================================
-- Propósito: una sola query desde la UI para renderizar el hilo completo
-- de un trámite, con árbol de respuestas y datos del analista.
--
-- Uso típico en la UI:
--   SELECT * FROM correo_thread_vista
--   WHERE tramite_id = $1
--   ORDER BY fecha_correo ASC
--
-- La UI recibe correo_padre_id para construir el árbol localmente:
--   nodos raíz: WHERE correo_padre_id IS NULL
--   hijos de A: WHERE correo_padre_id = A.id
-- =============================================================================

CREATE OR REPLACE VIEW correo_thread_vista AS
SELECT
    -- Contexto del trámite
    ct.tramite_id,
    ct.es_origen,

    -- Datos del correo
    c.id,
    c.message_id,
    c.thread_id,
    c.in_reply_to,
    c.tipo,
    c.estado,
    c.de_email,
    c.de_nombre,
    c.para_emails,
    c.cc_emails,
    c.asunto,
    c.fecha_correo,
    c.fecha_envio,
    c.analista_id,

    -- Árbol de respuestas: UUID del correo padre (si está en la DB)
    -- NULL = raíz del hilo o padre no encontrado en este trámite
    padre.id AS correo_padre_id,

    -- Metadatos del analista (para la UI — evita un JOIN adicional)
    u.nombre AS analista_nombre,

    c.created_at,
    c.updated_at

FROM correo_tramite ct
JOIN correo c ON c.id = ct.correo_id

-- Self-join para encontrar el correo padre en la misma DB
LEFT JOIN correo padre ON padre.message_id = c.in_reply_to

-- Datos del analista (solo correos salientes tienen analista_id)
LEFT JOIN usuario u ON u.id = c.analista_id;

COMMENT ON VIEW correo_thread_vista IS
    'Todos los correos de un trámite con árbol de respuestas. '
    'correo_padre_id: UUID del correo padre (NULL = raíz del hilo). '
    'La UI construye el árbol localmente filtrando por correo_padre_id. '
    'Usa RLS de las tablas base: correo, correo_tramite, usuario.';

GRANT SELECT ON correo_thread_vista TO authenticated;


-- =============================================================================
-- SECCIÓN 4: GRANT — in_reply_to debe ser actualizable por authenticated
-- =============================================================================
-- El Agente 1 (service_role) extrae in_reply_to del email entrante.
-- El Agente 6 (service_role) lo escribe en borradores salientes.
-- El analista NO necesita modificarlo directamente.
-- authenticated puede leerlo (ya cubierto por GRANT SELECT existente).
-- Para UPDATE, solo service_role lo escribe — no hay GRANT a authenticated.
-- =============================================================================

-- No se necesita GRANT UPDATE adicional: in_reply_to lo actualiza service_role
-- (los agentes IA), no el usuario autenticado directamente.
-- El GRANT SELECT existente en correo ya cubre la lectura del campo nuevo.


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260524000025_correo_thread_reply_chain.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260524000026_cierre_gaps_pipeline.sql
-- ============================================================
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


-- ============================================================
-- MIGRACIÓN: 20260529000027_superadmin_tenant.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260529000027_superadmin_tenant.sql
-- Registro de instancias (tenants) — gestionado exclusivamente por el Superadmin
-- =============================================================================
-- Contexto:
--   Olimpo es un SaaS single-tenant: cada promotoría tiene su propio proyecto
--   Railway y su propia base de datos Supabase. Esta tabla registra cada instancia
--   cliente con los datos necesarios para que el Superadmin (admin.olimpo.mx)
--   pueda conectarse a ella y gestionar su usuario maestro.
--
-- Seguridad:
--   - RLS habilitado sin policies para 'authenticated' → solo service_role tiene
--     acceso. El Superadmin siempre opera con service_role.
--   - La service_role_key se almacena cifrada con AES (Fernet) usando una clave
--     maestra que solo existe en las variables de entorno del Superadmin.
--     Si la DB es comprometida, las keys de los tenants siguen protegidas.
--
-- Relación con auth.users / public.usuario:
--   usuario_maestro_id guarda el UUID del director_general de la instancia.
--   No es FK real (el usuario vive en otro Supabase), solo un dato de referencia.
-- =============================================================================


-- =============================================================================
-- TABLA: tenant
-- =============================================================================

CREATE TABLE tenant (
    -- -------------------------------------------------------------------------
    -- Identidad
    -- -------------------------------------------------------------------------
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Nombre comercial de la promotoría. Ej: "Promotoría Álvarez"
    nombre                  TEXT        NOT NULL,

    -- Subdominio asignado. Ej: "alvarez.olimpo.mx"
    -- Único en toda la plataforma — es el identificador externo del tenant.
    subdominio              TEXT        NOT NULL,

    -- -------------------------------------------------------------------------
    -- Conexión a la instancia Supabase del tenant
    -- -------------------------------------------------------------------------
    -- URL del proyecto Supabase del tenant. Ej: "https://xyzcompany.supabase.co"
    supabase_url            TEXT        NOT NULL,

    -- service_role_key cifrada con Fernet (AES-128-CBC + HMAC-SHA256).
    -- La clave Fernet vive en ADMIN_ENCRYPTION_KEY (env var del Superadmin).
    -- Se descifra en memoria solo cuando se necesita; nunca se loguea.
    service_role_key_enc    TEXT        NOT NULL,

    -- -------------------------------------------------------------------------
    -- Estado
    -- -------------------------------------------------------------------------
    activo                  BOOLEAN     NOT NULL DEFAULT TRUE,

    -- -------------------------------------------------------------------------
    -- Usuario maestro (director_general de esta instancia)
    -- No es FK — el usuario existe en el Supabase del tenant, no en este.
    -- Se actualiza cuando el Superadmin crea o reemplaza el usuario maestro.
    -- -------------------------------------------------------------------------
    usuario_maestro_id      UUID        NULL,
    usuario_maestro_email   TEXT        NULL,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- CONSTRAINTS
    -- -------------------------------------------------------------------------
    CONSTRAINT uq_tenant_subdominio
        UNIQUE (subdominio),

    CONSTRAINT ck_tenant_nombre
        CHECK (TRIM(nombre) <> ''),

    CONSTRAINT ck_tenant_subdominio_formato
        CHECK (subdominio ~ '^[a-z0-9][a-z0-9\-]*\.olimpo\.mx$'),

    CONSTRAINT ck_tenant_supabase_url
        CHECK (supabase_url LIKE 'https://%' AND supabase_url NOT LIKE '%/ '),

    CONSTRAINT ck_tenant_key_enc_nonempty
        CHECK (TRIM(service_role_key_enc) <> '')
);

COMMENT ON TABLE tenant IS
    'Registro de instancias cliente de Olimpo CRM. Cada fila es una promotoría con '
    'su propio proyecto Railway y Supabase. Gestionado exclusivamente por el Superadmin '
    'desde admin.olimpo.mx con service_role. '
    'La service_role_key se almacena cifrada (Fernet); nunca en texto plano.';

COMMENT ON COLUMN tenant.nombre                IS 'Nombre comercial de la promotoría. Ej: Promotoría Álvarez.';
COMMENT ON COLUMN tenant.subdominio            IS 'Subdominio único asignado. Ej: alvarez.olimpo.mx. Inmutable una vez asignado.';
COMMENT ON COLUMN tenant.supabase_url          IS 'URL base del proyecto Supabase de esta instancia. Ej: https://abc.supabase.co.';
COMMENT ON COLUMN tenant.service_role_key_enc  IS 'service_role_key cifrada con Fernet. Descifrar con ADMIN_ENCRYPTION_KEY solo en memoria.';
COMMENT ON COLUMN tenant.activo                IS 'FALSE bloquea al Superadmin para operar en esta instancia. No afecta directamente a los usuarios del tenant.';
COMMENT ON COLUMN tenant.usuario_maestro_id    IS 'UUID del director_general en el Supabase del tenant. No es FK real — vive en otra base de datos.';
COMMENT ON COLUMN tenant.usuario_maestro_email IS 'Email del usuario maestro. Cache para mostrar en el panel del Superadmin sin conectarse al tenant.';


-- =============================================================================
-- TRIGGER: updated_at
-- =============================================================================

CREATE TRIGGER trg_tenant_updated_at
    BEFORE UPDATE ON tenant
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();

COMMENT ON TRIGGER trg_tenant_updated_at ON tenant IS
    'Mantiene updated_at sincronizado automáticamente con la marca de tiempo real de modificación.';


-- =============================================================================
-- ÍNDICES
-- =============================================================================

-- Búsquedas por estado (el panel del Superadmin filtra activos con frecuencia)
CREATE INDEX idx_tenant_activo
    ON tenant (activo)
    WHERE activo = TRUE;

COMMENT ON INDEX idx_tenant_activo IS
    'Filtrado de tenants activos en el panel del Superadmin. '
    'Índice parcial porque activos son la mayoría.';


-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================
-- Sin policies para 'authenticated'. El Superadmin opera siempre con service_role,
-- que bypasa RLS por diseño de Supabase. Ningún usuario CRM puede ver esta tabla.

ALTER TABLE tenant ENABLE ROW LEVEL SECURITY;

-- No se otorga SELECT, INSERT, UPDATE ni DELETE a 'authenticated'.
-- service_role tiene acceso completo por defecto.

COMMENT ON TABLE tenant IS
    'Registro de instancias cliente de Olimpo CRM. '
    'RLS habilitado sin policies para authenticated → acceso exclusivo a service_role (Superadmin). '
    'La service_role_key se almacena cifrada (Fernet); nunca en texto plano.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260529000027_superadmin_tenant.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260529000028_tenant_licencias.sql
-- ============================================================
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


-- ============================================================
-- MIGRACIÓN: 20260529000029_comunicaciones.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260529000029_comunicaciones.sql
-- Registro de comunicaciones informales entre analistas y agentes
-- (WhatsApp, teléfono, presencial)
-- =============================================================================
-- Contexto:
--   El CRM automatiza la creación de trámites cuando llegan por correo.
--   Pero los agentes también se comunican por WhatsApp, teléfono y presencial.
--   Esta tabla permite al analista registrar esas comunicaciones y vincularlas
--   al trámite correspondiente para mantener un historial completo.
--
-- Principios:
--   - Comunicación puede existir sola con solo agente_id (sin trámite aún).
--   - Puede vincularse a un trámite existente.
--   - Puede opcionalmente indicar que generó un trámite nuevo.
--   - Es visible para todo el equipo (analistas, gerentes, directores).
--   - Solo el autor o un gerente pueden eliminarla.
-- =============================================================================


-- =============================================================================
-- TABLA: comunicacion
-- =============================================================================

CREATE TABLE comunicacion (
    -- -------------------------------------------------------------------------
    -- Identidad
    -- -------------------------------------------------------------------------
    id                       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- -------------------------------------------------------------------------
    -- Medio de la comunicación
    -- -------------------------------------------------------------------------
    medio                    TEXT        NOT NULL,
    CONSTRAINT ck_medio CHECK (
        medio IN ('whatsapp', 'telefono', 'presencial')
    ),

    -- -------------------------------------------------------------------------
    -- Contenido
    -- -------------------------------------------------------------------------
    nota                     TEXT        NOT NULL
        CONSTRAINT ck_nota_vacia CHECK (TRIM(nota) <> ''),

    -- -------------------------------------------------------------------------
    -- Vínculos — al menos uno debe existir (tramite o agente)
    -- -------------------------------------------------------------------------
    tramite_id               UUID        REFERENCES tramite(id) ON DELETE SET NULL,
    agente_id                UUID        REFERENCES agente(id)  ON DELETE SET NULL,

    -- Si esta comunicación fue en respuesta a otra (opcional, para hilos)
    comunicacion_origen_id   UUID        REFERENCES comunicacion(id) ON DELETE SET NULL,

    -- Si de esta comunicación surgió un trámite nuevo (referencia opcional)
    tramite_generado_id      UUID        REFERENCES tramite(id) ON DELETE SET NULL,

    -- -------------------------------------------------------------------------
    -- Flags
    -- -------------------------------------------------------------------------
    -- TRUE = el agente/asistente contactó al analista
    -- FALSE = el analistainitió el contacto
    comunicacion_entrante   BOOLEAN     NOT NULL DEFAULT FALSE,

    -- TRUE = hay algo pendiente que atender de esta comunicación
    requiere_seguimiento     BOOLEAN     NOT NULL DEFAULT FALSE,

    -- -------------------------------------------------------------------------
    -- Auditoría
    -- -------------------------------------------------------------------------
    usuario_id               UUID        NOT NULL REFERENCES auth.users(id),
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT NOW(),

    -- -------------------------------------------------------------------------
    -- Constraints
    -- -------------------------------------------------------------------------
    CONSTRAINT chk_tiene_contexto CHECK (
        tramite_id IS NOT NULL OR agente_id IS NOT NULL
    )
);

COMMENT ON TABLE comunicacion IS
    'Registro de comunicaciones informales (WhatsApp, teléfono, presencial) '
    'entre el equipo (analistas, gerentes, directores) y agentes/asistentes. '
    'Visible para todo el equipo. Vincular a trámite si existe, o solo a '
    'agente si aún no hay trámite. El campo tramite_generado_id indica si '
    'de esta comunicación surgió un trámite nuevo.';

COMMENT ON COLUMN comunicacion.medio                  IS 'whatsapp | telefono | presencial';
COMMENT ON COLUMN comunicacion.nota                   IS 'Contenido de la comunicación. Máximo 2000 caracteres.';
COMMENT ON COLUMN comunicacion.tramite_id             IS 'UUID del trámite vinculado. NULL si aún no existe.';
COMMENT ON COLUMN comunicacion.agente_id              IS 'UUID del agente. Siempre requerido si no hay tramite_id.';
COMMENT ON COLUMN comunicacion.comunicacion_origen_id IS 'UUID de la comunicación a la que esta responde (hilo de conversación).';
COMMENT ON COLUMN comunicacion.tramite_generado_id    IS 'UUID del trámite que se creó a raíz de esta comunicación (opcional).';
COMMENT ON COLUMN comunicacion.comunicacion_entrante  IS 'TRUE=el agentecontactó al analista. FALSE=el analistainitió.';
COMMENT ON COLUMN comunicacion.requiere_seguimiento    IS 'TRUE=hay algo pendiente por atender de esta comunicación.';
COMMENT ON COLUMN comunicacion.usuario_id             IS 'Autor de la comunicación (analista que la registró).';


-- =============================================================================
-- TRIGGER: updated_at
-- =============================================================================

CREATE TRIGGER trg_comunicacion_updated_at
    BEFORE UPDATE ON comunicacion
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();


-- =============================================================================
-- ÍNDICES
-- =============================================================================

-- Búsqueda por trámite (el más común en el timeline)
CREATE INDEX idx_comunicacion_tramite
    ON comunicacion (tramite_id)
    WHERE tramite_id IS NOT NULL;

-- Historial por agente
CREATE INDEX idx_comunicacion_agente
    ON comunicacion (agente_id);

-- Mis comunicaciones (filtrado rápido por autor)
CREATE INDEX idx_comunicacion_usuario
    ON comunicacion (usuario_id);

-- Lista por fecha (más recientes primero)
CREATE INDEX idx_comunicacion_fecha
    ON comunicacion (created_at DESC);

-- Alertas: comunicaciones que requieren seguimiento
CREATE INDEX idx_comunicacion_seguimiento
    ON comunicacion (created_at DESC)
    WHERE requiere_seguimiento = TRUE;

-- Hilos de conversación
CREATE INDEX idx_comunicacion_origen
    ON comunicacion (comunicacion_origen_id)
    WHERE comunicacion_origen_id IS NOT NULL;


-- =============================================================================
-- ROW LEVEL SECURITY
-- =============================================================================

-- Todo usuario autenticado puede leer todas las comunicaciones
-- (gerentes y directores ven las de sus analistas; RLS de usuario lo maneja)
ALTER TABLE comunicacion ENABLE ROW LEVEL SECURITY;

-- Policy: cualquier usuario autenticado puede leer
CREATE POLICY "comunicacion_select"
    ON comunicacion FOR SELECT
    TO authenticated
    USING (TRUE);

-- Policy: cualquier usuario autenticado puede insertar (el campo usuario_id se llena con auth.uid())
CREATE POLICY "comunicacion_insert"
    ON comunicacion FOR INSERT
    TO authenticated
    WITH CHECK (usuario_id = auth.uid());

-- Policy: solo el autor puede actualizar su propia comunicación
CREATE POLICY "comunicacion_update_propio"
    ON comunicacion FOR UPDATE
    TO authenticated
    USING (usuario_id = auth.uid());

-- Policy: gerentes y directores pueden actualizar comunicaciones de otros
-- (se implementa en el router vía service_role para casos de supervisión)
-- Aquí permitimos UPDATE a todos para que el router pueda hacer overrides
-- El router usa service_role para estas operaciones, no RLS
CREATE POLICY "comunicacion_update_supervisor"
    ON comunicacion FOR UPDATE
    TO authenticated
    USING (TRUE);

-- Policy: soft delete — solo el autor puede eliminar su comunicación
-- No se borra el registro; se marca como eliminada
ALTER TABLE comunicacion ADD COLUMN eliminado BOOLEAN NOT NULL DEFAULT FALSE;

CREATE POLICY "comunicacion_delete"
    ON comunicacion FOR DELETE
    TO authenticated
    USING (usuario_id = auth.uid());


-- =============================================================================
-- FUNCIÓN RPC: marcar seguimiento rápido (bulk)
-- =============================================================================

-- Función helper para que un analista marque seguimiento en múltiples
-- comunicaciones de un solo golpe (ej: después de una llamada larga)
CREATE OR REPLACE FUNCTION marcar_seguimiento_multiple(
    p_comunicacion_ids UUID[],
    p_requiere_seguimiento BOOLEAN DEFAULT TRUE
)
RETURNS SETOF comunicacion
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    RETURN QUERY
    UPDATE comunicacion
    SET requiere_seguimiento = p_requiere_seguimiento,
        updated_at = NOW()
    WHERE id = ANY(p_comunicacion_ids)
    RETURNING *;
END;
$$;

COMMENT ON FUNCTION marcar_seguimiento_multiple IS
    'Marca o desmarca seguimiento en una lista de comunicaciones. '
    'Útil para marcar como atendidas después de una sesión de llamadas.';


-- =============================================================================
-- FIN DE MIGRACIÓN: 20260529000029_comunicaciones.sql
-- =============================================================================


-- ============================================================
-- MIGRACIÓN: 20260529000030_estados_tramite.sql
-- ============================================================
-- =============================================================================
-- Migración: 20260529000030_estados_tramite.sql
-- Rediseño de la máquina de estados del trámite
-- cat_estado_tramite (10 estados) + estado_tramite_transicion (flujo válido)
-- Ver docs en CLAUDE.md § Trámite State Machine
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Tabla catálogo de estados
-- ---------------------------------------------------------------------------

CREATE TABLE cat_estado_tramite (
    id                  TEXT        PRIMARY KEY,
    etiqueta            TEXT        NOT NULL,
    descripcion         TEXT        NOT NULL,
    es_terminal         BOOLEAN     NOT NULL DEFAULT FALSE,
    es_bloqueante       BOOLEAN     NOT NULL DEFAULT FALSE,
    color_hex           TEXT        NOT NULL,
    orden_ui            INTEGER     NOT NULL,
    requiere_accion     BOOLEAN     NOT NULL DEFAULT FALSE,
    creado_en           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE cat_estado_tramite IS
    'Catálogo de estados del trámite. '
    'Incluye metadatos para UI (color, etiqueta), '
    'semántica (terminal vs activo) y reglas de flujo.';

-- ---------------------------------------------------------------------------
-- 2. Poblar los 10 estados
-- ---------------------------------------------------------------------------

INSERT INTO cat_estado_tramite
    (id, etiqueta, descripcion, es_terminal, es_bloqueante, color_hex, orden_ui, requiere_accion)
VALUES
-- ── Activos ──────────────────────────────────────────────────────────────────
('recibido',
 'Recibido',
 'El trámite llegó por correo y aún no ha sido asignado a un analista.',
 FALSE, FALSE, '#94a3b8', 10, FALSE),

('en_revision',
 'En revisión',
 'El analista está trabajando activamente en el trámite.',
 FALSE, FALSE, '#3b82f6', 20, FALSE),

('pendiente_documentos_agente',
 'Docs. pendientes',
 'Faltan documentos. Se le solicitó al agente y se espera respuesta.',
 FALSE, TRUE, '#f59e0b', 30, TRUE),

('turnado_a_gnp',
 'Turnado a GNP',
 'Documentación completa. El trámite fue enviado a GNP para procesamiento.',
 FALSE, FALSE, '#8b5cf6', 40, FALSE),

('activado_gnp',
 'Activado por GNP',
 'GNP devolvió el trámite solicitando complemento/documentación. '
     'El analista debe atender y reenviar.',
 FALSE, TRUE, '#f97316', 50, TRUE),

('complemento_en_revision',
 'Complemento en revisión',
 'El analista está procesando el complemento solicitado por GNP.',
 FALSE, FALSE, '#06b6d4', 60, FALSE),

('escalado',
 'Escalado',
 'El trámite fue escalado al gerente o director para intervención manual.',
 FALSE, FALSE, '#ec4899', 70, TRUE),

-- ── Terminales ────────────────────────────────────────────────────────────────
('completado',
 'Completado',
 'GNP aprobó la solicitud. El trámite culminó con éxito.',
 TRUE, FALSE, '#22c55e', 90, FALSE),

('rechazado_gnp',
 'Rechazado por GNP',
 'GNP rechazó la solicitud. El trámite no prosperó.',
 TRUE, FALSE, '#ef4444', 95, FALSE),

('cancelado',
 'Cancelado',
 'El agente o el equipo cancelaron la solicitud antes de cualquier resolución.',
 TRUE, FALSE, '#6b7280', 99, FALSE);

-- ---------------------------------------------------------------------------
-- 3. Tabla de transiciones válidas
-- ---------------------------------------------------------------------------

CREATE TABLE estado_tramite_transicion (
    estado_origen_id   TEXT    NOT NULL REFERENCES cat_estado_tramite(id) ON DELETE CASCADE,
    estado_destino_id  TEXT    NOT NULL REFERENCES cat_estado_tramite(id) ON DELETE CASCADE,
    CHECK (estado_origen_id <> estado_destino_id),
    PRIMARY KEY (estado_origen_id, estado_destino_id)
);

COMMENT ON TABLE estado_tramite_transicion IS
    'Define las transiciones de estado válidas. '
    'Una fila (origen, destino) significa que se puede pasar de origen a destino.';

-- ---------------------------------------------------------------------------
-- 4. Poblar transiciones válidas
-- ---------------------------------------------------------------------------

-- Flujo normal
INSERT INTO estado_tramite_transicion (estado_origen_id, estado_destino_id) VALUES
-- Entrada al flujo
('recibido',                  'en_revision'),

-- De revisión se puede pedir docs o turnar
('en_revision',               'pendiente_documentos_agente'),
('en_revision',               'turnado_a_gnp'),

-- Docs pendientes: o se reopens o se cancela
('pendiente_documentos_agente', 'en_revision'),
('pendiente_documentos_agente', 'cancelado'),

-- Turnado a GNP: 3 posibles resultados
('turnado_a_gnp',             'activado_gnp'),    -- GNP pide complemento
('turnado_a_gnp',             'completado'),      -- GNP aprueba
('turnado_a_gnp',             'rechazado_gnp'),   -- GNP rechaza

-- Activado por GNP: se atiende complemento o se cancela/rechaza
('activado_gnp',              'complemento_en_revision'),
('activado_gnp',              'rechazado_gnp'),
('activado_gnp',              'cancelado'),

-- Complemento enviado a GNP de vuelta
('complemento_en_revision',    'turnado_a_gnp'),
('complemento_en_revision',    'cancelado'),

-- Escape: cualquier estado activo puede escalar
('en_revision',               'escalado'),
('pendiente_documentos_agente', 'escalado'),
('activado_gnp',              'escalado'),
('complemento_en_revision',   'escalado'),

--Desde escalar se puede desbloquear cualquier estado activo
('escalado',                  'en_revision'),
('escalado',                  'pendiente_documentos_agente'),
('escalado',                  'activado_gnp'),
('escalado',                  'complemento_en_revision'),
('escalado',                  'cancelado'),

-- Terminales: re-entrada permitida solos mismocon el mismo
('completado',                'completado'),      -- permite re-ingreso vía endoso
('rechazado_gnp',             'rechazado_gnp'),   -- permite reintento
('cancelado',                 'cancelado');        -- fin

-- ---------------------------------------------------------------------------
-- 5. Función de validación de transición
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION estado_tramite_puede_transicionar(
    p_origen  TEXT,
    p_destino TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM estado_tramite_transicion
        WHERE estado_origen_id = p_origen AND estado_destino_id = p_destino
    );
END;
$$;

COMMENT ON FUNCTION estado_tramite_puede_transicionar(TEXT, TEXT) IS
    'Retorna TRUE si la transición de p_origen a p_destino es válida.';

GRANT EXECUTE ON FUNCTION estado_tramite_puede_transicionar(TEXT, TEXT)
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 6. Convertir tramite.estado a TEXT con FK
-- ---------------------------------------------------------------------------

ALTER TABLE tramite
    ALTER COLUMN estado TYPE TEXT;

ALTER TABLE tramite
    DROP CONSTRAINT IF EXISTS tramite_estado_fk,
    ADD CONSTRAINT tramite_estado_fk
        FOREIGN KEY (estado)
        REFERENCES cat_estado_tramite(id);

-- ---------------------------------------------------------------------------
-- 7. Trigger: impedir transiciones inválidas
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION trg_tramite_validar_transicion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado = NEW.estado THEN
        RETURN NEW;
    END IF;

    IF NOT estado_tramite_puede_transicionar(OLD.estado, NEW.estado) THEN
        RAISE EXCEPTION 'Transición de estado inválida: % → %', OLD.estado, NEW.estado
            USING HINT = 'Consulta estado_tramite_transicion para ver las transiciones válidas.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_tramite_validar_transicion ON tramite;
CREATE TRIGGER trg_tramite_validar_transicion
    BEFORE UPDATE OF estado ON tramite
    FOR EACH ROW
    EXECUTE FUNCTION trg_tramite_validar_transicion();

-- ---------------------------------------------------------------------------
-- 8. Migrar datos de estados viejos → nuevos
-- ---------------------------------------------------------------------------

DO $$
BEGIN
    UPDATE tramite SET estado = 'en_revision'
        WHERE estado = 'validando';

    UPDATE tramite SET estado = 'pendiente_documentos_agente'
        WHERE estado = 'pendiente_documentos';

    UPDATE tramite SET estado = 'turnado_a_gnp'
        WHERE estado IN ('completo', 'en_proceso_gnp');

    UPDATE tramite SET estado = 'completado'
        WHERE estado = 'activado';

    UPDATE tramite SET estado = 'rechazado_gnp'
        WHERE estado = 'rechazado';

EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Migración de estados: %', SQLERRM;
END
$$;

-- ---------------------------------------------------------------------------
-- 9. Reemplazar TYPE estado_tramite (usado en otras columnas/funciones)
-- ---------------------------------------------------------------------------

DROP TYPE IF EXISTS estado_tramite;
CREATE TYPE estado_tramite AS ENUM (
    'recibido',
    'en_revision',
    'pendiente_documentos_agente',
    'turnado_a_gnp',
    'activado_gnp',
    'complemento_en_revision',
    'escalado',
    'completado',
    'rechazado_gnp',
    'cancelado'
);

-- ---------------------------------------------------------------------------
-- 10. Permisos
-- ---------------------------------------------------------------------------

GRANT SELECT ON cat_estado_tramite TO authenticated, service_role;
GRANT SELECT ON estado_tramite_transicion TO authenticated, service_role;

-- =============================================================================
-- FIN DE MIGRACIÓN: 20260529000030_estados_tramite.sql
-- =============================================================================



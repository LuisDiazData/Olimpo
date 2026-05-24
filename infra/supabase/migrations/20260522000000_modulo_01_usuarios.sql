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

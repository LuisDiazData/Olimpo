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

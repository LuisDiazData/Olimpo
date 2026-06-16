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
    ('director_general'::rol_usuario, 'tramites.ver',            TRUE),
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
                  AND u.ramo::text = (auth.jwt() -> 'app_metadata' ->> 'ramo')
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
                      AND u.ramo::text = (auth.jwt() -> 'app_metadata' ->> 'ramo')
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

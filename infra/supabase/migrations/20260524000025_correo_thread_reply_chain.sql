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

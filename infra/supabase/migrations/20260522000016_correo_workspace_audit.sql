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

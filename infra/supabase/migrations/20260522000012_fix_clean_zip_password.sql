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

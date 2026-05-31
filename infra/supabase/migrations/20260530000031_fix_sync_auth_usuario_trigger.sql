-- =============================================================================
-- Fix: sync_auth_usuario trigger compatible con GoTrue 2024+
--
-- Problema: versiones nuevas de Supabase Auth crean el usuario en dos pasos:
--   1. INSERT en auth.users con raw_app_meta_data = {"provider":"email",...}
--   2. UPDATE en auth.users para escribir el app_metadata personalizado (rol, ramo)
--
-- El trigger original solo disparaba en INSERT y lanzaba excepción si 'rol' era NULL,
-- lo que abortaba la transacción antes de que GoTrue pudiera escribir el metadata.
--
-- Fix:
--   1. sync_auth_usuario() ya no lanza excepción si 'rol' es NULL — simplemente
--      regresa NEW sin crear el registro. El paso 2 (UPDATE) lo capturará.
--   2. Usamos UPSERT (ON CONFLICT DO UPDATE) para que funcione tanto en INSERT
--      (si GoTrue ya trae el metadata en el INSERT) como en UPDATE posterior.
--   3. El trigger ahora dispara en AFTER INSERT OR UPDATE OF raw_app_meta_data.
-- =============================================================================

-- 1. Reemplazar la función con versión robusta
CREATE OR REPLACE FUNCTION sync_auth_usuario()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rol      TEXT;
    v_ramo     TEXT;
    v_nombre   TEXT;
    v_email    TEXT;
    v_telefono TEXT;
    v_firma    TEXT;
BEGIN
    v_rol      := NEW.raw_app_meta_data  ->> 'rol';
    v_ramo     := NEW.raw_app_meta_data  ->> 'ramo';
    v_nombre   := NEW.raw_user_meta_data ->> 'nombre';
    v_email    := NEW.email;
    v_telefono := NEW.raw_user_meta_data ->> 'telefono';
    v_firma    := NEW.raw_user_meta_data ->> 'firma_html';

    -- Si rol aún no está disponible (Supabase Auth lo escribe en UPDATE posterior),
    -- salir sin error. El trigger disparará de nuevo cuando llegue raw_app_meta_data.
    IF v_rol IS NULL THEN
        RETURN NEW;
    END IF;

    IF v_nombre IS NULL OR TRIM(v_nombre) = '' THEN
        RAISE EXCEPTION 'No se puede crear el usuario: falta "nombre" en user_metadata.';
    END IF;

    INSERT INTO public.usuario (id, nombre, email, rol, ramo, telefono, firma_html, activo, created_at, updated_at)
    VALUES (
        NEW.id,
        TRIM(v_nombre),
        v_email,
        v_rol::rol_usuario,
        CASE WHEN v_ramo IS NOT NULL THEN v_ramo::ramo_usuario ELSE NULL END,
        NULLIF(TRIM(COALESCE(v_telefono, '')), ''),
        NULLIF(TRIM(COALESCE(v_firma, '')), ''),
        TRUE, NOW(), NOW()
    )
    ON CONFLICT (id) DO UPDATE SET
        rol        = EXCLUDED.rol,
        ramo       = EXCLUDED.ramo,
        nombre     = EXCLUDED.nombre,
        telefono   = EXCLUDED.telefono,
        firma_html = EXCLUDED.firma_html,
        updated_at = NOW();

    RETURN NEW;
EXCEPTION
    WHEN invalid_text_representation THEN
        RAISE EXCEPTION 'Valor de rol o ramo inválido. Rol: %, Ramo: %', v_rol, v_ramo;
END;
$$;

-- 2. Recrear el trigger para disparar también en UPDATE OF raw_app_meta_data
DROP TRIGGER IF EXISTS trg_auth_on_new_usuario ON auth.users;

CREATE TRIGGER trg_auth_on_new_usuario
AFTER INSERT OR UPDATE OF raw_app_meta_data ON auth.users
FOR EACH ROW EXECUTE FUNCTION sync_auth_usuario();

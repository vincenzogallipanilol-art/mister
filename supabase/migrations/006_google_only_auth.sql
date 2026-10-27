-- MISTER: rimozione completa dell'auth a token — tutti (admin incluso) accedono
-- con Google. L'admin è determinato da una whitelist di email (admin_emails),
-- non più da un token. Da eseguire dopo 001-005.

-- ============================================================
-- 1. Whitelist email admin — aggiungi/rimuovi admin da qui
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_emails (
  email text PRIMARY KEY
);
ALTER TABLE public.admin_emails ENABLE ROW LEVEL SECURITY;
-- nessuna policy pubblica: gestita solo da SQL Editor (service role)

-- Inserisci qui la tua email admin (cambia se necessario):
INSERT INTO public.admin_emails(email)
VALUES ('vincenzogallipanilol@gmail.com')
ON CONFLICT (email) DO NOTHING;

-- ============================================================
-- 2. register_google_user() — ora riconosce anche gli admin via email
-- ============================================================
CREATE OR REPLACE FUNCTION public.register_google_user(
  p_email text DEFAULT '',
  p_display_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_uid      uuid := auth.uid();
  v_row      google_users%ROWTYPE;
  v_name     text;
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'non autenticato';
  END IF;

  SELECT EXISTS(SELECT 1 FROM admin_emails WHERE lower(email) = lower(trim(p_email)))
  INTO v_is_admin;

  SELECT * INTO v_row FROM google_users WHERE auth_uid = v_uid;

  IF NOT FOUND THEN
    INSERT INTO google_users (auth_uid, email, display_name, linked_at)
    VALUES (
      v_uid, p_email,
      COALESCE(NULLIF(trim(p_display_name), ''), split_part(p_email, '@', 1)),
      CASE WHEN v_is_admin THEN now() ELSE NULL END
    )
    RETURNING * INTO v_row;
  ELSIF v_is_admin AND v_row.linked_at IS NULL THEN
    UPDATE google_users SET linked_at = now() WHERE auth_uid = v_uid
    RETURNING * INTO v_row;
  END IF;

  IF v_is_admin THEN
    INSERT INTO profiles(id, role, name)
    VALUES (v_uid, 'admin', COALESCE(v_row.display_name, p_email))
    ON CONFLICT (id) DO UPDATE SET role = 'admin', name = EXCLUDED.name;

    RETURN jsonb_build_object(
      'status', 'linked', 'pid', NULL,
      'name', COALESCE(v_row.display_name, p_email), 'role', 'admin'
    );
  END IF;

  IF v_row.pid IS NOT NULL AND v_row.linked_at IS NOT NULL THEN
    SELECT data->>'name' INTO v_name FROM docs WHERE col = 'players' AND id = v_row.pid LIMIT 1;
    RETURN jsonb_build_object(
      'status', 'linked', 'pid', v_row.pid,
      'name', COALESCE(v_name, v_row.display_name, split_part(v_row.email, '@', 1)),
      'role', 'player'
    );
  END IF;

  RETURN jsonb_build_object('status', 'pending');
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_google_user(text, text) TO authenticated;

-- ============================================================
-- 3. Pannello admin: ora autenticato via sessione Google (auth.uid()),
--    niente più p_admin_token. Si sostituiscono le vecchie funzioni.
-- ============================================================
DROP FUNCTION IF EXISTS public.list_pending_google_users(text);
DROP FUNCTION IF EXISTS public.link_google_user(text, uuid, text);
DROP FUNCTION IF EXISTS public.unlink_google_user(text, uuid);

CREATE OR REPLACE FUNCTION public.list_pending_google_users()
RETURNS TABLE(auth_uid uuid, email text, display_name text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
    SELECT g.auth_uid, g.email, g.display_name, g.created_at
    FROM google_users g
    WHERE g.pid IS NULL OR g.linked_at IS NULL
    ORDER BY g.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_pending_google_users() TO authenticated;

CREATE OR REPLACE FUNCTION public.link_google_user(p_auth_uid uuid, p_pid text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_name    text;
  v_updated int;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  SELECT data->>'name' INTO v_name FROM docs WHERE col = 'players' AND id = p_pid LIMIT 1;

  UPDATE google_users SET pid = p_pid, linked_at = now() WHERE auth_uid = p_auth_uid;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN RETURN false; END IF;

  INSERT INTO profiles(id, role, name)
  VALUES (p_auth_uid, 'player', v_name)
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, role = 'player';

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.link_google_user(uuid, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.unlink_google_user(p_auth_uid uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE google_users SET pid = NULL, linked_at = NULL WHERE auth_uid = p_auth_uid;
  DELETE FROM profiles WHERE id = p_auth_uid;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unlink_google_user(uuid) TO authenticated;

-- ============================================================
-- 4. Rimozione completa del sistema a token
-- ============================================================
DROP FUNCTION IF EXISTS public.validate_token(text);
DROP FUNCTION IF EXISTS public.create_player_token(text, text);
DROP FUNCTION IF EXISTS public.revoke_player_token(text, text);
DROP FUNCTION IF EXISTS public.list_player_tokens(text);

-- ============================================================
-- 5. Chiusura accesso anonimo: ora tutto passa da Google (authenticated).
--    Rimuoviamo le policy "anon" aperte introdotte in 003 per il token-auth.
-- ============================================================
DROP POLICY IF EXISTS docs_anon_select ON public.docs;
DROP POLICY IF EXISTS docs_anon_insert ON public.docs;
DROP POLICY IF EXISTS docs_anon_update ON public.docs;
DROP POLICY IF EXISTS docs_anon_delete ON public.docs;
DROP POLICY IF EXISTS push_anon ON public.push_subs;

-- forza il reload dello schema PostgREST
NOTIFY pgrst, 'reload schema';

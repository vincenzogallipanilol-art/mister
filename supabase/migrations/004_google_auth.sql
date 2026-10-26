-- MISTER: Google OAuth via Supabase Auth
-- Da eseguire nell'SQL Editor di Supabase dopo 001/002/003.
--
-- Prerequisiti lato dashboard (da fare manualmente, UNA VOLTA):
-- 1) Authentication → Providers → Google: abilita e inserisci Client ID/Secret
--    (creati su Google Cloud Console, redirect URI = https://<PROJECT_REF>.supabase.co/auth/v1/callback)
-- 2) Authentication → URL Configuration:
--    Site URL = url dove è ospitata l'app (es. https://<user>.github.io/mister)
--    Redirect URLs: aggiungi la stessa URL
--
-- Architettura: gli admin continuano a usare il token (localStorage), i giocatori
-- passano a Google OAuth. google_users mappa auth.uid() → pid giocatore; quando
-- l'admin collega un utente, viene creato anche un profiles(id=auth.uid()) così
-- is_member()/is_admin() (storiche, da 001_init.sql) funzionano per utenti autenticati.

-- ============================================================
-- 1. Tabella google_users
-- ============================================================
CREATE TABLE IF NOT EXISTS public.google_users (
  auth_uid     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  pid          text,            -- id giocatore in docs; NULL = non ancora collegato
  email        text NOT NULL,
  display_name text,
  linked_at    timestamptz,     -- NULL = in attesa di approvazione admin
  created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.google_users ENABLE ROW LEVEL SECURITY;
-- Nessuna policy pubblica: accesso solo tramite le funzioni SECURITY DEFINER sotto

-- ============================================================
-- 2. RLS su docs/push_subs per utenti autenticati (Google)
--    Gli utenti anon (admin con token) restano gestiti dalle policy di 003.
-- ============================================================
DROP POLICY IF EXISTS docs_auth_select ON public.docs;
DROP POLICY IF EXISTS docs_auth_insert ON public.docs;
DROP POLICY IF EXISTS docs_auth_update ON public.docs;
DROP POLICY IF EXISTS docs_auth_delete ON public.docs;

CREATE POLICY docs_auth_select ON public.docs
  FOR SELECT TO authenticated USING (public.is_member());

CREATE POLICY docs_auth_insert ON public.docs
  FOR INSERT TO authenticated WITH CHECK (public.is_member());

CREATE POLICY docs_auth_update ON public.docs
  FOR UPDATE TO authenticated USING (public.is_member()) WITH CHECK (public.is_member());

CREATE POLICY docs_auth_delete ON public.docs
  FOR DELETE TO authenticated USING (public.is_admin());

DROP POLICY IF EXISTS push_auth ON public.push_subs;
CREATE POLICY push_auth ON public.push_subs
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ============================================================
-- 3. register_google_user() — chiamata dal client subito dopo il login Google
--    Crea la riga pending al primo accesso, altrimenti ritorna lo stato corrente.
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
  v_uid  uuid := auth.uid();
  v_row  google_users%ROWTYPE;
  v_name text;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'non autenticato';
  END IF;

  SELECT * INTO v_row FROM google_users WHERE auth_uid = v_uid;

  IF NOT FOUND THEN
    INSERT INTO google_users (auth_uid, email, display_name)
    VALUES (v_uid, p_email, COALESCE(NULLIF(trim(p_display_name), ''), split_part(p_email, '@', 1)));
    RETURN jsonb_build_object('status', 'new');
  END IF;

  IF v_row.pid IS NOT NULL AND v_row.linked_at IS NOT NULL THEN
    SELECT data->>'name' INTO v_name
    FROM docs WHERE col = 'players' AND id = v_row.pid LIMIT 1;

    RETURN jsonb_build_object(
      'status', 'linked',
      'pid',    v_row.pid,
      'name',   COALESCE(v_name, v_row.display_name, split_part(v_row.email, '@', 1)),
      'role',   'player'
    );
  END IF;

  RETURN jsonb_build_object('status', 'pending');
END;
$$;

GRANT EXECUTE ON FUNCTION public.register_google_user(text, text) TO authenticated;

-- ============================================================
-- 4. list_pending_google_users(admin_token) — pannello admin
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_pending_google_users(p_admin_token text)
RETURNS TABLE(auth_uid uuid, email text, display_name text, created_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role INTO v_role
  FROM invites
  WHERE code = lower(trim(p_admin_token))
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses = 0 OR uses < max_uses OR max_uses = 9999);

  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
    SELECT g.auth_uid, g.email, g.display_name, g.created_at
    FROM google_users g
    WHERE g.pid IS NULL OR g.linked_at IS NULL
    ORDER BY g.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_pending_google_users(text) TO anon;

-- ============================================================
-- 5. link_google_user(admin_token, auth_uid, pid) — collega utente ↔ giocatore
--    Crea anche profiles(id=auth_uid) così is_member()/is_admin() funzionano.
-- ============================================================
CREATE OR REPLACE FUNCTION public.link_google_user(
  p_admin_token text,
  p_auth_uid    uuid,
  p_pid         text
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_role text;
  v_name text;
  v_updated int;
BEGIN
  SELECT role INTO v_role
  FROM invites
  WHERE code = lower(trim(p_admin_token))
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses = 0 OR uses < max_uses OR max_uses = 9999);

  IF v_role IS DISTINCT FROM 'admin' THEN
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

GRANT EXECUTE ON FUNCTION public.link_google_user(text, uuid, text) TO anon;

-- ============================================================
-- 6. unlink_google_user(admin_token, auth_uid) — scollega (es. errore admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.unlink_google_user(
  p_admin_token text,
  p_auth_uid    uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_role text;
BEGIN
  SELECT role INTO v_role
  FROM invites
  WHERE code = lower(trim(p_admin_token))
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses = 0 OR uses < max_uses OR max_uses = 9999);

  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE google_users SET pid = NULL, linked_at = NULL WHERE auth_uid = p_auth_uid;
  DELETE FROM profiles WHERE id = p_auth_uid;

  RETURN true;
END;
$$;

GRANT EXECUTE ON FUNCTION public.unlink_google_user(text, uuid) TO anon;

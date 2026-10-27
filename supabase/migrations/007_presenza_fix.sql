-- MISTER 007: Fix pannello Presenza (veridicità) + notifica admin su nuovo accesso Google
-- Da eseguire dopo 001-006.

-- ============================================================
-- 1. link_google_user: evita doppie associazioni allo stesso pid.
--    Se un altro account Google risulta già collegato a quel giocatore,
--    lo scollega (pid/linked_at/profiles) e rimuove il suo vecchio
--    doc "links/<uid>" — altrimenti restano righe fantasma che il
--    pannello Presenza può mostrare al posto di quella vera.
-- ============================================================
CREATE OR REPLACE FUNCTION public.link_google_user(p_auth_uid uuid, p_pid text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_name    text;
  v_updated int;
  v_old     uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  SELECT data->>'name' INTO v_name FROM docs WHERE col = 'players' AND id = p_pid LIMIT 1;

  -- scollega eventuali altri account già agganciati a questo stesso giocatore
  FOR v_old IN SELECT auth_uid FROM google_users WHERE pid = p_pid AND auth_uid <> p_auth_uid LOOP
    UPDATE google_users SET pid = NULL, linked_at = NULL WHERE auth_uid = v_old;
    DELETE FROM profiles WHERE id = v_old;
    DELETE FROM docs WHERE path = 'links/' || v_old::text;
  END LOOP;

  UPDATE google_users SET pid = p_pid, linked_at = now() WHERE auth_uid = p_auth_uid;
  GET DIAGNOSTICS v_updated = ROW_COUNT;
  IF v_updated = 0 THEN RETURN false; END IF;

  INSERT INTO profiles(id, role, name)
  VALUES (p_auth_uid, 'player', v_name)
  ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, role = 'player';

  RETURN true;
END;
$$;

-- ============================================================
-- 2. unlink_google_user: ora pulisce anche il doc "links/<uid>",
--    altrimenti al prossimo accesso dell'utente shim.js lo ricrea
--    da solo e lo scollegamento fatto dall'admin non ha effetto reale.
-- ============================================================
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
  DELETE FROM docs WHERE path = 'links/' || p_auth_uid::text;

  RETURN true;
END;
$$;

-- ============================================================
-- 3. register_google_user: aggiunge "is_new" (true solo alla prima
--    registrazione in assoluto di quell'account) — serve al client per
--    sapere quando avvisare l'admin, senza notificare a ogni apertura
--    app di un utente già in attesa.
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
  v_is_new   boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'non autenticato';
  END IF;

  SELECT EXISTS(SELECT 1 FROM admin_emails WHERE lower(email) = lower(trim(p_email)))
  INTO v_is_admin;

  SELECT * INTO v_row FROM google_users WHERE auth_uid = v_uid;

  IF NOT FOUND THEN
    v_is_new := true;
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
      'name', COALESCE(v_row.display_name, p_email), 'role', 'admin', 'is_new', v_is_new
    );
  END IF;

  IF v_row.pid IS NOT NULL AND v_row.linked_at IS NOT NULL THEN
    SELECT data->>'name' INTO v_name FROM docs WHERE col = 'players' AND id = v_row.pid LIMIT 1;
    RETURN jsonb_build_object(
      'status', 'linked', 'pid', v_row.pid,
      'name', COALESCE(v_name, v_row.display_name, split_part(v_row.email, '@', 1)),
      'role', 'player', 'is_new', v_is_new
    );
  END IF;

  RETURN jsonb_build_object('status', 'pending', 'is_new', v_is_new);
END;
$$;

-- ============================================================
-- 4. admin_push_targets(): elenco auth_uid degli admin, usato dal client
--    per indirizzare la push "nuovo accesso Google" solo a loro.
--    Espone solo id opachi (nessuna email), callable da chiunque sia
--    autenticato (serve anche a chi si è appena registrato e non è ancora
--    collegato a nessun giocatore).
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_push_targets()
RETURNS TABLE(auth_uid uuid)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
  SELECT g.auth_uid FROM google_users g
  JOIN admin_emails a ON lower(a.email) = lower(g.email);
$$;

GRANT EXECUTE ON FUNCTION public.admin_push_targets() TO authenticated;

NOTIFY pgrst, 'reload schema';

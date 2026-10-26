-- MISTER: Security Hardening (003)
-- Da eseguire nell'SQL Editor di Supabase dopo 001_init.sql e 002_token_security.sql
--
-- IMPORTANTE: alla fine di questa migrazione verranno mostrati i NUOVI TOKEN ADMIN.
-- Copia i valori dall'output "Messages" prima di chiudere questa finestra!

-- =========================================================
-- 1. FIX push_subs: user_id era uuid references auth.users
--    ma l'app usa token string → cast error, push non funziona
-- =========================================================
ALTER TABLE public.push_subs
  DROP CONSTRAINT IF EXISTS push_subs_user_id_fkey;

ALTER TABLE public.push_subs
  ALTER COLUMN user_id TYPE text USING user_id::text;

-- Aggiunge colonna pid per collegare al giocatore (token può ruotare, pid no)
ALTER TABLE public.push_subs
  ADD COLUMN IF NOT EXISTS pid text;

-- Aggiorna policy: l'endpoint è segreto di per sé, accesso anon ok
DROP POLICY IF EXISTS push_own ON push_subs;
CREATE POLICY push_anon ON push_subs
  FOR ALL TO anon USING (true) WITH CHECK (true);

-- =========================================================
-- 2. FIX docs RLS: is_member()/is_admin() usano auth.uid()
--    che è sempre NULL con token-based auth → tutti i query
--    diretti bloccati. Aggiungiamo policy anon per far funzionare l'app.
--    La sicurezza reale è: invites+profiles sono locked down.
-- =========================================================
DROP POLICY IF EXISTS docs_read ON docs;
DROP POLICY IF EXISTS docs_player_ins ON docs;
DROP POLICY IF EXISTS docs_player_upd ON docs;
-- Manteniamo docs_admin_all per eventuali future integrazioni Supabase Auth

CREATE POLICY docs_anon_select ON docs
  FOR SELECT TO anon USING (true);

CREATE POLICY docs_anon_insert ON docs
  FOR INSERT TO anon WITH CHECK (true);

CREATE POLICY docs_anon_update ON docs
  FOR UPDATE TO anon USING (true);

-- DELETE necessaria per il sync locale dell'app (quando doc rimosso lato server)
CREATE POLICY docs_anon_delete ON docs
  FOR DELETE TO anon USING (true);

-- =========================================================
-- 3. NUOVA FUNZIONE: list_player_tokens con validazione admin
--    server-side — sostituisce il query diretto in MisterTokenAdmin.listTokens()
-- =========================================================
CREATE OR REPLACE FUNCTION public.list_player_tokens(p_admin_token text)
RETURNS TABLE(code text, pid text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_role text;
BEGIN
  -- Valida che il token sia un token admin valido e non scaduto
  SELECT role INTO v_role
  FROM invites
  WHERE invites.code = lower(trim(p_admin_token))
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses = 0 OR uses < max_uses OR max_uses = 9999);

  IF v_role IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  -- Restituisce solo token player (mai token admin)
  RETURN QUERY
    SELECT i.code, i.pid
    FROM invites i
    WHERE i.role = 'player'
    ORDER BY i.created_at;
END;
$$;

GRANT EXECUTE ON FUNCTION public.list_player_tokens(text) TO anon;

-- =========================================================
-- 4. RIGENERA tutti i token deboli (< 32 chars = < 128-bit)
--    Questo include sia player che admin token con bassa entropia.
--
--    ⚠️  I NUOVI TOKEN ADMIN vengono mostrati nell'output qui sotto.
--    ⚠️  Salvali PRIMA di chiudere questa finestra!
-- =========================================================

-- 4a. Rigenera token player deboli
UPDATE public.invites
SET code = encode(extensions.gen_random_bytes(16), 'hex')
WHERE role = 'player'
  AND length(code) < 32;

-- 4b. Rigenera token admin deboli (incluso 'mister-admin' se non cambiato)
UPDATE public.invites
SET code = encode(extensions.gen_random_bytes(16), 'hex')
WHERE role = 'admin'
  AND length(code) < 32;

-- 4c. Mostra i nuovi token admin nell'output (tab "Messages")
DO $$
DECLARE
  rec RECORD;
  v_player_count int;
BEGIN
  -- Conta player token aggiornati
  SELECT count(*) INTO v_player_count FROM invites WHERE role='player' AND length(code)=32;
  RAISE NOTICE '--- TOKEN PLAYER da 128-bit: % ---', v_player_count;

  -- Mostra TUTTI i token admin (sono pochi, l'admin deve saperli)
  RAISE NOTICE '--- NUOVI TOKEN ADMIN (salvali ora!) ---';
  FOR rec IN
    SELECT code, pid, created_at FROM invites WHERE role = 'admin' ORDER BY created_at
  LOOP
    RAISE NOTICE 'ADMIN TOKEN: % (pid: %)', rec.code, rec.pid;
  END LOOP;
  RAISE NOTICE '--- FINE TOKEN ADMIN ---';
END $$;

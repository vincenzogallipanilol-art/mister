-- MISTER 008: lista pid già collegati, per impedire di collegare un
-- giocatore già censito sotto un'altra email a un secondo account Google.

CREATE OR REPLACE FUNCTION public.linked_player_ids()
RETURNS TABLE(pid text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
    SELECT g.pid FROM google_users g
    WHERE g.pid IS NOT NULL AND g.linked_at IS NOT NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.linked_player_ids() TO authenticated;

NOTIFY pgrst, 'reload schema';

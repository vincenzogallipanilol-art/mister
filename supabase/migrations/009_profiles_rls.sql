-- MISTER 009: la tabella "profiles" (id/ruolo/nome di ogni utente collegato)
-- non aveva mai la sicurezza di riga attiva: chiunque, anche senza accesso,
-- poteva leggerla intera via API REST. Nessun punto dell'app la legge
-- direttamente (solo funzioni is_member()/is_admin()/register_google_user ecc,
-- tutte SECURITY DEFINER e quindi non toccate da RLS), quindi la blocco del
-- tutto, come già fatto per google_users.

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

NOTIFY pgrst, 'reload schema';

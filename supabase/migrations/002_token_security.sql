-- MISTER: fix SQL injection + rate limiting sui token
-- Applica via: Supabase Dashboard → SQL Editor → esegui tutto

-- 1. Aggiungi colonna pid a invites (se non esiste già)
alter table public.invites add column if not exists pid text;
alter table public.invites add column if not exists token_type text not null default 'player';

-- 2. Tabella rate limiting per i tentativi di accesso
create table if not exists public.token_attempts(
  id bigserial primary key,
  attempted_at timestamptz not null default now(),
  token_hash text not null,   -- sha256(input) – non il valore raw
  success boolean not null default false
);
create index if not exists token_attempts_hash_at on public.token_attempts(token_hash, attempted_at desc);

-- RLS: solo security definer può leggere/scrivere
alter table public.token_attempts enable row level security;
-- nessuna policy pubblica: accesso solo via security definer functions

-- 3. validate_token – SICURO, zero dynamic SQL
--    Vecchia versione vulnerabile rimossa e sostituita.
create or replace function public.validate_token(p_token text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_role       text;
  v_pid        text;
  v_name       text;
  v_hash       text;
  v_attempts   int;
  v_window     interval := interval '15 minutes';
  v_max_fails  int := 10;
begin
  -- Sanity: token vuoto
  if p_token is null or trim(p_token) = '' then
    return jsonb_build_object('valid', false);
  end if;

  -- Hash del tentativo (non salviamo il token raw)
  v_hash := encode(digest(lower(trim(p_token)), 'sha256'), 'hex');

  -- Rate limiting: blocca IP/token con troppi fallimenti recenti
  select count(*) into v_attempts
  from public.token_attempts
  where token_hash = v_hash
    and success = false
    and attempted_at > now() - v_window;

  if v_attempts >= v_max_fails then
    return jsonb_build_object('valid', false, 'reason', 'rate_limited');
  end if;

  -- Lookup parametrizzato – nessuna concatenazione di stringhe
  select i.role,
         i.pid,
         coalesce((select d.data->>'name'
                   from public.docs d
                   where d.col = 'players' and d.id = i.pid
                   limit 1), i.pid)
  into   v_role, v_pid, v_name
  from   public.invites i
  where  i.code = lower(trim(p_token))
    and  (i.expires_at is null or i.expires_at > now())
    and  i.uses < i.max_uses;

  -- Log del tentativo
  insert into public.token_attempts(token_hash, success)
  values (v_hash, v_role is not null);

  if v_role is null then
    return jsonb_build_object('valid', false);
  end if;

  return jsonb_build_object(
    'valid', true,
    'role',  v_role,
    'pid',   v_pid,
    'name',  v_name
  );
end $$;

-- 4. create_player_token – crea/rinnova un token per un giocatore (solo admin)
create or replace function public.create_player_token(p_admin_token text, p_pid text)
returns text language plpgsql security definer set search_path=public as $$
declare
  v_admin_role text;
  v_new_code   text;
begin
  -- Verifica che p_admin_token sia un token admin valido (query parametrizzata)
  select role into v_admin_role
  from public.invites
  where code = lower(trim(p_admin_token))
    and (expires_at is null or expires_at > now())
    and uses < max_uses;

  if v_admin_role is distinct from 'admin' then
    raise exception 'non autorizzato';
  end if;

  -- Revoca token precedente per lo stesso pid (se esiste)
  delete from public.invites
  where pid = p_pid and role = 'player';

  -- Genera nuovo token con alta entropia (32 hex = 128 bit)
  v_new_code := encode(gen_random_bytes(16), 'hex');

  insert into public.invites(code, role, pid, max_uses, expires_at, token_type)
  values (v_new_code, 'player', p_pid, 999999, null, 'player');

  return v_new_code;
end $$;

-- 5. revoke_player_token – revoca il token di un giocatore (solo admin)
create or replace function public.revoke_player_token(p_admin_token text, p_pid text)
returns boolean language plpgsql security definer set search_path=public as $$
declare
  v_admin_role text;
  v_deleted    int;
begin
  select role into v_admin_role
  from public.invites
  where code = lower(trim(p_admin_token))
    and (expires_at is null or expires_at > now())
    and uses < max_uses;

  if v_admin_role is distinct from 'admin' then
    raise exception 'non autorizzato';
  end if;

  delete from public.invites
  where pid = p_pid and role = 'player';

  get diagnostics v_deleted = row_count;
  return v_deleted > 0;
end $$;

-- 6. Pulizia periodica dei log di tentativo (mantieni solo ultimi 7 giorni)
create or replace function public.cleanup_token_attempts() returns void
language sql security definer set search_path=public as $$
  delete from public.token_attempts where attempted_at < now() - interval '7 days';
$$;

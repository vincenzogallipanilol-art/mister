-- MISTER: fix search_path — pgcrypto (digest, gen_random_bytes) vive nello schema
-- "extensions" su Supabase, ma le funzioni di 002 avevano "set search_path=public"
-- che lo esclude → errore 42883 "function digest(...) does not exist" → 404 su RPC.

create or replace function public.validate_token(p_token text)
returns jsonb language plpgsql security definer set search_path=public, extensions as $$
declare
  v_role       text;
  v_pid        text;
  v_name       text;
  v_hash       text;
  v_attempts   int;
  v_window     interval := interval '15 minutes';
  v_max_fails  int := 10;
begin
  if p_token is null or trim(p_token) = '' then
    return jsonb_build_object('valid', false);
  end if;

  v_hash := encode(digest(lower(trim(p_token)), 'sha256'), 'hex');

  select count(*) into v_attempts
  from public.token_attempts
  where token_hash = v_hash
    and success = false
    and attempted_at > now() - v_window;

  if v_attempts >= v_max_fails then
    return jsonb_build_object('valid', false, 'reason', 'rate_limited');
  end if;

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

create or replace function public.create_player_token(p_admin_token text, p_pid text)
returns text language plpgsql security definer set search_path=public, extensions as $$
declare
  v_admin_role text;
  v_new_code   text;
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

  v_new_code := encode(gen_random_bytes(16), 'hex');

  insert into public.invites(code, role, pid, max_uses, expires_at, token_type)
  values (v_new_code, 'player', p_pid, 999999, null, 'player');

  return v_new_code;
end $$;

-- revoke_player_token non usa pgcrypto ma la riallineiamo per coerenza
create or replace function public.revoke_player_token(p_admin_token text, p_pid text)
returns boolean language plpgsql security definer set search_path=public, extensions as $$
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

-- forza il reload dello schema PostgREST
notify pgrst, 'reload schema';

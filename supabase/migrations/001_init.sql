-- MISTER: schema, permessi (RLS), storico modifiche, inviti, push
create extension if not exists pgcrypto;

create table public.profiles(
  id uuid primary key references auth.users on delete cascade,
  role text not null default 'player' check (role in ('admin','player')),
  name text,
  created_at timestamptz default now()
);

-- documenti generici: players/x, matches/x, events/x, rsvps/x, ratings/x, links/x, pairs/x, state/setup...
create table public.docs(
  path text primary key,
  col text not null,
  id text not null,
  data jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users
);
create index on public.docs(col);

-- storico: chi ha fatto cosa e quando
create table public.doc_log(
  id bigserial primary key,
  at timestamptz not null default now(),
  user_id uuid,
  action text not null,
  path text not null,
  col text not null,
  old_data jsonb,
  new_data jsonb
);
create index on public.doc_log(path);
create index on public.doc_log(col, at desc);

create table public.invites(
  code text primary key default encode(gen_random_bytes(5),'hex'),
  role text not null default 'player' check (role in ('admin','player')),
  max_uses int not null default 30,
  uses int not null default 0,
  expires_at timestamptz default now() + interval '30 days',
  created_by uuid references auth.users,
  created_at timestamptz default now()
);

create table public.push_subs(
  endpoint text primary key,
  user_id uuid not null references auth.users on delete cascade,
  sub jsonb not null,
  created_at timestamptz default now()
);

-- helper
create or replace function public.is_member() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid()) $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role='admin') $$;
create or replace function public.my_pid() returns text language sql stable security definer set search_path=public as
$$ select data->>'p' from docs where path='links/'||auth.uid()::text $$;

-- riscatto invito: crea il profilo con il ruolo dell'invito
create or replace function public.redeem_invite(p_code text, p_name text default null) returns text
language plpgsql security definer set search_path=public as $$
declare i invites%rowtype; r text;
begin
  if auth.uid() is null then raise exception 'non autenticato'; end if;
  select role into r from profiles where id=auth.uid();
  if r is not null then return r; end if;
  select * into i from invites where code=lower(trim(p_code)) for update;
  if not found or i.uses>=i.max_uses or (i.expires_at is not null and i.expires_at<now()) then
    raise exception 'invito non valido o scaduto';
  end if;
  update invites set uses=uses+1 where code=i.code;
  insert into profiles(id,role,name) values(auth.uid(),i.role,p_name);
  return i.role;
end $$;

-- RLS
alter table profiles enable row level security;
alter table docs enable row level security;
alter table doc_log enable row level security;
alter table invites enable row level security;
alter table push_subs enable row level security;

create policy prof_self on profiles for select using (id=auth.uid() or is_admin());
create policy prof_admin_upd on profiles for update using (is_admin());

create policy docs_read on docs for select using (is_member());
create policy docs_admin_all on docs for all using (is_admin()) with check (is_admin());
-- i giocatori scrivono solo ratings/rsvps/links propri
create policy docs_player_ins on docs for insert with check (
  is_member() and (
    (col='links' and id=auth.uid()::text) or
    (col='rsvps' and data->>'p'=my_pid()) or
    (col='ratings' and data->>'r'=my_pid())));
create policy docs_player_upd on docs for update
  using (is_member() and (
    (col='links' and id=auth.uid()::text) or
    (col='rsvps' and data->>'p'=my_pid()) or
    (col='ratings' and data->>'r'=my_pid())))
  with check (
    (col='links' and id=auth.uid()::text) or
    (col='rsvps' and data->>'p'=my_pid()) or
    (col='ratings' and data->>'r'=my_pid()));

create policy log_read on doc_log for select using (is_admin());
create policy inv_admin on invites for all using (is_admin()) with check (is_admin());
create policy push_own on push_subs for all using (user_id=auth.uid()) with check (user_id=auth.uid());

-- trigger: metadati + storico
create or replace function public.docs_audit() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='DELETE' then
    insert into doc_log(user_id,action,path,col,old_data) values(auth.uid(),'delete',old.path,old.col,old.data);
    return old;
  end if;
  new.updated_at=now(); new.updated_by=auth.uid();
  if tg_op='INSERT' then
    insert into doc_log(user_id,action,path,col,new_data) values(auth.uid(),'insert',new.path,new.col,new.data);
  elsif old.data is distinct from new.data then
    insert into doc_log(user_id,action,path,col,old_data,new_data) values(auth.uid(),'update',new.path,new.col,old.data,new.data);
  end if;
  return new;
end $$;
create trigger docs_audit_t before insert or update or delete on docs for each row execute function docs_audit();

-- realtime
alter publication supabase_realtime add table docs;

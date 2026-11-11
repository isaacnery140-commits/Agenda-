-- Várias agendas: cada agenda tem um código próprio; quem tem o código vê só aquela agenda.

create table if not exists public.agenda_agendas (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  code_sha text not null unique,
  created_by text not null default '',
  created_at timestamptz not null default now()
);
alter table public.agenda_agendas enable row level security;
revoke all on public.agenda_agendas from anon, authenticated;

alter table public.agenda_events add column if not exists agenda_id uuid references public.agenda_agendas(id) on delete cascade;
create index if not exists agenda_events_agenda_idx on public.agenda_events (agenda_id, date);
alter table public.agenda_push_subs add column if not exists agenda_id uuid references public.agenda_agendas(id) on delete cascade;

create or replace function public.agenda_sha(p_code text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(lower(trim(coalesce(p_code,''))), 'sha256'), 'hex');
$$;
revoke all on function public.agenda_sha(text) from public, anon, authenticated;

create or replace function public.agenda_gen_code() returns text
language plpgsql set search_path = '' as $$
declare
  w text[] := array['sol','lua','mar','rio','flor','vento','nuvem','pedra','ilha','fogo','neve','trilha','farol','onda','serra','campo',
                    'brisa','estrela','monte','lago','ponte','jardim','praia','bosque','vale','chuva','areia','folha','ninho','porto','cais','duna'];
  b bytea := extensions.gen_random_bytes(6);
begin
  return w[1 + get_byte(b,0) % 32] || '-' || w[1 + get_byte(b,1) % 32] || '-' || w[1 + get_byte(b,2) % 32] || '-' ||
         lpad(((get_byte(b,3) * 65536 + get_byte(b,4) * 256 + get_byte(b,5)) % 100000)::text, 5, '0');
end $$;
revoke all on function public.agenda_gen_code() from public, anon, authenticated;

-- Confere o código e devolve a agenda a que ele dá acesso.
drop function if exists public.agenda_auth(text);
create function public.agenda_auth(p_code text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare aid uuid;
begin
  select a.id into aid from public.agenda_agendas a where a.code_sha = public.agenda_sha(p_code);
  if aid is null then
    perform pg_sleep(1);
    raise exception 'codigo_invalido' using errcode = '28000';
  end if;
  return aid;
end $$;
revoke all on function public.agenda_auth(text) from public, anon, authenticated;

drop function if exists public.agenda_check(text);
create function public.agenda_check(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare aid uuid; r jsonb;
begin
  aid := public.agenda_auth(p_code);
  select jsonb_build_object('name', a.name, 'created_by', a.created_by) into r from public.agenda_agendas a where a.id = aid;
  return r;
end $$;

-- Cria uma agenda nova (precisa já ter acesso a alguma agenda) e devolve o código dela.
create or replace function public.agenda_create(p_code text, p_name text, p_author text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c text; n text := left(trim(coalesce(p_name,'')),60);
begin
  perform public.agenda_auth(p_code);
  if n = '' then raise exception 'nome_obrigatorio'; end if;
  if (select count(*) from public.agenda_agendas) >= 300 then raise exception 'limite_de_agendas'; end if;
  c := public.agenda_gen_code();
  insert into public.agenda_agendas (name, code_sha, created_by) values (n, public.agenda_sha(c), left(trim(coalesce(p_author,'')),40));
  return jsonb_build_object('code', c, 'name', n);
end $$;

-- Troca o código da agenda (quem tinha o código antigo perde o acesso). Só quem criou a agenda.
create or replace function public.agenda_rotate(p_code text, p_author text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare aid uuid; a public.agenda_agendas; c text; me text := left(trim(coalesce(p_author,'')),40);
begin
  aid := public.agenda_auth(p_code);
  select * into a from public.agenda_agendas where id = aid;
  if a.created_by <> '' and lower(a.created_by) <> lower(me) then raise exception 'sem_permissao'; end if;
  c := public.agenda_gen_code();
  update public.agenda_agendas set code_sha = public.agenda_sha(c), created_by = case when created_by = '' then me else created_by end where id = aid;
  delete from public.agenda_push_subs s where s.agenda_id = aid and lower(s.name) <> lower(me);
  return jsonb_build_object('code', c, 'name', a.name);
end $$;

create or replace function public.agenda_rename(p_code text, p_name text, p_author text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare aid uuid; a public.agenda_agendas; n text := left(trim(coalesce(p_name,'')),60);
begin
  aid := public.agenda_auth(p_code);
  select * into a from public.agenda_agendas where id = aid;
  if a.created_by <> '' and lower(a.created_by) <> lower(trim(coalesce(p_author,''))) then raise exception 'sem_permissao'; end if;
  if n = '' then raise exception 'nome_obrigatorio'; end if;
  update public.agenda_agendas set name = n where id = aid;
  return jsonb_build_object('name', n);
end $$;

create or replace function public.agenda_list(p_code text)
returns setof public.agenda_events language plpgsql security definer set search_path = '' as $$
declare aid uuid;
begin
  aid := public.agenda_auth(p_code);
  return query
    select * from public.agenda_events e
    where e.agenda_id = aid and e.date >= (current_date - interval '400 days')
    order by e.date, e.start_time nulls first;
end $$;

create or replace function public.agenda_subscribe(p_code text, p_name text, p_endpoint text, p_p256dh text, p_auth text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare aid uuid;
begin
  aid := public.agenda_auth(p_code);
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then
    raise exception 'assinatura_invalida';
  end if;
  insert into public.agenda_push_subs (endpoint, agenda_id, p256dh, auth, name)
  values (p_endpoint, aid, p_p256dh, p_auth, left(coalesce(p_name,''),40))
  on conflict (endpoint, agenda_id) do update set p256dh = excluded.p256dh, auth = excluded.auth, name = excluded.name;
  return true;
end $$;

create or replace function public.agenda_save(
  p_code text, p_id uuid, p_title text, p_date date, p_all_day boolean,
  p_start text, p_end text, p_place text, p_notes text, p_author text, p_allow_edit boolean
) returns public.agenda_events language plpgsql security definer set search_path = '' as $$
declare
  aid uuid;
  r public.agenda_events;
  old public.agenda_events;
  me text := left(trim(coalesce(p_author,'')),40);
  is_owner boolean;
  quando text;
  ag text;
begin
  aid := public.agenda_auth(p_code);
  select name into ag from public.agenda_agendas where id = aid;
  quando := to_char(p_date,'DD/MM') || case when coalesce(p_all_day,false) or nullif(p_start,'') is null then ' (dia inteiro)' else ' às ' || p_start end;
  if p_id is null then
    insert into public.agenda_events (agenda_id, title, date, all_day, start_time, end_time, place, notes, created_by, edited_by, allow_edit)
    values (aid, trim(p_title), p_date, coalesce(p_all_day,false), nullif(p_start,''), nullif(p_end,''),
            coalesce(p_place,''), coalesce(p_notes,''), me, me, coalesce(p_allow_edit,false))
    returning * into r;
    perform public.agenda_push_call(jsonb_build_object('kind','send','agenda_id',aid,'exclude',me,
      'title','Novo compromisso: ' || r.title,
      'body', quando || case when me <> '' then ' · marcado por ' || me else '' end || ' · ' || ag));
  else
    select * into old from public.agenda_events where id = p_id and agenda_id = aid;
    if old.id is null then raise exception 'compromisso_nao_encontrado'; end if;
    is_owner := old.created_by = '' or lower(old.created_by) = lower(me);
    if not is_owner and not old.allow_edit then raise exception 'sem_permissao'; end if;
    update public.agenda_events set
      title = trim(p_title), date = p_date, all_day = coalesce(p_all_day,false),
      start_time = nullif(p_start,''), end_time = nullif(p_end,''),
      place = coalesce(p_place,''), notes = coalesce(p_notes,''),
      allow_edit = case when is_owner then coalesce(p_allow_edit, old.allow_edit) else old.allow_edit end,
      reminded_at = case when old.date is distinct from p_date or old.start_time is distinct from nullif(p_start,'') then null else old.reminded_at end,
      edited_by = me, updated_at = now()
    where id = p_id
    returning * into r;
    if old.date is distinct from r.date or old.start_time is distinct from r.start_time or old.all_day is distinct from r.all_day then
      perform public.agenda_push_call(jsonb_build_object('kind','send','agenda_id',aid,'exclude',me,
        'title','Compromisso alterado: ' || r.title,
        'body', 'Agora ' || quando || case when me <> '' then ' · alterado por ' || me else '' end || ' · ' || ag));
    end if;
  end if;
  return r;
end $$;

create or replace function public.agenda_delete(p_code text, p_id uuid, p_author text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare aid uuid; old public.agenda_events;
begin
  aid := public.agenda_auth(p_code);
  select * into old from public.agenda_events where id = p_id and agenda_id = aid;
  if old.id is null then return true; end if;
  if not (old.created_by = '' or lower(old.created_by) = lower(trim(coalesce(p_author,''))) or old.allow_edit) then
    raise exception 'sem_permissao';
  end if;
  delete from public.agenda_events where id = p_id;
  return true;
end $$;

-- Versão antiga do app (sem informar quem exclui).
create or replace function public.agenda_delete(p_code text, p_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare aid uuid;
begin
  aid := public.agenda_auth(p_code);
  delete from public.agenda_events where id = p_id and agenda_id = aid;
  return true;
end $$;

drop function if exists public.agenda_due_reminders();
create function public.agenda_due_reminders()
returns table (title text, body text, agenda_id uuid) language plpgsql security definer set search_path = '' as $$
begin
  return query
  with due as (
    update public.agenda_events e set reminded_at = now()
    where e.reminded_at is null and not e.all_day
      and e.start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and e.date between current_date - 1 and current_date + 2
      and ((e.date + e.start_time::time) at time zone 'America/Sao_Paulo') > now()
      and ((e.date + e.start_time::time) at time zone 'America/Sao_Paulo') <= now() + interval '60 minutes'
    returning e.title as t, e.start_time as s, e.place as p, e.agenda_id as a
  )
  select 'Lembrete: ' || d.t,
         'Começa às ' || d.s || case when d.p <> '' then ' · ' || d.p else '' end || ' · ' || g.name,
         d.a
  from due d join public.agenda_agendas g on g.id = d.a;
end $$;
revoke all on function public.agenda_due_reminders() from public, anon, authenticated;

revoke all on function public.agenda_check(text) from public;
revoke all on function public.agenda_create(text, text, text) from public;
revoke all on function public.agenda_rotate(text, text) from public;
revoke all on function public.agenda_rename(text, text, text) from public;
grant execute on function public.agenda_check(text) to anon;
grant execute on function public.agenda_create(text, text, text) to anon;
grant execute on function public.agenda_rotate(text, text) to anon;
grant execute on function public.agenda_rename(text, text, text) to anon;

notify pgrst, 'reload schema';

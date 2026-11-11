-- Banco da Agenda a Dois (Supabase / Postgres).
-- As tabelas ficam fechadas para acesso direto (RLS ligado e sem políticas).
-- O app só conversa com as funções abaixo, e todas exigem o código da agenda.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.agenda_config (
  id int primary key default 1 check (id = 1),
  code_hash text not null
);

create table if not exists public.agenda_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 120),
  date date not null,
  all_day boolean not null default false,
  start_time text check (start_time is null or start_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  end_time text check (end_time is null or end_time ~ '^[0-2][0-9]:[0-5][0-9]$'),
  place text not null default '' check (char_length(place) <= 120),
  notes text not null default '' check (char_length(notes) <= 1000),
  created_by text not null default '' check (char_length(created_by) <= 40),
  edited_by text not null default '' check (char_length(edited_by) <= 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists agenda_events_date_idx on public.agenda_events (date);

alter table public.agenda_config enable row level security;
alter table public.agenda_events enable row level security;
revoke all on public.agenda_config from anon, authenticated;
revoke all on public.agenda_events from anon, authenticated;

-- Confere o código; espera um pouco quando erra, para dificultar tentativas em massa.
create or replace function public.agenda_auth(p_code text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_code is null or not exists (
    select 1 from public.agenda_config c
    where c.code_hash = extensions.crypt(p_code, c.code_hash)
  ) then
    perform pg_sleep(1);
    raise exception 'codigo_invalido' using errcode = '28000';
  end if;
end $$;
revoke all on function public.agenda_auth(text) from public, anon, authenticated;

create or replace function public.agenda_check(p_code text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform public.agenda_auth(p_code);
  return true;
end $$;

create or replace function public.agenda_list(p_code text)
returns setof public.agenda_events language plpgsql security definer set search_path = '' as $$
begin
  perform public.agenda_auth(p_code);
  return query
    select * from public.agenda_events e
    where e.date >= (current_date - interval '400 days')
    order by e.date, e.start_time nulls first;
end $$;

create or replace function public.agenda_save(
  p_code text, p_id uuid, p_title text, p_date date, p_all_day boolean,
  p_start text, p_end text, p_place text, p_notes text, p_author text
) returns public.agenda_events language plpgsql security definer set search_path = '' as $$
declare r public.agenda_events;
begin
  perform public.agenda_auth(p_code);
  if p_id is null then
    insert into public.agenda_events (title, date, all_day, start_time, end_time, place, notes, created_by, edited_by)
    values (trim(p_title), p_date, coalesce(p_all_day,false), nullif(p_start,''), nullif(p_end,''),
            coalesce(p_place,''), coalesce(p_notes,''), left(coalesce(p_author,''),40), left(coalesce(p_author,''),40))
    returning * into r;
  else
    update public.agenda_events set
      title = trim(p_title), date = p_date, all_day = coalesce(p_all_day,false),
      start_time = nullif(p_start,''), end_time = nullif(p_end,''),
      place = coalesce(p_place,''), notes = coalesce(p_notes,''),
      edited_by = left(coalesce(p_author,''),40), updated_at = now()
    where id = p_id
    returning * into r;
    if r.id is null then raise exception 'compromisso_nao_encontrado'; end if;
  end if;
  return r;
end $$;

create or replace function public.agenda_delete(p_code text, p_id uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform public.agenda_auth(p_code);
  delete from public.agenda_events where id = p_id;
  return true;
end $$;

revoke all on function public.agenda_check(text) from public;
revoke all on function public.agenda_list(text) from public;
revoke all on function public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text) from public;
revoke all on function public.agenda_delete(text, uuid) from public;
grant execute on function public.agenda_check(text) to anon;
grant execute on function public.agenda_list(text) to anon;
grant execute on function public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text) to anon;
grant execute on function public.agenda_delete(text, uuid) to anon;

-- Para definir (ou trocar) o código da agenda, rode no SQL Editor do Supabase,
-- trocando SEU-CODIGO pelo código que vocês vão usar:
--   insert into public.agenda_config (id, code_hash)
--   values (1, extensions.crypt('SEU-CODIGO', extensions.gen_salt('bf')))
--   on conflict (id) do update set code_hash = excluded.code_hash;

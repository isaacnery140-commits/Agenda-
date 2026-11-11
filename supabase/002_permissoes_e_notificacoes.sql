-- Permissão de edição por compromisso + notificações (push).
-- As chaves de notificação (vapid_private, push_secret) ficam só no banco, nunca neste repositório.

create extension if not exists pg_net;
create extension if not exists pg_cron;

alter table public.agenda_events add column if not exists allow_edit boolean not null default false;
alter table public.agenda_events add column if not exists reminded_at timestamptz;

alter table public.agenda_config add column if not exists vapid_public text;
alter table public.agenda_config add column if not exists vapid_private text;
alter table public.agenda_config add column if not exists push_secret text;

create table if not exists public.agenda_push_subs (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.agenda_push_subs enable row level security;
revoke all on public.agenda_push_subs from anon, authenticated;

-- Chama a função de envio (Edge Function "agenda-push"). Nunca impede o salvamento se falhar.
create or replace function public.agenda_push_call(p_body jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  select push_secret into s from public.agenda_config where id = 1;
  if s is null then return; end if;
  perform net.http_post(
    url := 'https://pvhoumlovxjlqvmchobv.supabase.co/functions/v1/agenda-push',
    headers := jsonb_build_object('Content-Type','application/json','x-agenda-secret', s),
    body := p_body
  );
exception when others then null;
end $$;
revoke all on function public.agenda_push_call(jsonb) from public, anon, authenticated;

create or replace function public.agenda_subscribe(p_code text, p_name text, p_endpoint text, p_p256dh text, p_auth text)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  perform public.agenda_auth(p_code);
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then
    raise exception 'assinatura_invalida';
  end if;
  insert into public.agenda_push_subs (endpoint, p256dh, auth, name)
  values (p_endpoint, p_p256dh, p_auth, left(coalesce(p_name,''),40))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, name = excluded.name;
  return true;
end $$;

drop function if exists public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text);
create or replace function public.agenda_save(
  p_code text, p_id uuid, p_title text, p_date date, p_all_day boolean,
  p_start text, p_end text, p_place text, p_notes text, p_author text, p_allow_edit boolean
) returns public.agenda_events language plpgsql security definer set search_path = '' as $$
declare
  r public.agenda_events;
  old public.agenda_events;
  me text := left(trim(coalesce(p_author,'')),40);
  is_owner boolean;
  quando text;
begin
  perform public.agenda_auth(p_code);
  quando := to_char(p_date,'DD/MM') || case when coalesce(p_all_day,false) or nullif(p_start,'') is null then ' (dia inteiro)' else ' às ' || p_start end;
  if p_id is null then
    insert into public.agenda_events (title, date, all_day, start_time, end_time, place, notes, created_by, edited_by, allow_edit)
    values (trim(p_title), p_date, coalesce(p_all_day,false), nullif(p_start,''), nullif(p_end,''),
            coalesce(p_place,''), coalesce(p_notes,''), me, me, coalesce(p_allow_edit,false))
    returning * into r;
    perform public.agenda_push_call(jsonb_build_object('kind','send','exclude',me,
      'title','Novo compromisso: ' || r.title, 'body', quando || case when me <> '' then ' · marcado por ' || me else '' end));
  else
    select * into old from public.agenda_events where id = p_id;
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
      perform public.agenda_push_call(jsonb_build_object('kind','send','exclude',me,
        'title','Compromisso alterado: ' || r.title, 'body', 'Agora ' || quando || case when me <> '' then ' · alterado por ' || me else '' end));
    end if;
  end if;
  return r;
end $$;

drop function if exists public.agenda_delete(text, uuid);
create or replace function public.agenda_delete(p_code text, p_id uuid, p_author text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare old public.agenda_events;
begin
  perform public.agenda_auth(p_code);
  select * into old from public.agenda_events where id = p_id;
  if old.id is null then return true; end if;
  if not (old.created_by = '' or lower(old.created_by) = lower(trim(coalesce(p_author,''))) or old.allow_edit) then
    raise exception 'sem_permissao';
  end if;
  delete from public.agenda_events where id = p_id;
  return true;
end $$;

-- Compromissos que começam em até 1 hora e ainda não foram avisados (horário de Brasília).
create or replace function public.agenda_due_reminders()
returns table (title text, body text) language plpgsql security definer set search_path = '' as $$
begin
  return query
  with due as (
    update public.agenda_events e set reminded_at = now()
    where e.reminded_at is null and not e.all_day
      and e.start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
      and e.date between current_date - 1 and current_date + 2
      and ((e.date + e.start_time::time) at time zone 'America/Sao_Paulo') > now()
      and ((e.date + e.start_time::time) at time zone 'America/Sao_Paulo') <= now() + interval '60 minutes'
    returning e.title as t, e.start_time as s, e.place as p
  )
  select 'Lembrete: ' || d.t, 'Começa às ' || d.s || case when d.p <> '' then ' · ' || d.p else '' end from due d;
end $$;
revoke all on function public.agenda_due_reminders() from public, anon, authenticated;

revoke all on function public.agenda_subscribe(text, text, text, text, text) from public;
revoke all on function public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text, boolean) from public;
revoke all on function public.agenda_delete(text, uuid, text) from public;
grant execute on function public.agenda_subscribe(text, text, text, text, text) to anon;
grant execute on function public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text, boolean) to anon;
grant execute on function public.agenda_delete(text, uuid, text) to anon;

-- Verifica lembretes a cada 5 minutos.
select cron.unschedule(jobid) from cron.job where jobname = 'agenda-reminders';
select cron.schedule('agenda-reminders', '*/5 * * * *', $c$ select public.agenda_push_call('{"kind":"reminders"}'::jsonb) $c$);

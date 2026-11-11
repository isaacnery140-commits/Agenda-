-- Aviso na hora marcada + aviso antecipado ajustável por compromisso (padrão: 60 minutos antes).

alter table public.agenda_events add column if not exists remind_minutes int not null default 60 check (remind_minutes between 0 and 10080);
alter table public.agenda_events add column if not exists notified_at timestamptz;

create or replace function public.agenda_save(
  p_code text, p_id uuid, p_title text, p_date date, p_all_day boolean,
  p_start text, p_end text, p_place text, p_notes text, p_author text, p_allow_edit boolean, p_remind int
) returns public.agenda_events language plpgsql security definer set search_path = '' as $$
declare
  aid uuid;
  r public.agenda_events;
  old public.agenda_events;
  me text := left(trim(coalesce(p_author,'')),40);
  is_owner boolean;
  quando text;
  ag text;
  moved boolean;
begin
  aid := public.agenda_auth(p_code);
  select name into ag from public.agenda_agendas where id = aid;
  quando := to_char(p_date,'DD/MM') || case when coalesce(p_all_day,false) or nullif(p_start,'') is null then ' (dia inteiro)' else ' às ' || p_start end;
  if p_id is null then
    insert into public.agenda_events (agenda_id, title, date, all_day, start_time, end_time, place, notes, created_by, edited_by, allow_edit, remind_minutes)
    values (aid, trim(p_title), p_date, coalesce(p_all_day,false), nullif(p_start,''), nullif(p_end,''),
            coalesce(p_place,''), coalesce(p_notes,''), me, me, coalesce(p_allow_edit,false), coalesce(p_remind,60))
    returning * into r;
    perform public.agenda_push_call(jsonb_build_object('kind','send','agenda_id',aid,'exclude',me,
      'title','Novo compromisso: ' || r.title,
      'body', quando || case when me <> '' then ' · marcado por ' || me else '' end || ' · ' || ag));
  else
    select * into old from public.agenda_events where id = p_id and agenda_id = aid;
    if old.id is null then raise exception 'compromisso_nao_encontrado'; end if;
    is_owner := old.created_by = '' or lower(old.created_by) = lower(me);
    if not is_owner and not old.allow_edit then raise exception 'sem_permissao'; end if;
    moved := old.date is distinct from p_date or old.start_time is distinct from nullif(p_start,'');
    update public.agenda_events set
      title = trim(p_title), date = p_date, all_day = coalesce(p_all_day,false),
      start_time = nullif(p_start,''), end_time = nullif(p_end,''),
      place = coalesce(p_place,''), notes = coalesce(p_notes,''),
      allow_edit = case when is_owner then coalesce(p_allow_edit, old.allow_edit) else old.allow_edit end,
      remind_minutes = coalesce(p_remind, old.remind_minutes),
      reminded_at = case when moved or coalesce(p_remind, old.remind_minutes) <> old.remind_minutes then null else old.reminded_at end,
      notified_at = case when moved then null else old.notified_at end,
      edited_by = me, updated_at = now()
    where id = p_id
    returning * into r;
    if moved or old.all_day is distinct from r.all_day then
      perform public.agenda_push_call(jsonb_build_object('kind','send','agenda_id',aid,'exclude',me,
        'title','Compromisso alterado: ' || r.title,
        'body', 'Agora ' || quando || case when me <> '' then ' · alterado por ' || me else '' end || ' · ' || ag));
    end if;
  end if;
  return r;
end $$;

-- Versão anterior do app (sem escolher o tempo de aviso): mantém o aviso já configurado.
create or replace function public.agenda_save(
  p_code text, p_id uuid, p_title text, p_date date, p_all_day boolean,
  p_start text, p_end text, p_place text, p_notes text, p_author text, p_allow_edit boolean
) returns public.agenda_events language sql security definer set search_path = '' as $$
  select public.agenda_save(p_code, p_id, p_title, p_date, p_all_day, p_start, p_end, p_place, p_notes, p_author, p_allow_edit, null::int);
$$;

-- Momento de início do compromisso (horário de Brasília); nulo se não tiver hora válida.
create or replace function public.agenda_start_ts(e public.agenda_events) returns timestamptz
language sql stable set search_path = '' as $$
  select case when not e.all_day and e.start_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    then (e.date + e.start_time::time) at time zone 'America/Sao_Paulo' end;
$$;
revoke all on function public.agenda_start_ts(public.agenda_events) from public, anon, authenticated;

create or replace function public.agenda_due_reminders()
returns table (title text, body text, agenda_id uuid) language plpgsql security definer set search_path = '' as $$
begin
  return query
  with antes as (
    update public.agenda_events e set reminded_at = now()
    where e.reminded_at is null and e.remind_minutes > 0
      and e.date between current_date - 1 and current_date + 8
      and public.agenda_start_ts(e) > now()
      and public.agenda_start_ts(e) - make_interval(mins => e.remind_minutes) <= now()
    returning e.title as t, e.start_time as s, e.place as p, e.agenda_id as a, e.date as d
  ), agora as (
    update public.agenda_events e set notified_at = now()
    where e.notified_at is null
      and e.date between current_date - 1 and current_date + 1
      and public.agenda_start_ts(e) <= now()
      and public.agenda_start_ts(e) > now() - interval '15 minutes'
    returning e.title as t, e.start_time as s, e.place as p, e.agenda_id as a
  )
  select 'Lembrete: ' || d.t,
         case when d.d = (now() at time zone 'America/Sao_Paulo')::date then 'Hoje' else to_char(d.d,'DD/MM') end
           || ' às ' || d.s || case when d.p <> '' then ' · ' || d.p else '' end || ' · ' || g.name,
         d.a
  from antes d join public.agenda_agendas g on g.id = d.a
  union all
  select 'Agora: ' || n.t,
         'Começa às ' || n.s || case when n.p <> '' then ' · ' || n.p else '' end || ' · ' || g.name,
         n.a
  from agora n join public.agenda_agendas g on g.id = n.a;
end $$;
revoke all on function public.agenda_due_reminders() from public, anon, authenticated;

-- Roda a cada minuto; só chama o envio quando há algum aviso na hora.
create or replace function public.agenda_tick()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (
    select 1 from public.agenda_events e
    where e.date between current_date - 1 and current_date + 8
      and public.agenda_start_ts(e) is not null
      and ( (e.reminded_at is null and e.remind_minutes > 0 and public.agenda_start_ts(e) > now()
             and public.agenda_start_ts(e) - make_interval(mins => e.remind_minutes) <= now())
         or (e.notified_at is null and public.agenda_start_ts(e) <= now() and public.agenda_start_ts(e) > now() - interval '15 minutes') )
  ) then
    perform public.agenda_push_call('{"kind":"reminders"}'::jsonb);
  end if;
end $$;
revoke all on function public.agenda_tick() from public, anon, authenticated;

revoke all on function public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text, boolean, int) from public;
grant execute on function public.agenda_save(text, uuid, text, date, boolean, text, text, text, text, text, boolean, int) to anon;

select cron.schedule('agenda-reminders', '* * * * *', $c$ select public.agenda_tick() $c$);
notify pgrst, 'reload schema';

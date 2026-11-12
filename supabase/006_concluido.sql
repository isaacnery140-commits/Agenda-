-- Marcar compromisso como feito. Compromisso feito não gera mais avisos; remarcar desfaz o "feito".
-- (agenda_due_reminders e agenda_tick, de 005, passaram a ignorar compromissos com done_at preenchido.)
alter table public.agenda_events add column if not exists done_at timestamptz;
alter table public.agenda_events add column if not exists done_by text not null default '';

create or replace function public.agenda_events_moved() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.date is distinct from old.date or new.start_time is distinct from old.start_time then
    new.done_at := null; new.done_by := '';
  end if;
  return new;
end $$;
drop trigger if exists agenda_events_moved on public.agenda_events;
create trigger agenda_events_moved before update on public.agenda_events
for each row execute function public.agenda_events_moved();

create or replace function public.agenda_done(p_code text, p_id uuid, p_done boolean, p_author text)
returns public.agenda_events language plpgsql security definer set search_path = '' as $$
declare aid uuid; r public.agenda_events; me text := left(trim(coalesce(p_author,'')),40); ag text;
begin
  aid := public.agenda_auth(p_code);
  update public.agenda_events set
    done_at = case when coalesce(p_done,true) then coalesce(done_at, now()) else null end,
    done_by = case when coalesce(p_done,true) then case when done_at is null then me else done_by end else '' end
  where id = p_id and agenda_id = aid
  returning * into r;
  if r.id is null then raise exception 'compromisso_nao_encontrado'; end if;
  if coalesce(p_done,true) then
    select name into ag from public.agenda_agendas where id = aid;
    perform public.agenda_push_call(jsonb_build_object('kind','send','agenda_id',aid,'exclude',me,
      'title','Feito: ' || r.title, 'body', case when me <> '' then 'Marcado como feito por ' || me || ' · ' else '' end || ag));
  end if;
  return r;
end $$;
revoke all on function public.agenda_done(text, uuid, boolean, text) from public;
grant execute on function public.agenda_done(text, uuid, boolean, text) to anon;

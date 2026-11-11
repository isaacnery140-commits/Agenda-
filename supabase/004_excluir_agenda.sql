-- Exclui a agenda inteira (compromissos e inscrições de notificação vão junto). Só quem criou.
create or replace function public.agenda_remove(p_code text, p_author text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare aid uuid; a public.agenda_agendas;
begin
  aid := public.agenda_auth(p_code);
  select * into a from public.agenda_agendas where id = aid;
  if a.created_by <> '' and lower(a.created_by) <> lower(trim(coalesce(p_author,''))) then raise exception 'sem_permissao'; end if;
  delete from public.agenda_agendas where id = aid;
  return true;
end $$;
revoke all on function public.agenda_remove(text, text) from public;
grant execute on function public.agenda_remove(text, text) to anon;

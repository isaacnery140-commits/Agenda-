-- Metas: 1ª parcela/entrega com comprovante, galga por máquina, bônus por máquina acima da meta,
-- e ações em várias vendas de uma vez. Tudo continua passando por funções que conferem o código.

-- vendas: campos novos
alter table public.metas_vendas
  add column if not exists pago boolean not null default false,
  add column if not exists parcela_informada boolean not null default false,
  add column if not exists parcela_valor numeric check (parcela_valor is null or parcela_valor >= 0),
  add column if not exists comprovante_id uuid,
  add column if not exists comprovante_nome text not null default '' check (char_length(comprovante_nome) <= 120),
  add column if not exists maquinas jsonb not null default '[]'::jsonb check (jsonb_typeof(maquinas) = 'array');

-- config: valor por máquina acima de cada meta
alter table public.metas_config
  add column if not exists valor1 numeric not null default 0 check (valor1 >= 0),
  add column if not exists valor2 numeric not null default 0 check (valor2 >= 0);

-- comprovantes guardados no banco (só acessíveis com o código)
create table if not exists public.metas_comprovantes (
  id uuid primary key default gen_random_uuid(),
  venda_id uuid,
  nome text not null default '' check (char_length(nome) <= 120),
  tipo text not null default '' check (char_length(tipo) <= 80),
  dados text not null check (char_length(dados) <= 4000000),
  created_by text not null default '' check (char_length(created_by) <= 40),
  created_at timestamptz not null default now()
);
alter table public.metas_comprovantes enable row level security;
revoke all on public.metas_comprovantes from anon, authenticated;

create or replace function public.metas_venda_json(v public.metas_vendas)
returns jsonb language sql immutable set search_path to '' as $$
  select jsonb_build_object('id',v.id,'data',v.data,'mes',v.mes,'ano',v.ano,'cliente',v.cliente,'produto',v.produto,'preco',v.preco,
    'quantidade',v.quantidade,'entregue',v.entregue,'comissao',v.comissao,'ordem',v.ordem,'createdBy',v.created_by,'editedBy',v.edited_by,'updatedAt',v.updated_at,
    'pago',v.pago,'parcelaInformada',v.parcela_informada,'parcelaValor',v.parcela_valor,
    'comprovanteId',v.comprovante_id,'comprovanteNome',v.comprovante_nome,'maquinas',v.maquinas);
$$;

create or replace function public.metas_cfg_json()
returns jsonb language sql security definer set search_path to '' as $$
  select jsonb_build_object('ano',c.ano,'metaAno',c.meta_ano,'metaSemestre',c.meta_semestre,'metaMes',c.meta_mes,
    'metaMensal',c.meta_mensal,'comissaoPaga',c.comissao_paga,'updatedBy',c.updated_by,'updatedAt',c.updated_at,
    'meta1',c.meta1,'meta2',c.meta2,'valor1',c.valor1,'valor2',c.valor2)
  from public.metas_config c where c.id = 1;
$$;

create or replace function public.metas_config_save(p_code text, p_data jsonb, p_author text)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  perform public.metas_auth(p_code);
  update public.metas_config set
    ano = coalesce(nullif(p_data->>'ano','')::int, ano),
    meta_ano = coalesce(nullif(p_data->>'metaAno','')::int, meta_ano),
    meta_mensal = coalesce(nullif(p_data->>'metaMensal','')::int, meta_mensal),
    meta1 = coalesce(nullif(p_data->>'meta1','')::int, meta1),
    meta2 = coalesce(nullif(p_data->>'meta2','')::int, meta2),
    valor1 = coalesce(nullif(p_data->>'valor1','')::numeric, valor1),
    valor2 = coalesce(nullif(p_data->>'valor2','')::numeric, valor2),
    meta_semestre = case when jsonb_typeof(p_data->'metaSemestre') = 'object' then p_data->'metaSemestre' else meta_semestre end,
    meta_mes = case when jsonb_typeof(p_data->'metaMes') = 'object' then p_data->'metaMes' else meta_mes end,
    comissao_paga = case when jsonb_typeof(p_data->'comissaoPaga') = 'object' then p_data->'comissaoPaga' else comissao_paga end,
    updated_by = left(trim(coalesce(p_author,'')),40), updated_at = now()
  where id = 1;
  return public.metas_cfg_json();
end $$;

-- salvar uma venda: campos ausentes ficam como estão
create or replace function public.metas_save(p_code text, p_id uuid, p_data jsonb, p_author text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare r public.metas_vendas; d date; me text := left(trim(coalesce(p_author,'')),40);
  maq jsonb := case when jsonb_typeof(p_data->'maquinas') = 'array' then p_data->'maquinas' else null end;
begin
  perform public.metas_auth(p_code);
  if maq is not null and length(maq::text) > 20000 then raise exception 'maquinas_grande_demais'; end if;
  if p_id is not null and exists (select 1 from public.metas_vendas where id = p_id) then
    select * into r from public.metas_vendas where id = p_id;
    d := coalesce(nullif(p_data->>'data','')::date, r.data);
    update public.metas_vendas set
      data = d, mes = extract(month from d)::int, ano = extract(year from d)::int,
      cliente = left(coalesce(p_data->>'cliente', cliente),80),
      produto = left(coalesce(p_data->>'produto', produto),80),
      preco = case when p_data ? 'preco' then nullif(p_data->>'preco','')::numeric else preco end,
      quantidade = coalesce(nullif(p_data->>'quantidade','')::int, quantidade),
      entregue = coalesce((p_data->>'entregue')::boolean, entregue),
      comissao = case when p_data ? 'comissao' then nullif(p_data->>'comissao','')::numeric else comissao end,
      pago = coalesce((p_data->>'pago')::boolean, pago),
      parcela_informada = coalesce((p_data->>'parcelaInformada')::boolean, parcela_informada),
      parcela_valor = case when p_data ? 'parcelaValor' then nullif(p_data->>'parcelaValor','')::numeric else parcela_valor end,
      comprovante_id = case when p_data ? 'comprovanteId' then nullif(p_data->>'comprovanteId','')::uuid else comprovante_id end,
      comprovante_nome = case when p_data ? 'comprovanteNome' then left(coalesce(p_data->>'comprovanteNome',''),120) else comprovante_nome end,
      maquinas = coalesce(maq, maquinas),
      edited_by = me, updated_at = now()
    where id = p_id returning * into r;
  else
    d := coalesce(nullif(p_data->>'data','')::date, current_date);
    if (select count(*) from public.metas_vendas) >= 20000 then raise exception 'limite_de_vendas'; end if;
    insert into public.metas_vendas (id, data, mes, ano, cliente, produto, preco, quantidade, entregue, comissao, ordem, created_by, edited_by,
      pago, parcela_informada, parcela_valor, comprovante_id, comprovante_nome, maquinas)
    values (coalesce(p_id, gen_random_uuid()), d, extract(month from d)::int, extract(year from d)::int,
      left(coalesce(p_data->>'cliente',''),80), left(coalesce(p_data->>'produto',''),80),
      nullif(p_data->>'preco','')::numeric, coalesce(nullif(p_data->>'quantidade','')::int,1),
      coalesce((p_data->>'entregue')::boolean,false), nullif(p_data->>'comissao','')::numeric,
      (extract(epoch from clock_timestamp())*1000)::bigint, me, me,
      coalesce((p_data->>'pago')::boolean,false), coalesce((p_data->>'parcelaInformada')::boolean,false),
      nullif(p_data->>'parcelaValor','')::numeric, nullif(p_data->>'comprovanteId','')::uuid,
      left(coalesce(p_data->>'comprovanteNome',''),120), coalesce(maq,'[]'::jsonb))
    returning * into r;
  end if;
  return public.metas_venda_json(r);
end $$;

-- várias vendas de uma vez (entregue / 1ª parcela paga). Entrega só vale para quem tem a 1ª parcela paga.
create or replace function public.metas_bulk(p_code text, p_ids uuid[], p_campo text, p_valor boolean, p_author text)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare me text := left(trim(coalesce(p_author,'')),40);
begin
  perform public.metas_auth(p_code);
  if coalesce(array_length(p_ids,1),0) > 2000 then raise exception 'muitas_vendas'; end if;
  if p_campo = 'entregue' then
    update public.metas_vendas set entregue = p_valor, edited_by = me, updated_at = now()
      where id = any(p_ids) and (not p_valor or pago);
  elsif p_campo = 'pago' then
    update public.metas_vendas set pago = p_valor, parcela_informada = true, edited_by = me, updated_at = now()
      where id = any(p_ids);
  else raise exception 'campo_invalido'; end if;
  return coalesce((select jsonb_agg(public.metas_venda_json(v)) from public.metas_vendas v where v.id = any(p_ids)),'[]'::jsonb);
end $$;

-- comprovantes
create or replace function public.metas_comp_save(p_code text, p_venda uuid, p_nome text, p_tipo text, p_dados text, p_author text)
returns uuid language plpgsql security definer set search_path to '' as $$
declare i uuid;
begin
  perform public.metas_auth(p_code);
  if p_dados is null or length(p_dados) > 4000000 then raise exception 'arquivo_grande_demais'; end if;
  if (select count(*) from public.metas_comprovantes) >= 5000 then raise exception 'limite_de_comprovantes'; end if;
  insert into public.metas_comprovantes (venda_id, nome, tipo, dados, created_by)
  values (p_venda, left(coalesce(p_nome,''),120), left(coalesce(p_tipo,''),80), p_dados, left(trim(coalesce(p_author,'')),40))
  returning id into i;
  return i;
end $$;

create or replace function public.metas_comp_get(p_code text, p_id uuid)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  perform public.metas_auth(p_code);
  return (select jsonb_build_object('nome',c.nome,'tipo',c.tipo,'dados',c.dados) from public.metas_comprovantes c where c.id = p_id);
end $$;

revoke all on function public.metas_bulk(text, uuid[], text, boolean, text) from public;
revoke all on function public.metas_comp_save(text, uuid, text, text, text, text) from public;
revoke all on function public.metas_comp_get(text, uuid) from public;
grant execute on function public.metas_bulk(text, uuid[], text, boolean, text) to anon, authenticated;
grant execute on function public.metas_comp_save(text, uuid, text, text, text, text) to anon, authenticated;
grant execute on function public.metas_comp_get(text, uuid) to anon, authenticated;

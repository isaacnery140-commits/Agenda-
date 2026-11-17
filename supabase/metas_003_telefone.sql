-- Metas: telefone de contato do cliente (aplicado junto com nova versão de metas_venda_json e metas_save,
-- iguais às de metas_002 mais o campo 'telefone').
alter table public.metas_vendas add column if not exists telefone text not null default '' check (char_length(telefone) <= 30);

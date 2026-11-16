# Vendas de Máquinas — metas compartilhadas

Metas e vendas de máquinas, feitas para usar no celular ou no computador. Abre direto no navegador, **sem conta e sem login**: cada pessoa digita o próprio nome e o código de acesso uma vez, e o aparelho lembra.

- **Visão geral:** total do ano contra a Meta 1 e a Meta 2, gráfico de máquinas por mês com a meta mensal, e resumo de cada mês.
- **Páginas dos meses:** tabela editável (data, cliente, produto, preço, quantidade, entregue, % de comissão), com totais e comissão do mês.
- O que um altera aparece para o outro em até 15 segundos (e na hora em que o app é aberto).

## Como funciona

- `index.html`: o app inteiro.
- `config.js`: endereço do banco e a chave pública do Supabase.
- Os dados ficam no Supabase, nas tabelas `metas_config` e `metas_vendas`. As tabelas ficam fechadas; o app só usa funções (`metas_list`, `metas_save`, `metas_delete`, `metas_config_save`) que conferem o código antes de ler ou gravar.

O código de acesso **não** fica neste repositório; só uma versão embaralhada (hash) fica guardada no banco.

## Publicar

Settings → Pages → *Deploy from a branch* → `main` / `(root)`.

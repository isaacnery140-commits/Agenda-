# Agenda compartilhada

Agendas compartilhadas, feitas para usar no celular. Cada agenda tem um código próprio: só quem recebe o código vê aquela agenda, e uma pessoa pode participar de várias. Abre direto no navegador, sem conta e sem login: cada pessoa digita o código da agenda e o próprio nome uma vez, e o celular lembra.

## Como usar no celular

1. Abra o link do app (GitHub Pages) no celular.
2. Digite o código da agenda e seu nome.
3. Instale como app:
   - **iPhone (Safari):** botão Compartilhar → **Adicionar à Tela de Início**.
   - **Android (Chrome):** menu ⋮ → **Instalar app** ou **Adicionar à tela inicial**.

O que um marca aparece para o outro em até 15 segundos (e na hora em que o app é aberto).

## Como funciona

- `index.html`: o app inteiro (calendário, lista do dia, próximos compromissos).
- `config.js`: endereço do banco e a chave pública do Supabase.
- `sw.js` e `manifest.webmanifest`: deixam o app instalável e com ícone próprio.
- `supabase/schema.sql`: estrutura do banco. As tabelas ficam fechadas; o app só usa funções que conferem o código da agenda antes de ler ou gravar.

O código da agenda **não** fica neste repositório; só uma versão embaralhada (hash) fica guardada no banco. Para trocar o código, veja o final de `supabase/schema.sql`.

## Publicar

Settings → Pages → *Deploy from a branch* → `main` / `(root)`.

-- Metas: prêmio por meta (valor1/valor2 = prêmio ao bater a Meta 1/2), valor por máquina acima da Meta 2 e nº de funcionários para dividir o bônus.
alter table public.metas_config
  add column if not exists valor_extra numeric not null default 0 check (valor_extra >= 0),
  add column if not exists funcionarios integer not null default 1 check (funcionarios between 1 and 1000);
-- metas_cfg_json e metas_config_save passaram a ler/gravar valorExtra e funcionarios.

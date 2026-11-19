-- ===========================================================================
-- AgendaPro — as dúvidas frequentes da casa (63_duvidas_casa.sql)
--
-- O que tem de valer:
--   · o link (sem login) recebe só pergunta e resposta, aparadas, com teto,
--     na ordem do dono, até 20 — e nada mais do cfg do salão;
--   · dúvida sem pergunta ou sem resposta, ou que não é objeto, fica de fora;
--   · salão suspenso ou apelido que não existe: lista vazia;
--   · a peneira (duvidas_limpas) é peça de dentro: anon não a chama.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('63000000-0000-0000-0000-00000000000a', 'duv-a', 'Barbearia Lima', 'ativo', 'America/Sao_Paulo',
   jsonb_build_object('sobre', 'segredo não', 'pagamentos', jsonb_build_object('pix', 'chave'),
     'duvidas', jsonb_build_array(
        jsonb_build_object('p', '  Precisa agendar?  ', 'r', '  Sim, pelo link.  '),
        jsonb_build_object('p', 'Sem resposta', 'r', '   '),
        jsonb_build_object('p', 'Só pergunta'),
        'texto solto', 42,
        jsonb_build_object('p', 7, 'r', 'número no título'),
        jsonb_build_object('p', repeat('a', 300), 'r', repeat('b', 3000), 'extra', 'fora')))),
  ('63000000-0000-0000-0000-00000000000b', 'duv-b', 'Fechado', 'suspenso', 'America/Sao_Paulo',
   jsonb_build_object('duvidas', jsonb_build_array(jsonb_build_object('p', 'Oi?', 'r', 'Oi.')))),
  ('63000000-0000-0000-0000-00000000000c', 'duv-c', 'Sem dúvidas', 'ativo', 'America/Sao_Paulo',
   jsonb_build_object('duvidas', 'não é lista'));

grant usage on schema auth to anon, authenticated;

do $$
declare r jsonb; l jsonb;
begin
  set local role anon;
  r := public.duvidas_da_casa('duv-a');
  reset role;
  l := r -> 'duvidas';
  perform t_verdade('a entrega é um objeto só com a lista de dúvidas', jsonb_typeof(r) = 'object' and (select count(*) from jsonb_object_keys(r)) = 1);
  perform t_verdade('só as duas com pergunta E resposta em texto (veio ' || jsonb_array_length(l) || ')', jsonb_array_length(l) = 2);
  perform t_verdade('aparada, na ordem do dono', l -> 0 = '{"p":"Precisa agendar?","r":"Sim, pelo link."}'::jsonb);
  perform t_verdade('título até 150, resposta até 2000', length(l -> 1 ->> 'p') = 150 and length(l -> 1 ->> 'r') = 2000);
  perform t_verdade('chave estranha não sai', not (l -> 1 ? 'extra'));
  perform t_verdade('nada mais do cfg sai pela porta', position('segredo' in r::text) = 0 and position('chave' in r::text) = 0);
end $$;

do $$
declare n int;
begin
  perform t_verdade('salão suspenso: nada', jsonb_array_length(public.duvidas_da_casa('duv-b') -> 'duvidas') = 0);
  perform t_verdade('apelido que não existe: nada', jsonb_array_length(public.duvidas_da_casa('nao-existe') -> 'duvidas') = 0);
  perform t_verdade('cfg.duvidas que não é lista: nada', jsonb_array_length(public.duvidas_da_casa('duv-c') -> 'duvidas') = 0);
  select jsonb_array_length(public.duvidas_limpas(
           (select jsonb_agg(jsonb_build_object('p', 'P' || g, 'r', 'R')) from generate_series(1, 30) g)))
    into n;
  perform t_verdade('no máximo 20 dúvidas (veio ' || n || ')', n = 20);
  perform t_verdade('nulo vira lista vazia', public.duvidas_limpas(null) = '[]'::jsonb);
  perform t_verdade('a peneira é peça de dentro', not has_function_privilege('anon', 'public.duvidas_limpas(jsonb)', 'execute')
             and not has_function_privilege('authenticated', 'public.duvidas_limpas(jsonb)', 'execute'));
  perform t_verdade('a entrega é aberta ao link', has_function_privilege('anon', 'public.duvidas_da_casa(text)', 'execute'));
end $$;

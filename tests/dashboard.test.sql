-- ===========================================================================
-- PediHub — o Ranking (60_dashboard.sql)
--
-- Uma agenda montada à mão, com a resposta sabida de antemão:
--   · a Maria marcou 3 vezes (1ª do ranking), a Joana 2, a Carla 1;
--   · a Joana gastou mais (2 x R$ 150) que a Maria (3 x R$ 50);
--   · a Ju atendeu 4, a Bia 2: a Ju é a 1ª;
--   · a Carla é nova e veio pelo link; a Paula é nova pelo balcão;
--     a Maria e a Joana já vinham antes: são recorrentes;
--   · a Dona Rosa vinha sempre e sumiu;
--   · 4 visitantes no link, 3 pelo Instagram.
-- E quem vê o quê: a gestão tudo; a Ju só o dela; a recepção, nada; o
-- vizinho, nada; o plano Grátis, nada.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a6000000-0000-0000-0000-00000000000a'),  -- Ana  — dona
  ('b6000000-0000-0000-0000-00000000000b'),  -- Rita — recepção
  ('d6000000-0000-0000-0000-00000000000d'),  -- Ju   — profissional
  ('e6000000-0000-0000-0000-00000000000e');  -- Eva  — dona do vizinho
insert into public.perfis (id, nome, telefone) values
  ('a6000000-0000-0000-0000-00000000000a', 'Ana',  '+5511960000001'),
  ('b6000000-0000-0000-0000-00000000000b', 'Rita', '+5511960000002'),
  ('d6000000-0000-0000-0000-00000000000d', 'Ju',   '+5511960000004'),
  ('e6000000-0000-0000-0000-00000000000e', 'Eva',  '+5511960000005')
on conflict (id) do update set nome = excluded.nome;

insert into public.saloes (id, slug, nome, status, fuso) values
  ('60000000-0000-0000-0000-00000000000a', 'rank-a', 'Salão do Ranking', 'ativo', 'America/Sao_Paulo'),
  ('60000000-0000-0000-0000-00000000000b', 'rank-b', 'Salão Vizinho',    'ativo', 'America/Sao_Paulo'),
  ('60000000-0000-0000-0000-00000000000c', 'rank-c', 'Salão Grátis',     'ativo', 'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status) values
  ('60000000-0000-0000-0000-00000000000a', 'time', 'ativa'),
  ('60000000-0000-0000-0000-00000000000b', 'time', 'ativa'),
  ('60000000-0000-0000-0000-00000000000c', 'gratuito', 'ativa');
insert into public.vinculos (perfil_id, salao_id, papel) values
  ('a6000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-00000000000a', 'dono'),
  ('b6000000-0000-0000-0000-00000000000b', '60000000-0000-0000-0000-00000000000a', 'recepcao'),
  ('d6000000-0000-0000-0000-00000000000d', '60000000-0000-0000-0000-00000000000a', 'profissional'),
  ('e6000000-0000-0000-0000-00000000000e', '60000000-0000-0000-0000-00000000000b', 'dono'),
  ('a6000000-0000-0000-0000-00000000000a', '60000000-0000-0000-0000-00000000000c', 'dono');
insert into public.profissionais (id, salao_id, perfil_id, nome, ativo) values
  ('96000000-0000-0000-0000-00000000000d', '60000000-0000-0000-0000-00000000000a', 'd6000000-0000-0000-0000-00000000000d', 'Ju', true),
  ('96000000-0000-0000-0000-00000000000e', '60000000-0000-0000-0000-00000000000a', null, 'Bia', true);
insert into public.servicos (id, salao_id, nome, duracao_min, preco) values
  ('61000000-0000-0000-0000-0000000000a1', '60000000-0000-0000-0000-00000000000a', 'Corte',  60, 50),
  ('61000000-0000-0000-0000-0000000000a2', '60000000-0000-0000-0000-00000000000a', 'Mechas', 60, 150);
insert into public.clientes (id, salao_id, nome, telefone, pelo_link, criado_em) values
  ('c6000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-00000000000a', 'Maria',     '11960001001', false, now() - interval '200 days'),
  ('c6000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-00000000000a', 'Joana',     '11960001002', false, now() - interval '200 days'),
  ('c6000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-00000000000a', 'Carla',     '11960001003', true,  '2026-03-02 12:00-03'),
  ('c6000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-00000000000a', 'Paula',     '11960001004', false, now() - interval '200 days'),
  ('c6000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-00000000000a', 'Dona Rosa', '11960001005', false, now() - interval '400 days');
grant usage on schema auth to anon, authenticated;

-- A agenda, com os gatilhos fora (o teste é da conta, não da marcação).
alter table public.agendamentos disable trigger user;
create or replace function t_ag(p_cli int, p_prof text, p_quando text, p_status text, p_origem text, p_valor numeric, p_serv text)
returns void language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.agendamentos (id, salao_id, cliente_id, profissional_id, inicio, fim, status, origem, valor_previsto, criado_em)
  values (v_id, '60000000-0000-0000-0000-00000000000a',
          ('c6000000-0000-0000-0000-00000000000' || p_cli)::uuid,
          case p_prof when 'Ju' then '96000000-0000-0000-0000-00000000000d'::uuid else '96000000-0000-0000-0000-00000000000e'::uuid end,
          p_quando::timestamptz, p_quando::timestamptz + interval '1 hour', p_status, p_origem, p_valor, p_quando::timestamptz - interval '2 days');
  insert into public.agendamento_servicos (agendamento_id, servico_id, ordem, duracao_min, preco)
  values (v_id, case p_serv when 'Corte' then '61000000-0000-0000-0000-0000000000a1'::uuid else '61000000-0000-0000-0000-0000000000a2'::uuid end,
          0, 60, p_valor);
end $$;
-- Antes de março: a história.
select t_ag(1, 'Ju',  '2026-01-10 10:00-03', 'concluido', 'recepcao', 50,  'Corte');
select t_ag(2, 'Bia', '2026-01-12 10:00-03', 'concluido', 'recepcao', 150, 'Mechas');
select t_ag(5, 'Ju',  '2025-10-01 10:00-03', 'concluido', 'recepcao', 50,  'Corte');
select t_ag(5, 'Ju',  '2025-11-01 10:00-03', 'concluido', 'recepcao', 50,  'Corte');
select t_ag(5, 'Ju',  '2025-12-01 10:00-03', 'concluido', 'recepcao', 50,  'Corte');
-- Março de 2026: o período do ranking.
select t_ag(1, 'Ju',  '2026-03-03 10:00-03', 'concluido', 'recepcao', 50,  'Corte');
select t_ag(1, 'Ju',  '2026-03-10 10:00-03', 'concluido', 'online',   50,  'Corte');
select t_ag(1, 'Ju',  '2026-03-17 10:00-03', 'concluido', 'online',   50,  'Corte');
select t_ag(2, 'Bia', '2026-03-05 15:00-03', 'concluido', 'recepcao', 150, 'Mechas');
select t_ag(2, 'Bia', '2026-03-19 15:00-03', 'concluido', 'recepcao', 150, 'Mechas');
select t_ag(3, 'Ju',  '2026-03-07 09:00-03', 'concluido', 'online',   50,  'Corte');   -- nova, pelo link
select t_ag(4, 'Ju',  '2026-03-14 09:00-03', 'faltou',    'recepcao', 50,  'Corte');   -- nova, balcão, faltou
select t_ag(4, 'Ju',  '2026-03-21 09:00-03', 'cancelado', 'online',   50,  'Corte');   -- cancelado: não conta
alter table public.agendamentos enable trigger user;

-- As visitas de março: 4 visitantes, 3 pelo Instagram; e a Rita (equipe) abrindo o próprio link.
insert into public.link_visitas (salao_id, dia, visitante, origem, vezes) values
  ('60000000-0000-0000-0000-00000000000a', '2026-03-02', md5('x1'), 'instagram', 2),
  ('60000000-0000-0000-0000-00000000000a', '2026-03-02', md5('x2'), 'instagram', 1),
  ('60000000-0000-0000-0000-00000000000a', '2026-03-09', md5('x3'), 'instagram', 1),
  ('60000000-0000-0000-0000-00000000000a', '2026-03-09', md5('x4'), 'whatsapp',  3),
  ('60000000-0000-0000-0000-00000000000a', '2026-02-20', md5('x5'), 'google',    1);  -- fevereiro: fica fora

create or replace function t_como(p_quem uuid, p_sql text) returns text
language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_quem::text, ''), true);
  perform set_config('role', case when p_quem is null then 'anon' else 'authenticated' end, true);
  begin
    execute p_sql into r;
  exception when others then
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claim.sub', '', true);
    return 'ERRO: ' || sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return coalesce(r, '');
end $$;
create temporary table d as select t_como('a6000000-0000-0000-0000-00000000000a',
  $q$select public.dashboard('60000000-0000-0000-0000-00000000000a', '2026-03-01', '2026-03-31')::text$q$) as t;
grant select on d to public;
create or replace function j() returns jsonb language sql as $$ select t::jsonb from d $$;

-- ===========================================================================
\echo ''
\echo '1. O resumo de março'
-- ===========================================================================
do $$
declare r jsonb := j()->'resumo';
begin
  perform t_igual('marcados (sem os cancelados): 7', (r->>'marcados')::bigint, 7);
  perform t_igual('atendidos: 6', (r->>'atendidos')::bigint, 6);
  perform t_igual('faltas: 1', (r->>'faltas')::bigint, 1);
  perform t_igual('cancelados: 1', (r->>'cancelados')::bigint, 1);
  perform t_igual('pelo link: 3 (o cancelado não conta)', (r->>'peloLink')::bigint, 3);
  perform t_igual('valor atendido: 3x50 + 2x150 + 50 = R$ 500', (r->>'valor')::numeric::bigint, 500);
  perform t_igual('clientes diferentes no mês: 4', (r->>'clientes')::bigint, 4);
  perform t_igual('novas: 2 (Carla e Paula)', (r->>'novas')::bigint, 2);
  perform t_igual('novas pelo link: 1 (Carla)', (r->>'novasPeloLink')::bigint, 1);
  perform t_igual('novas no balcão: 1 (Paula)', (r->>'novasNoBalcao')::bigint, 1);
  perform t_igual('recorrentes: 2 (Maria e Joana já vinham)', (r->>'recorrentes')::bigint, 2);
  perform t_igual('vieram mais de uma vez no mês: 2', (r->>'maisDeUmaVez')::bigint, 2);
  perform t_igual('cadastros pelo link no mês: 1', (r->>'cadastrosPeloLink')::bigint, 1);
  perform t_igual('e o mês anterior (fevereiro) para comparar: nada marcado',
    ((j()->'antes')->>'marcados')::bigint, 0);
  perform t_igual('fevereiro teve 1 visitante', ((j()->'antes')->>'visitantes')::bigint, 1);
end $$;

-- ===========================================================================
\echo ''
\echo '2. Os rankings'
-- ===========================================================================
do $$
declare c jsonb := j()->'clientesQueMaisMarcaram'; g jsonb := j()->'clientesQueMaisGastaram';
        p jsonb := j()->'profissionais'; s jsonb := j()->'servicos';
begin
  perform t_texto('1ª que mais marcou: Maria (3)', c->0->>'nome' || ' ' || (c->0->>'marcados'), 'Maria 3');
  perform t_texto('2ª: Joana (2)', c->1->>'nome' || ' ' || (c->1->>'marcados'), 'Joana 2');
  perform t_igual('4 clientes no ranking (o horário cancelado da Paula não a tira: ela faltou)', jsonb_array_length(c), 4);
  perform t_texto('a falta aparece na linha da Paula',
    (select x->>'faltas' from jsonb_array_elements(c) x where x->>'nome' = 'Paula'), '1');
  perform t_texto('quem mais gastou: Joana (R$ 300)', g->0->>'nome' || ' ' || ((g->0->>'valor')::numeric)::int, 'Joana 300');
  perform t_texto('depois a Maria (R$ 150)', g->1->>'nome' || ' ' || ((g->1->>'valor')::numeric)::int, 'Maria 150');
  perform t_falso('quem não gastou nada não entra no "mais gastaram" (a Paula faltou)',
    exists (select 1 from jsonb_array_elements(g) x where x->>'nome' = 'Paula'));

  perform t_texto('quem mais atendeu: Ju (4)', p->0->>'nome' || ' ' || (p->0->>'atendidos'), 'Ju 4');
  perform t_texto('depois a Bia (2)', p->1->>'nome' || ' ' || (p->1->>'atendidos'), 'Bia 2');
  perform t_texto('a Ju: 2 clientes atendidas (a Paula faltou), 1 falta, 1 cancelado, 3 pelo link',
    concat_ws(',', p->0->>'clientes', p->0->>'faltas', p->0->>'cancelados', p->0->>'peloLink'), '2,1,1,3');
  perform t_texto('a Bia fez R$ 300', ((p->1->>'valor')::numeric)::int::text, '300');

  perform t_texto('serviço mais pedido: Corte (5)', s->0->>'nome' || ' ' || (s->0->>'vezes'), 'Corte 5');

  perform t_texto('quem sumiu: a Dona Rosa, com 3 atendimentos',
    (j()->'sumidas')->0->>'nome' || ' ' || ((j()->'sumidas')->0->>'atendimentos'), 'Dona Rosa 3');
  perform t_igual('e só ela (a Maria vem sempre)', jsonb_array_length(j()->'sumidas'), 1);

  perform t_texto('por dia da semana (dom..sáb): terças cheias',
    (j()->'porDiaDaSemana')::text, '[0, 0, 3, 0, 2, 0, 2]');
end $$;

-- ===========================================================================
\echo ''
\echo '3. O link'
-- ===========================================================================
do $$
declare l jsonb := j()->'link';
begin
  perform t_igual('4 visitantes em março', (l->>'visitantes')::bigint, 4);
  perform t_igual('7 visitas (a mesma pessoa voltando conta como visita, não como visitante)', (l->>'visitas')::bigint, 7);
  perform t_texto('origem principal: Instagram (3)', (l->'porOrigem'->0->>'origem') || ' ' || (l->'porOrigem'->0->>'n'), 'instagram 3');
  perform t_igual('dois dias com visita', jsonb_array_length(l->'porDia'), 2);
  perform t_texto('contando desde o primeiro dia registrado', l->>'contandoDesde', '2026-02-20');
end $$;

-- ===========================================================================
\echo ''
\echo '4. Quem vê o quê'
-- ===========================================================================
do $$
declare e text; m jsonb;
begin
  e := t_como('d6000000-0000-0000-0000-00000000000d',
    $q$select public.dashboard('60000000-0000-0000-0000-00000000000a', '2026-03-01', '2026-03-31')::text$q$);
  m := e::jsonb;
  perform t_texto('a Ju vê o dela', m->>'escopo', 'meu');
  perform t_igual('só ela no ranking de profissionais', jsonb_array_length(m->'profissionais'), 1);
  perform t_igual('só os horários dela: 5 marcados', ((m->'resumo')->>'marcados')::bigint, 5);
  perform t_falso('nenhuma cliente da Bia na lista dela',
    exists (select 1 from jsonb_array_elements(m->'clientesQueMaisMarcaram') x where x->>'nome' = 'Joana'));
  perform t_verdade('e nada das visitas do link nem dos cadastros', (m->'link') = 'null'::jsonb
    and (m->'resumo'->'cadastrosPeloLink') = 'null'::jsonb);

  e := t_como('b6000000-0000-0000-0000-00000000000b',
    $q$select public.dashboard('60000000-0000-0000-0000-00000000000a', '2026-03-01', '2026-03-31')::text$q$);
  perform t_verdade('a recepção (sem ficha de quem atende) não vê — ' || e, e like 'ERRO: O Ranking é da gestão%');
  e := t_como('e6000000-0000-0000-0000-00000000000e',
    $q$select public.dashboard('60000000-0000-0000-0000-00000000000a', '2026-03-01', '2026-03-31')::text$q$);
  perform t_verdade('a dona do vizinho não lê o ranking deste', e like 'ERRO: Sem permissão%');
  e := t_como(null, $q$select public.dashboard('60000000-0000-0000-0000-00000000000a', '2026-03-01', '2026-03-31')::text$q$);
  perform t_verdade('visitante sem login nem chama', e like 'ERRO: permission denied%');
  e := t_como('a6000000-0000-0000-0000-00000000000a',
    $q$select public.dashboard('60000000-0000-0000-0000-00000000000c', '2026-03-01', '2026-03-31')::text$q$);
  perform t_verdade('no plano Grátis, é do Básico para cima — ' || e, e like 'ERRO: O Ranking está disponível a partir do plano Básico%');
  e := t_como('a6000000-0000-0000-0000-00000000000a',
    $q$select public.dashboard('60000000-0000-0000-0000-00000000000a', '2026-03-31', '2026-03-01')::text$q$);
  perform t_verdade('datas trocadas são recusadas', e like 'ERRO: Confira as datas%');
end $$;

-- ===========================================================================
\echo ''
\echo '5. O contador de visitas'
-- ===========================================================================
delete from public.link_visitas;
do $$
declare e text; c text := 'abcdefghijklmnop1234';
begin
  e := t_como(null, format($q$select public.registrar_visita('rank-a', '%s', 'instagram')::text$q$, c));
  perform t_igual('a visita sem login conta', (select count(*) from public.link_visitas), 1);
  e := t_como(null, format($q$select public.registrar_visita('rank-a', '%s', 'instagram')::text$q$, c));
  perform t_igual('a mesma pessoa no mesmo dia é 1 visitante', (select count(*) from public.link_visitas), 1);
  perform t_igual('e 2 visitas', (select vezes from public.link_visitas)::bigint, 2);
  perform t_falso('o código do aparelho não fica guardado como veio',
    exists (select 1 from public.link_visitas where visitante like '%' || c || '%'));
  e := t_como(null, $q$select public.registrar_visita('rank-a', 'curto', 'x')::text$q$);
  e := t_como(null, $q$select public.registrar_visita('rank-a', 'abc''); drop table x; --aaaaaaaa', 'x')::text$q$);
  perform t_igual('código fora do formato é ignorado, sem erro', (select count(*) from public.link_visitas), 1);
  e := t_como(null, $q$select public.registrar_visita('rank-a', 'zzzzzzzzzzzzzzzzzzzz', 'site-estranho')::text$q$);
  perform t_texto('origem desconhecida vira "outro"',
    (select string_agg(origem, ',' order by origem) from public.link_visitas), 'instagram,outro');
  e := t_como('d6000000-0000-0000-0000-00000000000d',
    $q$select public.registrar_visita('rank-a', 'qqqqqqqqqqqqqqqqqqqq', 'direto')::text$q$);
  perform t_igual('a equipe abrindo o próprio link não conta', (select count(*) from public.link_visitas), 2);
  e := t_como(null, $q$select public.registrar_visita('nao-existe', 'yyyyyyyyyyyyyyyyyyyy', 'direto')::text$q$);
  perform t_igual('link que não existe não grava nada', (select count(*) from public.link_visitas), 2);
  e := t_como('a6000000-0000-0000-0000-00000000000a', $q$select count(*)::text from public.link_visitas$q$);
  perform t_verdade('ninguém lê a tabela de visitas pela API', e like 'ERRO: permission denied%');
end $$;

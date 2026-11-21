-- ===========================================================================
-- PediHub — complementos e variações (67_complementos)
--
-- A Pizzaria do Léo monta a "Pizza grande" (base R$ 0):
--   Sabores   min 1, max 2, vale o MAIOR  — Calabresa 50, Frango 55, Camarão 80
--   Borda     min 0, max 1, soma          — Catupiry 8, Cheddar 9 (desligada)
--   Extras    min 0, max 2, soma          — Bacon 5, Ovo 3, Milho 2
-- e o "Refrigerante" sem complemento nenhum.
--
--   1. quem grava: a dona grava, a atendente não; o grupo errado é recusado;
--   2. o link enxerga os grupos de quem está à venda;
--   3. o preço: meio a meio cobra o maior; extras somam; o texto fica no item;
--   4. o que é recusado: sem sabor, três sabores, opção desligada, opção de
--      outro item, extras demais — e o preço que a tela "manda" não conta.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a6700000-0000-0000-0000-00000000000a'),  -- Léo — dono
  ('d6700000-0000-0000-0000-00000000000d');  -- Ju  — atendente
insert into public.perfis (id, nome, telefone) values
  ('a6700000-0000-0000-0000-00000000000a', 'Léo', '+5511967000001'),
  ('d6700000-0000-0000-0000-00000000000d', 'Ju',  '+5511967000004')
on conflict (id) do update set nome = excluded.nome, telefone = excluded.telefone;
insert into public.saloes (id, slug, nome, status, fuso) values
  ('56700000-0000-0000-0000-00000000000a', 'pizza-leo', 'Pizzaria do Léo', 'ativo', 'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('56700000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a6700000-0000-0000-0000-00000000000a', '56700000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('d6700000-0000-0000-0000-00000000000d', '56700000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('56710000-0000-0000-0000-0000000000b1', '56700000-0000-0000-0000-00000000000a', 'Pizza grande', 0, true, true, true),
  ('56710000-0000-0000-0000-0000000000b2', '56700000-0000-0000-0000-00000000000a', 'Refrigerante', 10, true, true, true);
grant usage on schema auth to anon, authenticated;

create or replace function t_como(p_quem uuid, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_quem::text, ''), true);
  if p_quem is null then set local role anon; else set local role authenticated; end if;
  execute p_sql into r;
  reset role;
  return r;
end $$;

-- Os grupos, com ids conhecidos para o teste poder escolher.
create or replace function t_grupos() returns text language sql as $$ select $j$[
  {"id":"56720000-0000-0000-0000-0000000000a1","nome":"Sabores","min":1,"max":2,"regra":"maior","opcoes":[
     {"id":"56730000-0000-0000-0000-0000000000c1","nome":"Calabresa","preco":"50"},
     {"id":"56730000-0000-0000-0000-0000000000c2","nome":"Frango","preco":"55"},
     {"id":"56730000-0000-0000-0000-0000000000c3","nome":"Camarão","preco":"80,00"}]},
  {"id":"56720000-0000-0000-0000-0000000000a2","nome":"Borda","min":0,"max":1,"regra":"soma","opcoes":[
     {"id":"56730000-0000-0000-0000-0000000000d1","nome":"Catupiry","preco":"8"},
     {"id":"56730000-0000-0000-0000-0000000000d2","nome":"Cheddar","preco":"9","ativo":false}]},
  {"id":"56720000-0000-0000-0000-0000000000a3","nome":"Extras","min":0,"max":2,"regra":"soma","opcoes":[
     {"id":"56730000-0000-0000-0000-0000000000e1","nome":"Bacon","preco":"5"},
     {"id":"56730000-0000-0000-0000-0000000000e2","nome":"Ovo","preco":"3"},
     {"id":"56730000-0000-0000-0000-0000000000e3","nome":"Milho","preco":"2"}]}]$j$ $$;

-- Um pedido pelo link (anon), retirada no Pix, com os itens dados.
create or replace function t_pedir(p_itens text) returns jsonb language sql as $$
  select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'pizza-leo',
    json_build_object('nome', 'Maria', 'telefone', '11967000010', 'entrega', 'retirada',
                      'pagamento', 'pix', 'itens', p_itens::json)::text))
$$;

\echo ''
\echo '1. Quem grava os complementos'
select t_texto('a atendente não grava',
  erro_de(format('select t_como(%L, %L)', 'd6700000-0000-0000-0000-00000000000d',
    format('select public.salvar_opcoes_do_produto(%L, %L::jsonb)',
           '56710000-0000-0000-0000-0000000000b1', t_grupos()))),
  'Só a gestão muda o cardápio.');
select t_texto('grupo sem opções é recusado',
  erro_de($$select t_como('a6700000-0000-0000-0000-00000000000a',
    'select public.salvar_opcoes_do_produto(''56710000-0000-0000-0000-0000000000b1'', ''[{"nome":"Borda","opcoes":[]}]''::jsonb)')$$),
  'O grupo "Borda" está sem opções.');
select t_texto('mínimo maior que o máximo é recusado',
  erro_de($$select t_como('a6700000-0000-0000-0000-00000000000a',
    'select public.salvar_opcoes_do_produto(''56710000-0000-0000-0000-0000000000b1'', ''[{"nome":"Sabores","min":3,"max":2,"opcoes":[{"nome":"A"},{"nome":"B"},{"nome":"C"}]}]''::jsonb)')$$),
  'No grupo "Sabores", confira o mínimo e o máximo.');
select t_como('a6700000-0000-0000-0000-00000000000a',
  format('select public.salvar_opcoes_do_produto(%L, %L::jsonb)', '56710000-0000-0000-0000-0000000000b1', t_grupos()));
select t_igual('a dona gravou 3 grupos e 8 opções',
  (select count(*) from public.produto_grupos where produto_id = '56710000-0000-0000-0000-0000000000b1')
  * 10 + (select count(*) from public.produto_opcoes o join public.produto_grupos g on g.id = o.grupo_id
           where g.produto_id = '56710000-0000-0000-0000-0000000000b1'), 38);
select t_texto('o preço com vírgula entrou certo (Camarão 80)',
  (select preco::text from public.produto_opcoes where id = '56730000-0000-0000-0000-0000000000c3'), '80.00');
select t_igual('gravar de novo substitui, não duplica',
  (select count(*) from (select t_como('a6700000-0000-0000-0000-00000000000a',
     format('select public.salvar_opcoes_do_produto(%L, %L::jsonb)', '56710000-0000-0000-0000-0000000000b1', t_grupos()))) x
   cross join public.produto_grupos g where g.produto_id = '56710000-0000-0000-0000-0000000000b1'), 3);
select t_verdade('a tela não lê as tabelas direto',
  not has_table_privilege('authenticated', 'public.produto_opcoes', 'select')
  and not has_table_privilege('anon', 'public.produto_grupos', 'select'));

\echo ''
\echo '2. O link enxerga os grupos'
select t_igual('a pizza aparece com 3 grupos; o refri, sem nada',
  (select jsonb_array_length(t_como(null, 'select public.opcoes_da_casa(''pizza-leo'')')
     ->'56710000-0000-0000-0000-0000000000b1')
   + coalesce(jsonb_array_length(t_como(null, 'select public.opcoes_da_casa(''pizza-leo'')')
     ->'56710000-0000-0000-0000-0000000000b2'), 0))::bigint, 3);

\echo ''
\echo '3. O preço e o texto do item'
-- Meio a meio Calabresa (50) + Camarão (80) = vale 80; borda Catupiry 8; Bacon 5 + Ovo 3.
-- 96 por pizza, 2 pizzas = 192; e um refri de 10. A tela "manda" preço 1.
select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b1","quantidade":2,"preco":1,
   "opcoes":["56730000-0000-0000-0000-0000000000c1","56730000-0000-0000-0000-0000000000c3",
             "56730000-0000-0000-0000-0000000000d1","56730000-0000-0000-0000-0000000000e1",
             "56730000-0000-0000-0000-0000000000e2"]},
  {"produto":"56710000-0000-0000-0000-0000000000b2","quantidade":1}]') as r1 \gset
select t_texto('o subtotal é 2 × 96 + 10 = 202 (o preço da tela não conta)',
  (:'r1'::jsonb->>'subtotal'), '202.00');
select t_texto('a unidade da pizza grava 96',
  (select i.preco::text from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
    where p.salao_id = '56700000-0000-0000-0000-00000000000a' and i.ordem = 1), '96.00');
select t_texto('o nome do item leva o meio a meio, a borda e os extras',
  (select i.nome from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
    where p.salao_id = '56700000-0000-0000-0000-00000000000a' and i.ordem = 1),
  'Pizza grande — Sabores: ½ Calabresa, ½ Camarão · Borda: Catupiry · Extras: Bacon, Ovo');
select t_igual('a lista estruturada fica guardada (3 grupos)',
  (select jsonb_array_length(i.opcoes) from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
    where p.salao_id = '56700000-0000-0000-0000-00000000000a' and i.ordem = 1)::bigint, 3);
select t_texto('o refri, sem complemento, fica como era',
  (select i.nome || ' ' || i.preco from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
    where p.salao_id = '56700000-0000-0000-0000-00000000000a' and i.ordem = 2), 'Refrigerante 10.00');

\echo ''
\echo '4. O que é recusado'
select t_texto('pizza sem sabor',
  erro_de($$select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b1","quantidade":1,"opcoes":[]}]')$$),
  'Pizza grande: Escolha sabores.');
select t_texto('três sabores num grupo de até dois',
  erro_de($$select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b1","quantidade":1,
    "opcoes":["56730000-0000-0000-0000-0000000000c1","56730000-0000-0000-0000-0000000000c2","56730000-0000-0000-0000-0000000000c3"]}]')$$),
  'Pizza grande: Em "Sabores", escolha no máximo 2.');
select t_texto('a borda desligada (Cheddar)',
  erro_de($$select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b1","quantidade":1,
    "opcoes":["56730000-0000-0000-0000-0000000000c1","56730000-0000-0000-0000-0000000000d2"]}]')$$),
  'Pizza grande: Uma das opções escolhidas não está mais disponível. Confira o pedido.');
select t_texto('opção da pizza pendurada no refri',
  erro_de($$select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b2","quantidade":1,
    "opcoes":["56730000-0000-0000-0000-0000000000e1"]}]')$$),
  'Refrigerante: Uma das opções escolhidas não está mais disponível. Confira o pedido.');
select t_texto('três extras num grupo de até dois',
  erro_de($$select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b1","quantidade":1,
    "opcoes":["56730000-0000-0000-0000-0000000000c1","56730000-0000-0000-0000-0000000000e1",
              "56730000-0000-0000-0000-0000000000e2","56730000-0000-0000-0000-0000000000e3"]}]')$$),
  'Pizza grande: Em "Extras", escolha no máximo 2.');
select t_texto('id que não é id',
  erro_de($$select t_pedir('[{"produto":"56710000-0000-0000-0000-0000000000b1","quantidade":1,
    "opcoes":["xyz"]}]')$$),
  'Pizza grande: Uma das opções do item não existe mais. Confira o pedido.');

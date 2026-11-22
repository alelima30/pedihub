-- ===========================================================================
-- PediHub — a conta da mesa e o garçom de cada item (73)
--
-- No Bar do Toninho, mesa 5:
--   1. o Wilson (garçom da casa) lança um prato: abre a conta da mesa, e o
--      item sai com o nome dele; vai direto para "em preparo";
--   2. o Beto (freelancer) lança um vinho na MESMA mesa: entra na mesma
--      conta, com o nome do Beto; o cliente pede uma sobremesa pelo QR:
--      também na conta, marcada como do cliente;
--   3. o mapa mostra a mesa 5 aberta com o total; servido antes de fechar
--      NÃO vira venda (a forma de pagamento ainda não existe);
--   4. não fecha com pedido esperando "Aceitar"; aceito, fecha com 10% e
--      no crédito: tudo vira venda, o serviço entra à parte, a mesa libera;
--   5. quem é de fora não vê nem fecha.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a7300000-0000-0000-0000-00000000000a'),  -- Toninho — dono
  ('b7300000-0000-0000-0000-00000000000b'),  -- Wilson  — garçom
  ('c7300000-0000-0000-0000-00000000000c'),  -- Beto    — freelancer
  ('e7300000-0000-0000-0000-00000000000e');  -- de fora
insert into public.perfis (id, nome, telefone) values
  ('a7300000-0000-0000-0000-00000000000a', 'Toninho', '+5511973000001'),
  ('b7300000-0000-0000-0000-00000000000b', 'Wilson Souza', '+5511973000002'),
  ('c7300000-0000-0000-0000-00000000000c', 'Beto Lima', '+5511973000003'),
  ('e7300000-0000-0000-0000-00000000000e', 'Fulano', '+5511973000009')
on conflict (id) do update set nome = excluded.nome;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57300000-0000-0000-0000-00000000000a', 'bar-toninho', 'Bar do Toninho', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"mesas":10}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57300000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7300000-0000-0000-0000-00000000000a', '57300000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('b7300000-0000-0000-0000-00000000000b', '57300000-0000-0000-0000-00000000000a', 'profissional', 'ativo'),
  ('c7300000-0000-0000-0000-00000000000c', '57300000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('57310000-0000-0000-0000-0000000000b1', '57300000-0000-0000-0000-00000000000a', 'Picanha', 80, true, true, true),
  ('57310000-0000-0000-0000-0000000000b2', '57300000-0000-0000-0000-00000000000a', 'Vinho tinto', 60, true, true, true),
  ('57310000-0000-0000-0000-0000000000b3', '57300000-0000-0000-0000-00000000000a', 'Pudim', 20, true, true, true);
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
create or replace function t_lancar(p_quem uuid, p_produto text) returns jsonb language sql as $$
  select t_como(p_quem, format('select public.lancar_pedido(%L, %L::jsonb)', '57300000-0000-0000-0000-00000000000a',
    json_build_object('origem', 'mesa', 'nome', 'Mesa 5', 'entrega', 'mesa', 'mesa', '5', 'pagamento', 'na_mesa',
      'itens', json_build_array(json_build_object('produto', p_produto, 'quantidade', 1)))::text))
$$;
create or replace function t_conta(p_quem uuid) returns jsonb language sql as $$
  select t_como(p_quem, $q$select public.conta_da_mesa('57300000-0000-0000-0000-00000000000a', '5')$q$)
$$;

\echo ''
\echo '1. O Wilson lança o prato'
select t_lancar('b7300000-0000-0000-0000-00000000000b', '57310000-0000-0000-0000-0000000000b1') as l1 \gset
select t_texto('o pedido já vai para a cozinha (em preparo)', :'l1'::jsonb->>'status', 'em_preparo');
select t_texto('a conta da mesa 5 abriu, com a picanha em nome do Wilson',
  (select x->>'nome' || ' · ' || (x->>'garcom') from jsonb_array_elements(t_conta('a7300000-0000-0000-0000-00000000000a')->'itens') x),
  'Picanha · Wilson');

\echo ''
\echo '2. O freelancer lança o vinho; o cliente pede pelo QR'
select t_lancar('c7300000-0000-0000-0000-00000000000c', '57310000-0000-0000-0000-0000000000b2');
select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'bar-toninho',
  '{"nome":"Cliente","entrega":"mesa","mesa":"5","pagamento":"na_mesa","itens":[{"produto":"57310000-0000-0000-0000-0000000000b3","quantidade":1}]}')) as q1 \gset
select t_texto('uma conta só, cada item com quem lançou',
  (select string_agg(x->>'nome' || ':' || (x->>'garcom'), ' | ' order by x->>'em')
     from jsonb_array_elements(t_conta('b7300000-0000-0000-0000-00000000000b')->'itens') x),
  'Picanha:Wilson | Vinho tinto:Beto | Pudim:Cliente (QR)');
select t_igual('as três vieram para a mesma conta',
  (select count(distinct conta_id) from public.pedidos where salao_id = '57300000-0000-0000-0000-00000000000a'), 1);

\echo ''
\echo '3. O mapa, e o servido que ainda não é venda'
select t_texto('o mapa: mesa 5 aberta, R$ 160, 3 itens, 1 esperando aceitar',
  (select x->>'mesa' || ' ' || (x->>'total') || ' ' || (x->>'itens') || ' ' || (x->>'esperando')
     from jsonb_array_elements(t_como('b7300000-0000-0000-0000-00000000000b',
       $q$select public.mesas_abertas('57300000-0000-0000-0000-00000000000a')$q$)) x),
  '5 160.00 3 1');
update public.pedidos set status = 'entregue', entregue_em = now()
 where salao_id = '57300000-0000-0000-0000-00000000000a' and numero = (:'l1'::jsonb->>'numero')::bigint;
select t_verdade('a picanha servida, com a conta aberta, ainda não é venda',
  (select comanda_id is null from public.pedidos where salao_id = '57300000-0000-0000-0000-00000000000a'
      and numero = (:'l1'::jsonb->>'numero')::bigint));

\echo ''
\echo '4. Fechar a conta'
select t_texto('com o pudim esperando "Aceitar", não fecha',
  erro_de($$select t_como('b7300000-0000-0000-0000-00000000000b',
    $q$select public.fechar_conta_mesa('57300000-0000-0000-0000-00000000000a', '5', 'credito', 10, 2)$q$)$$),
  'Há pedido desta mesa esperando "Aceitar". Aceite ou cancele antes de fechar.');
select t_como('b7300000-0000-0000-0000-00000000000b', format('select public.mudar_status_pedido(%L::uuid, %L)',
  (select id from public.pedidos where salao_id = '57300000-0000-0000-0000-00000000000a'
      and numero = (:'q1'::jsonb->>'numero')::bigint), 'em_preparo'));
select t_como('b7300000-0000-0000-0000-00000000000b',
  $q$select public.fechar_conta_mesa('57300000-0000-0000-0000-00000000000a', '5', 'credito', 10, 2)$q$) as f1 \gset
select t_texto('160 + 10% (16) = 176; por pessoa (2) 88',
  (:'f1'::jsonb->>'subtotal') || ' + ' || (:'f1'::jsonb->>'servico') || ' = ' || (:'f1'::jsonb->>'total')
    || ' / ' || (:'f1'::jsonb->>'porPessoa'), '160.00 + 16.00 = 176.00 / 88.00');
select t_igual('as 3 vendas da mesa entraram no caixa, no crédito',
  (select count(*) from public.pedidos p join public.pagamentos pg on pg.comanda_id = p.comanda_id
    where p.salao_id = '57300000-0000-0000-0000-00000000000a' and pg.forma = 'credito'), 3);
select t_texto('e o serviço entrou à parte, R$ 16 no crédito',
  (select pg.valor || ' ' || pg.forma from public.comanda_itens i join public.pagamentos pg on pg.comanda_id = i.comanda_id
    where i.descricao like 'Taxa de serviço%Mesa 5'), '16.00 credito');
select t_texto('a mesa 5 está livre de novo',
  t_conta('a7300000-0000-0000-0000-00000000000a')->>'aberta', 'false');
select t_lancar('b7300000-0000-0000-0000-00000000000b', '57310000-0000-0000-0000-0000000000b3');
select t_igual('o próximo cliente da mesa 5 abre outra conta',
  (select count(*) from public.mesa_contas where salao_id = '57300000-0000-0000-0000-00000000000a'), 2);

\echo ''
\echo '5. Quem é de fora'
select t_texto('não vê a conta',
  erro_de($$select t_conta('e7300000-0000-0000-0000-00000000000e')$$), 'Sem permissão neste estabelecimento.');
select t_texto('nem fecha',
  erro_de($$select t_como('e7300000-0000-0000-0000-00000000000e',
    $q$select public.fechar_conta_mesa('57300000-0000-0000-0000-00000000000a', '5', 'pix', 0, null)$q$)$$),
  'Sem permissão neste estabelecimento.');
select t_verdade('a tabela das contas não abre para a tela',
  not has_table_privilege('authenticated', 'public.mesa_contas', 'select'));

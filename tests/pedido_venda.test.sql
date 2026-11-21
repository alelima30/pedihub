-- ===========================================================================
-- PediHub — o pedido entregue vira venda (65_pedido_vira_venda)
--
-- A Pizzaria do Léo recebe três pedidos pelo link:
--
--   1. Pix, com entrega: a Ju (atendente) leva até "entregue" e a venda
--      nasce sozinha — comanda fechada, itens com o preço DO PEDIDO, a taxa
--      como acréscimo, o Pix no valor exato, o estoque baixando;
--   2. cartão, para retirar, de alguém sem ficha: a ficha nasce e o cartão
--      entra como crédito;
--   3. cancelado: não vira venda nenhuma;
--   e não se vende duas vezes o mesmo pedido.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a6500000-0000-0000-0000-00000000000a'),  -- Léo — dono
  ('d6500000-0000-0000-0000-00000000000d');  -- Ju  — atendente
insert into public.perfis (id, nome, telefone) values
  ('a6500000-0000-0000-0000-00000000000a', 'Léo', '+5511965000001'),
  ('d6500000-0000-0000-0000-00000000000d', 'Ju',  '+5511965000004')
on conflict (id) do update set nome = excluded.nome, telefone = excluded.telefone;
insert into public.saloes (id, slug, nome, status, fuso) values
  ('56500000-0000-0000-0000-00000000000a', 'pizzaria-leo', 'Pizzaria do Léo', 'ativo', 'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('56500000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20);
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a6500000-0000-0000-0000-00000000000a', '56500000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('d6500000-0000-0000-0000-00000000000d', '56500000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, estoque, ativo, venda_online) values
  ('56510000-0000-0000-0000-0000000000b1', '56500000-0000-0000-0000-00000000000a', 'Pizza calabresa', 50, 10, true, true),
  ('56510000-0000-0000-0000-0000000000b2', '56500000-0000-0000-0000-00000000000a', 'Refrigerante 2L', 12, 20, true, true);
insert into public.clientes (id, salao_id, nome, telefone) values
  ('56520000-0000-0000-0000-0000000000c1', '56500000-0000-0000-0000-00000000000a', 'Maria', '5511965000010');

-- Pedido 1: duas pizzas a R$ 48 (o cardápio de hoje diz 50: vale o do pedido),
-- um refri, R$ 6 de entrega, Pix.
insert into public.pedidos (id, salao_id, numero, cliente_id, nome, telefone, tipo_entrega,
                            bairro, subtotal, taxa_entrega, total, pagamento) values
  ('56530000-0000-0000-0000-0000000000e1', '56500000-0000-0000-0000-00000000000a', 1,
   '56520000-0000-0000-0000-0000000000c1', 'Maria', '5511965000010', 'entrega',
   'Centro', 108, 6, 114, 'pix'),
-- Pedido 2: retirada, cartão, de quem ainda não tem ficha.
  ('56530000-0000-0000-0000-0000000000e2', '56500000-0000-0000-0000-00000000000a', 2,
   null, 'José Novo', '5511965000020', 'retirada', null, 12, 0, 12, 'cartao'),
-- Pedido 3: vai ser cancelado.
  ('56530000-0000-0000-0000-0000000000e3', '56500000-0000-0000-0000-00000000000a', 3,
   '56520000-0000-0000-0000-0000000000c1', 'Maria', '5511965000010', 'retirada', null, 50, 0, 50, 'dinheiro');
insert into public.pedido_itens (pedido_id, produto_id, nome, preco, quantidade, ordem) values
  ('56530000-0000-0000-0000-0000000000e1', '56510000-0000-0000-0000-0000000000b1', 'Pizza calabresa', 48, 2, 1),
  ('56530000-0000-0000-0000-0000000000e1', '56510000-0000-0000-0000-0000000000b2', 'Refrigerante 2L', 12, 1, 2),
  ('56530000-0000-0000-0000-0000000000e2', '56510000-0000-0000-0000-0000000000b2', 'Refrigerante 2L', 12, 1, 1),
  ('56530000-0000-0000-0000-0000000000e3', '56510000-0000-0000-0000-0000000000b1', 'Pizza calabresa', 50, 1, 1);
grant usage on schema auth to anon, authenticated;

create or replace function t_como(p_quem uuid, p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_quem::text, ''), true);
  set local role authenticated;
  execute p_sql into r;
  reset role;
  return r;
end $$;
create or replace function t_status(p_pedido text, p_status text) returns jsonb language sql as $$
  select t_como('d6500000-0000-0000-0000-00000000000d',
    format('select public.mudar_status_pedido(%L::uuid, %L)', p_pedido, p_status))
$$;

\echo ''
\echo '1. Pix com entrega: a atendente entrega e a venda nasce'
select t_status('56530000-0000-0000-0000-0000000000e1', 'em_preparo');
select t_status('56530000-0000-0000-0000-0000000000e1', 'saiu');
select t_verdade('antes de entregar, não é venda',
  (select comanda_id is null from public.pedidos where id = '56530000-0000-0000-0000-0000000000e1'));
select t_status('56530000-0000-0000-0000-0000000000e1', 'entregue');
select t_verdade('entregue: o pedido aponta para uma comanda',
  (select comanda_id is not null and venda_erro is null
     from public.pedidos where id = '56530000-0000-0000-0000-0000000000e1'));
select t_texto('a comanda está fechada',
  (select c.status from public.comandas c join public.pedidos p on p.comanda_id = c.id
    where p.id = '56530000-0000-0000-0000-0000000000e1'), 'fechada');
select t_texto('o total da comanda é o total do pedido (108 + 6 de entrega)',
  (select t.total::text from public.comandas_totais t join public.pedidos p on p.comanda_id = t.id
    where p.id = '56530000-0000-0000-0000-0000000000e1'), '114.00');
select t_texto('a taxa de entrega é o acréscimo',
  (select c.acrescimo::text from public.comandas c join public.pedidos p on p.comanda_id = c.id
    where p.id = '56530000-0000-0000-0000-0000000000e1'), '6.00');
select t_texto('a pizza entra com o preço DO PEDIDO (48), e não o do cardápio (50)',
  (select i.preco_unit::text from public.comanda_itens i join public.pedidos p on p.comanda_id = i.comanda_id
    where p.id = '56530000-0000-0000-0000-0000000000e1' and i.descricao = 'Pizza calabresa'), '48.00');
select t_texto('o pagamento é Pix, no valor exato',
  (select pg.forma || ' ' || pg.valor from public.pagamentos pg join public.pedidos p on p.comanda_id = pg.comanda_id
    where p.id = '56530000-0000-0000-0000-0000000000e1'), 'pix 114.00');
select t_igual('o estoque da pizza baixou 2 (10 → 8)',
  (select estoque from public.produtos where id = '56510000-0000-0000-0000-0000000000b1')::bigint, 8);

\echo ''
\echo '2. Cartão, para retirar, de quem não tinha ficha'
select t_status('56530000-0000-0000-0000-0000000000e2', 'em_preparo');
select t_status('56530000-0000-0000-0000-0000000000e2', 'pronto');
select t_status('56530000-0000-0000-0000-0000000000e2', 'entregue');
select t_verdade('a ficha do José nasceu e ficou no pedido',
  (select cliente_id is not null and comanda_id is not null
     from public.pedidos where id = '56530000-0000-0000-0000-0000000000e2'));
select t_texto('o cartão da entrega entra como crédito',
  (select pg.forma from public.pagamentos pg join public.pedidos p on p.comanda_id = pg.comanda_id
    where p.id = '56530000-0000-0000-0000-0000000000e2'), 'credito');

\echo ''
\echo '3. Cancelado não é venda; e não se vende duas vezes'
select t_status('56530000-0000-0000-0000-0000000000e3', 'cancelado');
select t_verdade('o cancelado não tem comanda',
  (select comanda_id is null from public.pedidos where id = '56530000-0000-0000-0000-0000000000e3'));
select public.pedido_vira_venda('56530000-0000-0000-0000-0000000000e1');
select t_igual('chamar de novo não cria outra comanda',
  (select count(*) from public.comandas where salao_id = '56500000-0000-0000-0000-00000000000a'), 2);
select t_igual('o faturamento do dia soma os dois pedidos (114 + 12)',
  (select round(sum(t.total))::bigint from public.comandas_totais t
    where t.salao_id = '56500000-0000-0000-0000-00000000000a' and t.status = 'fechada'), 126);
select t_verdade('a tela não chama a função por fora',
  not has_function_privilege('authenticated', 'public.pedido_vira_venda(uuid)', 'execute'));

-- ===========================================================================
-- PediHub — o pedido lançado pela equipe (70_pedido_balcao)
--
-- A Lanchonete do Bia está FECHADA no link (pausada) e com pedido mínimo
-- de R$ 50. Mesmo assim:
--
--   1. o link continua recusando (fechado, mínimo) — a porta pública não muda;
--   2. a atendente lança um pedido de TELEFONE com entrega num bairro fora da
--      lista, taxa combinada (R$ 7), complemento e troco: entra "em preparo";
--   3. um pedido de BALCÃO sem telefone, com item que não aparece no link;
--   4. quem não é da equipe não lança; origem inventada é recusada;
--   5. entregue, o de balcão vira venda como qualquer outro.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a7000000-0000-0000-0000-00000000000a'),  -- Bia  — dona
  ('d7000000-0000-0000-0000-00000000000d'),  -- Rui  — atendente
  ('c7000000-0000-0000-0000-00000000000c');  -- de fora
insert into public.perfis (id, nome, telefone) values
  ('a7000000-0000-0000-0000-00000000000a', 'Bia', '+5511970000001'),
  ('d7000000-0000-0000-0000-00000000000d', 'Rui', '+5511970000004'),
  ('c7000000-0000-0000-0000-00000000000c', 'Fulano', '+5511970000009')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57000000-0000-0000-0000-00000000000a', 'lanche-bia', 'Lanchonete da Bia', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"aceitando":false,"minimo":50,"taxas":[{"bairro":"Centro","taxa":5}],"pagamentos":["pix"]}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57000000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7000000-0000-0000-0000-00000000000a', '57000000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('d7000000-0000-0000-0000-00000000000d', '57000000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('57010000-0000-0000-0000-0000000000b1', '57000000-0000-0000-0000-00000000000a', 'X-Burger', 20, true, true, true),
  ('57010000-0000-0000-0000-0000000000b2', '57000000-0000-0000-0000-00000000000a', 'Café', 5, true, false, true);
insert into public.produto_grupos (id, salao_id, produto_id, nome, min, max, regra) values
  ('57020000-0000-0000-0000-0000000000a1', '57000000-0000-0000-0000-00000000000a',
   '57010000-0000-0000-0000-0000000000b1', 'Adicionais', 0, 3, 'soma');
insert into public.produto_opcoes (id, grupo_id, salao_id, nome, preco) values
  ('57030000-0000-0000-0000-0000000000c1', '57020000-0000-0000-0000-0000000000a1',
   '57000000-0000-0000-0000-00000000000a', 'Bacon', 4);
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
create or replace function t_lancar(p_quem uuid, p_pedido text) returns jsonb language sql as $$
  select t_como(p_quem, format('select public.lancar_pedido(%L, %L::jsonb)',
    '57000000-0000-0000-0000-00000000000a', p_pedido))
$$;

\echo ''
\echo '1. A porta do link não muda'
select t_texto('pausado, o link recusa',
  erro_de($$select t_como(null, $q$select public.fazer_pedido('lanche-bia',
    '{"nome":"Ana","telefone":"11970000020","entrega":"retirada","pagamento":"pix",
      "itens":[{"produto":"57010000-0000-0000-0000-0000000000b1","quantidade":1}]}'::jsonb)$q$)$$),
  'O Lanchonete da Bia não está recebendo pedidos agora.');

\echo ''
\echo '2. Pedido de telefone, lançado pela atendente'
select t_lancar('d7000000-0000-0000-0000-00000000000d', '{"origem":"telefone","nome":"Carlos",
  "telefone":"(11) 97000-0030","entrega":"entrega","pagamento":"dinheiro","troco":"100","taxa":"7",
  "endereco":{"rua":"Rua B","numero":"20","bairro":"Jardim Longe"},
  "itens":[{"produto":"57010000-0000-0000-0000-0000000000b1","quantidade":2,
            "opcoes":["57030000-0000-0000-0000-0000000000c1"]}]}') as r1 \gset
select t_texto('2 X-Burger com bacon (24) = 48; mínimo de 50 não vale no balcão; total 48 + 7 = 55',
  (:'r1'::jsonb->>'subtotal') || ' + ' || (:'r1'::jsonb->>'taxa') || ' = ' || (:'r1'::jsonb->>'total'),
  '48.00 + 7.00 = 55.00');
select t_texto('o pedido já nasce em preparo, com origem telefone e bairro fora da lista',
  (select status || ' ' || origem || ' ' || bairro || ' ' || (aceito_em is not null)
     from public.pedidos where salao_id = '57000000-0000-0000-0000-00000000000a' and numero = (:'r1'::jsonb->>'numero')::bigint),
  'em_preparo telefone Jardim Longe true');
select t_texto('dinheiro vale mesmo a casa só aceitando Pix no link',
  (select pagamento || ' troco ' || troco_para from public.pedidos
    where salao_id = '57000000-0000-0000-0000-00000000000a' and numero = (:'r1'::jsonb->>'numero')::bigint),
  'dinheiro troco 100.00');

\echo ''
\echo '3. Pedido de balcão, sem telefone, com item que não está no link'
select t_lancar('d7000000-0000-0000-0000-00000000000d', '{"nome":"Mesa do canto","entrega":"retirada",
  "pagamento":"cartao","itens":[{"produto":"57010000-0000-0000-0000-0000000000b2","quantidade":2}]}') as r2 \gset
select t_texto('o café (fora do link) entra: 2 × 5 = 10, origem balcão, sem telefone nem ficha',
  (select total || ' ' || origem || ' [' || telefone || '] ' || (cliente_id is null)
     from public.pedidos where salao_id = '57000000-0000-0000-0000-00000000000a' and numero = (:'r2'::jsonb->>'numero')::bigint),
  '10.00 balcao [] true');

\echo ''
\echo '4. Quem lança'
select t_texto('quem é de fora não lança',
  erro_de($$select t_lancar('c7000000-0000-0000-0000-00000000000c', '{"nome":"X","entrega":"retirada","pagamento":"pix","itens":[{"produto":"57010000-0000-0000-0000-0000000000b2","quantidade":1}]}')$$),
  'Sem permissão neste estabelecimento.');
select t_texto('origem inventada é recusada',
  erro_de($$select t_lancar('a7000000-0000-0000-0000-00000000000a', '{"origem":"link","nome":"X","entrega":"retirada","pagamento":"pix","itens":[{"produto":"57010000-0000-0000-0000-0000000000b2","quantidade":1}]}')$$),
  'Origem de pedido desconhecida.');
select t_texto('telefone digitado errado ainda é recusado',
  erro_de($$select t_lancar('a7000000-0000-0000-0000-00000000000a', '{"nome":"X","telefone":"123","entrega":"retirada","pagamento":"pix","itens":[{"produto":"57010000-0000-0000-0000-0000000000b2","quantidade":1}]}')$$),
  'Confira o WhatsApp: precisa do DDD.');
select t_verdade('o anon nem chama a porta da equipe',
  not has_function_privilege('anon', 'public.lancar_pedido(uuid,jsonb)', 'execute'));

\echo ''
\echo '5. O de balcão vira venda'
select t_como('d7000000-0000-0000-0000-00000000000d', format(
  'select public.mudar_status_pedido(%L::uuid, %L)',
  (select id from public.pedidos where salao_id = '57000000-0000-0000-0000-00000000000a' and numero = (:'r2'::jsonb->>'numero')::bigint),
  'entregue'));
select t_texto('entregue: comanda fechada de 10, no cartão (crédito)',
  (select t.total || ' ' || pg.forma from public.pedidos p
     join public.comandas_totais t on t.id = p.comanda_id
     join public.pagamentos pg on pg.comanda_id = p.comanda_id
    where p.salao_id = '57000000-0000-0000-0000-00000000000a' and p.numero = (:'r2'::jsonb->>'numero')::bigint),
  '10.00 credito');

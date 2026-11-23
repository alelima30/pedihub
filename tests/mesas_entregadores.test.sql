-- ===========================================================================
-- PediHub — mesas, entregadores e fidelidade (71)
--
-- A Pizzaria do Nico tem 10 mesas, os entregadores Lu e Beto, e fidelidade:
-- a cada 3 pedidos entregues, 10% no próximo.
--
--   1. MESA pelo QR: sem endereço, sem taxa, sem telefone, "paga na mesa";
--      mesa 11 (não existe) e mesa sem número são recusadas; "na mesa" fora
--      da mesa também; ao entregar, a equipe diz como pagou e a venda bate;
--   2. ENTREGADOR: quem levou fica no pedido; o acerto soma entregas e
--      taxas por pessoa; o link público não vê os nomes;
--   3. FIDELIDADE: 3 entregues → o 4º sai com 10% sozinho; com cupom, não
--      soma; o acompanhamento diz quanto falta.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a7100000-0000-0000-0000-00000000000a');
insert into public.perfis (id, nome, telefone) values ('a7100000-0000-0000-0000-00000000000a', 'Nico', '+5511971000001')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57100000-0000-0000-0000-00000000000a', 'pizza-nico', 'Pizzaria do Nico', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"mesas":10,"taxaPadrao":6,"entregadores":["Lu","Beto"],
                "fidelidade":{"ligado":true,"pedidos":3,"desconto":10}}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57100000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7100000-0000-0000-0000-00000000000a', '57100000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('57110000-0000-0000-0000-0000000000b1', '57100000-0000-0000-0000-00000000000a', 'Pizza', 50, true, true, true);
insert into public.cupons (salao_id, codigo, tipo, valor, um_por_cliente) values
  ('57100000-0000-0000-0000-00000000000a', 'CINCO', 'valor', 5, false);
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
create or replace function t_link(p_extra text) returns jsonb language sql as $$
  select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'pizza-nico',
    (('{"nome":"Cliente","itens":[{"produto":"57110000-0000-0000-0000-0000000000b1","quantidade":1}]}')::jsonb
      || p_extra::jsonb)::text))
$$;
create or replace function t_dono(p_sql text) returns jsonb language sql as $$
  select t_como('a7100000-0000-0000-0000-00000000000a', p_sql)
$$;
create or replace function t_id(p_numero jsonb) returns uuid language sql as $$
  select id from public.pedidos where salao_id = '57100000-0000-0000-0000-00000000000a'
     and numero = (p_numero->>'numero')::bigint
$$;

\echo ''
\echo '1. Mesa pelo QR'
select t_link('{"entrega":"mesa","mesa":"5","pagamento":"na_mesa"}') as m1 \gset
select t_texto('mesa 5: sem taxa e sem telefone, total 50',
  (:'m1'::jsonb->>'taxa') || ' / ' || (:'m1'::jsonb->>'total'), '0.00 / 50.00');
select t_texto('o pedido guarda a mesa e o "paga na mesa"',
  (select tipo_entrega || ' ' || mesa || ' ' || pagamento || ' [' || telefone || ']' from public.pedidos where id = t_id(:'m1'::jsonb)),
  'mesa 5 na_mesa []');
select t_texto('mesa 11 não existe',
  erro_de($$select t_link('{"entrega":"mesa","mesa":"11","pagamento":"na_mesa"}')$$),
  'Esta mesa não recebe pedido pelo link. Chame o garçom.');
select t_texto('mesa sem número',
  erro_de($$select t_link('{"entrega":"mesa","pagamento":"na_mesa"}')$$),
  'Diga o número da mesa.');
select t_texto('"paga na mesa" fora da mesa é recusado',
  erro_de($$select t_link('{"entrega":"retirada","telefone":"11971000099","pagamento":"na_mesa"}')$$),
  'Escolha como vai pagar.');
select t_dono(format('select public.mudar_status_pedido(%L::uuid, %L)', t_id(:'m1'::jsonb), 'em_preparo'));
select t_dono(format('select public.mudar_status_pedido(%L::uuid, %L)', t_id(:'m1'::jsonb), 'entregue'));
-- 73: pedido de mesa é da CONTA da mesa; vira venda quando a conta fecha.
select t_dono($q$select public.fechar_conta_mesa('57100000-0000-0000-0000-00000000000a', '5', 'pix', 0, null)$q$);
select t_texto('conta fechada: a venda da mesa entra no Pix, 50',
  (select pg.forma || ' ' || pg.valor from public.pedidos p join public.pagamentos pg on pg.comanda_id = p.comanda_id
    where p.id = t_id(:'m1'::jsonb)), 'pix 50.00');

\echo ''
\echo '2. Entregadores'
select t_link('{"entrega":"entrega","telefone":"11971000020","pagamento":"pix","endereco":{"rua":"R","numero":"1","bairro":"Centro"}}') as e1 \gset
select t_link('{"entrega":"entrega","telefone":"11971000021","pagamento":"pix","endereco":{"rua":"R","numero":"2","bairro":"Centro"}}') as e2 \gset
select t_dono(format('select public.definir_entregador(%L::uuid, %L)', t_id(:'e1'::jsonb), 'Lu'));
select t_dono(format('select public.definir_entregador(%L::uuid, %L)', t_id(:'e2'::jsonb), 'Lu'));
update public.pedidos set status = 'entregue', entregue_em = now()
 where id in (t_id(:'e1'::jsonb), t_id(:'e2'::jsonb));
select t_texto('o acerto: Lu fez 2 entregas, R$ 12 de taxa',
  (select x->>'entregador' || ' ' || (x->>'entregas') || ' ' || (x->>'taxas')
     -- O dia DO RESTAURANTE (entre 21h e meia-noite o current_date em UTC já é amanhã).
     from jsonb_array_elements(t_dono(format('select public.acerto_entregadores(%L::uuid, %L::date, %L::date)',
       '57100000-0000-0000-0000-00000000000a', (now() at time zone 'America/Sao_Paulo')::date,
       (now() at time zone 'America/Sao_Paulo')::date))) x where x->>'entregador' = 'Lu'),
  'Lu 2 12.00');
select t_texto('pedido de mesa não tem entregador',
  erro_de(format($q$select t_dono('select public.definir_entregador(''%s''::uuid, ''Beto'')')$q$, t_id(:'m1'::jsonb))),
  'Só pedido de entrega tem entregador.');
select t_falso('o link público não vê os nomes dos entregadores',
  t_como(null, $$select public.pedidos_da_casa('pizza-nico')$$) ? 'entregadores');
select t_igual('mas vê as 10 mesas e a fidelidade ligada',
  ((t_como(null, $$select public.pedidos_da_casa('pizza-nico')$$)->>'mesas')::int
   + case when (t_como(null, $$select public.pedidos_da_casa('pizza-nico')$$)->'fidelidade'->>'ligado')::boolean then 100 else 0 end)::bigint,
  110);

\echo ''
\echo '3. Fidelidade'
-- O 11971000030 já tem 3 pedidos entregues.
insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status)
select '57100000-0000-0000-0000-00000000000a', 900 + g, 'Fiel', '11971000030', 'retirada', 50, 0, 50, 'pix', 'entregue'
  from generate_series(1, 3) g;
select t_link('{"entrega":"retirada","telefone":"11971000030","pagamento":"pix","cupom":"CINCO"}') as f0 \gset
select t_texto('com cupom digitado, vale o cupom (não soma)', :'f0'::jsonb->>'desconto', '5.00');
update public.pedidos set status = 'cancelado' where id = t_id(:'f0'::jsonb);
select t_link('{"entrega":"retirada","telefone":"11971000030","pagamento":"pix"}') as f1 \gset
select t_texto('o 4º pedido sai com 10% sozinho: 50 − 5 = 45',
  (:'f1'::jsonb->>'desconto') || ' / ' || (:'f1'::jsonb->>'total') || ' / ' || (:'f1'::jsonb->>'fidelidade'),
  '5.00 / 45.00 / true');
select t_texto('marcado como FIDELIDADE no pedido',
  (select cupom_codigo from public.pedidos where id = t_id(:'f1'::jsonb)), 'FIDELIDADE');
select t_link('{"entrega":"retirada","telefone":"11971000030","pagamento":"pix"}') as f2 \gset
select t_texto('o seguinte não ganha de novo (o prêmio foi usado)', :'f2'::jsonb->>'desconto', '0.00');
select t_texto('o acompanhamento diz quanto falta (3 entregues: faltam 3 para o próximo)',
  (t_como(null, format('select public.meu_pedido(%L::uuid)',
     (select token from public.pedidos where id = t_id(:'f2'::jsonb))))->'fidelidade'->>'faltam'), '3');

\echo ''
\echo '4. Débito ou crédito (72)'
select t_link('{"entrega":"retirada","telefone":"11971000040","pagamento":"debito"}') as d1 \gset
select t_dono(format('select public.mudar_status_pedido(%L::uuid, %L)', t_id(:'d1'::jsonb), 'em_preparo'));
select t_dono(format('select public.mudar_status_pedido(%L::uuid, %L)', t_id(:'d1'::jsonb), 'entregue'));
select t_texto('o débito entra no caixa como débito',
  (select pg.forma from public.pedidos p join public.pagamentos pg on pg.comanda_id = p.comanda_id
    where p.id = t_id(:'d1'::jsonb)), 'debito');
select t_texto('crédito também vale (a lista padrão tem os dois)',
  erro_de($$select (select t_dono($q$select to_jsonb(1)$q$)) || t_link('{"entrega":"retirada","telefone":"11971000041","pagamento":"credito"}')$$), null);

-- ===========================================================================
-- PediHub — o cartão fidelidade reconhece a cliente pelo celular (78)
--
-- O Lanche da Bia dá 10% a cada 3 pedidos entregues. A Carla pediu duas
-- vezes ANTES do 78, com o celular preenchido sozinho no formato
-- internacional (+55), e uma vez depois, digitando "(11) 97200-0040".
--
--   1. os pedidos antigos, gravados com o 55, são acertados pelo 78;
--   2. o celular digitado de três jeitos é UMA pessoa: o 4º pedido sai
--      com o desconto, e o acompanhamento conta certo;
--   3. a trava de "3 pedidos esperando" também enxerga os três jeitos.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a7800000-0000-0000-0000-00000000000a');
insert into public.perfis (id, nome, telefone) values ('a7800000-0000-0000-0000-00000000000a', 'Bia', '+5511978000001')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57800000-0000-0000-0000-00000000000a', 'lanche-bia', 'Lanche da Bia', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"fidelidade":{"ligado":true,"pedidos":3,"desconto":10}}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57800000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7800000-0000-0000-0000-00000000000a', '57800000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('57810000-0000-0000-0000-0000000000b1', '57800000-0000-0000-0000-00000000000a', 'X-Salada', 30, true, true, true);
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
create or replace function t_pedir(p_tel text) returns jsonb language sql as $$
  select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'lanche-bia',
    jsonb_build_object('nome', 'Carla', 'telefone', p_tel, 'entrega', 'retirada', 'pagamento', 'pix',
      'itens', jsonb_build_array(jsonb_build_object('produto', '57810000-0000-0000-0000-0000000000b1', 'quantidade', 1)))::text))
$$;
create or replace function t_id(p jsonb) returns uuid language sql as $$
  select id from public.pedidos where salao_id = '57800000-0000-0000-0000-00000000000a'
     and numero = (p->>'numero')::bigint
$$;

\echo ''
\echo '1. Os pedidos de antes do 78, com o 55 na frente'
insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status)
select '57800000-0000-0000-0000-00000000000a', 800 + g, 'Carla', '5511972000040', 'retirada', 30, 0, 30, 'pix', 'entregue'
  from generate_series(1, 2) g;
-- Um número com DDD 55 (Santa Maria, RS) e 11 dígitos não é "+55": fica como está.
insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status)
values ('57800000-0000-0000-0000-00000000000a', 810, 'Rui', '55999990000', 'retirada', 30, 0, 30, 'pix', 'entregue');
\ir ../supabase/78_fidelidade_pelo_celular.sql
select t_igual('o 78 acerta os dois pedidos antigos para o formato nacional',
  (select count(*) from public.pedidos where salao_id = '57800000-0000-0000-0000-00000000000a'
      and nome = 'Carla' and telefone = '11972000040'), 2);
select t_texto('e não mexe no celular de DDD 55 sem o +55',
  (select telefone from public.pedidos where salao_id = '57800000-0000-0000-0000-00000000000a' and numero = 810),
  '55999990000');

\echo ''
\echo '2. Três jeitos de digitar, uma cliente só'
select t_pedir('(11) 97200-0040') as p3 \gset
select t_texto('digitado com DDD e traço, grava no formato nacional',
  (select telefone from public.pedidos where id = t_id(:'p3'::jsonb)), '11972000040');
select t_texto('o 3º pedido ainda não tem desconto (2 entregues)', :'p3'::jsonb->>'desconto', '0.00');
update public.pedidos set status = 'entregue', entregue_em = now() where id = t_id(:'p3'::jsonb);

select t_pedir('+55 11 97200-0040') as p4 \gset
select t_texto('o 4º, com o +55 do preenchimento automático, sai com 10%: 30 − 3 = 27',
  (:'p4'::jsonb->>'desconto') || ' / ' || (:'p4'::jsonb->>'total') || ' / ' || (:'p4'::jsonb->>'fidelidade'),
  '3.00 / 27.00 / true');
select t_texto('e grava o mesmo celular, sem o 55',
  (select telefone from public.pedidos where id = t_id(:'p4'::jsonb)), '11972000040');
select t_texto('o acompanhamento conta os 3 entregues dela (faltam 3 para o próximo)',
  (t_como(null, format('select public.meu_pedido(%L::uuid)',
     (select token from public.pedidos where id = t_id(:'p4'::jsonb))))->'fidelidade'->>'faltam'), '3');

\echo ''
\echo '3. A trava de pedidos esperando enxerga os três jeitos'
-- O 4º pedido acima ainda espera. Mais dois, cada um digitado de um jeito:
select t_texto('o 2º esperando, com 55 colado, entra', (t_pedir('5511972000040'))->>'status', 'recebido');
select t_texto('o 3º esperando, com espaço, entra', (t_pedir('11 972000040'))->>'status', 'recebido');
select t_texto('o 4º esperando é recusado, mesmo digitado de outro jeito',
  erro_de($$select t_pedir('+55 (11) 97200-0040')$$),
  'Você já tem pedidos esperando a confirmação. Aguarde ou cancele um antes de fazer outro.');

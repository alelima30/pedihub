-- ===========================================================================
-- PediHub — o link do pedido (86)
--
--   1. a equipe do estabelecimento recebe o código do pedido;
--   2. quem é de fora (logado em outra casa, ou sem login) não recebe;
--   3. com o código, o meu_pedido() abre o pedido sem conta nenhuma.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a8600000-0000-0000-0000-00000000000a'),  -- Lia  — dona
  ('c8600000-0000-0000-0000-00000000000c');  -- de fora
insert into public.perfis (id, nome, telefone) values
  ('a8600000-0000-0000-0000-00000000000a', 'Lia', '+5511970008601'),
  ('c8600000-0000-0000-0000-00000000000c', 'Fulano', '+5511970008609')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, tipo, cfg) values
  ('58600000-0000-0000-0000-00000000000a', 'lanche-86', 'Lanchonete 86', 'ativo', 'America/Sao_Paulo',
   'restaurante', '{"pedidos":{"pagamentos":["dinheiro"]}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58600000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a8600000-0000-0000-0000-00000000000a', '58600000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('58610000-0000-0000-0000-0000000000b1', '58600000-0000-0000-0000-00000000000a', 'X-Burger', 20, true, true, true);
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

select t_como(null, $q$select public.fazer_pedido('lanche-86', '{"nome":"Ana","telefone":"11970008620",
  "entrega":"retirada","pagamento":"dinheiro","itens":[{"produto":"58610000-0000-0000-0000-0000000000b1","quantidade":1}]}'::jsonb)$q$) \gset
select id as pedido, token as certo from public.pedidos where salao_id = '58600000-0000-0000-0000-00000000000a' limit 1 \gset

create or replace function t_token(p_quem uuid, p_ped uuid) returns text language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_quem::text, ''), true);
  if p_quem is null then set local role anon; else set local role authenticated; end if;
  r := public.token_do_pedido(p_ped)::text;
  reset role;
  return r;
end $$;

\echo ''
\echo '1. A equipe recebe o código'
select t_texto('a dona recebe o código do pedido',
  t_token('a8600000-0000-0000-0000-00000000000a', :'pedido'), :'certo');

\echo ''
\echo '2. Quem é de fora, não'
select t_texto('logado sem ser da casa: recusado',
  erro_de(format('select t_token(%L, %L)', 'c8600000-0000-0000-0000-00000000000c', :'pedido')),
  'Sem permissão neste estabelecimento.');
select t_verdade('sem login: nem chega na função',
  erro_de(format('select t_token(null, %L)', :'pedido')) like '%permission denied%');

\echo ''
\echo '3. Com o código, o pedido abre sem conta'
select t_texto('o meu_pedido() acha o pedido (número e loja)',
  (t_como(null, format('select public.meu_pedido(%L)', :'certo'))->>'numero') || ' / '
  || (t_como(null, format('select public.meu_pedido(%L)', :'certo'))->>'slug'), '1 / lanche-86');

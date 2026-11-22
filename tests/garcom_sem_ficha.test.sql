-- ===========================================================================
-- PediHub — o garçom entra sem ficha; o aviso no celular é do pedido de fora (77)
--
--   1. a dona convida o Wilson como garçom, sem ficha nenhuma na Equipe; ele
--      aceita e vira da equipe (papel "profissional");
--   2. o aviso no celular: o pedido do QR da mesa 4 toca, dizendo "mesa 4";
--      o que o próprio garçom lança na mesa, e o de telefone, não tocam.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a7700000-0000-0000-0000-00000000000a'), ('b7700000-0000-0000-0000-00000000000b');
insert into public.perfis (id, nome, telefone) values
  ('a7700000-0000-0000-0000-00000000000a', 'Rosa', '+5511977000001'),
  ('b7700000-0000-0000-0000-00000000000b', 'Wilson Souza', '+5511977000002')
on conflict (id) do update set nome = excluded.nome;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57700000-0000-0000-0000-00000000000a', 'bar-rosa', 'Bar da Rosa', 'ativo', 'America/Sao_Paulo', '{"pedidos":{"mesas":10}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57700000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7700000-0000-0000-0000-00000000000a', '57700000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('57710000-0000-0000-0000-0000000000b1', '57700000-0000-0000-0000-00000000000a', 'Chopp', 12, true, true, true);
-- O celular da dona, com o aviso ligado.
insert into public.push_aparelhos (salao_id, perfil_id, endpoint, p256dh, auth) values
  ('57700000-0000-0000-0000-00000000000a', 'a7700000-0000-0000-0000-00000000000a',
   'https://push.exemplo/rosa', repeat('p', 64), repeat('a', 16));
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

\echo ''
\echo '1. O convite do garçom, sem ficha'
select t_como('a7700000-0000-0000-0000-00000000000a',
  $q$select public.criar_convite('57700000-0000-0000-0000-00000000000a', 'profissional', 'Wilson', null)$q$)->>'token' as tk \gset
select t_verdade('a dona gera o convite de garçom sem escolher ficha', :'tk' is not null);
select t_como('b7700000-0000-0000-0000-00000000000b', format('select public.aceitar_convite(%L::uuid)', :'tk'));
select t_texto('o Wilson aceitou: é da equipe, como garçom',
  (select papel || ' ' || status from public.vinculos
    where perfil_id = 'b7700000-0000-0000-0000-00000000000b' and salao_id = '57700000-0000-0000-0000-00000000000a'),
  'profissional ativo');
select t_igual('e nenhuma ficha de agenda foi criada ou tomada',
  (select count(*) from public.profissionais where perfil_id = 'b7700000-0000-0000-0000-00000000000b'), 0);
select t_texto('ele lança na mesa, e o item sai com o nome dele',
  (select t_como('b7700000-0000-0000-0000-00000000000b', format('select public.lancar_pedido(%L, %L::jsonb)',
     '57700000-0000-0000-0000-00000000000a',
     '{"origem":"mesa","nome":"Mesa 2","entrega":"mesa","mesa":"2","pagamento":"na_mesa","itens":[{"produto":"57710000-0000-0000-0000-0000000000b1","quantidade":1}]}'))->>'status'),
  'em_preparo');
select t_texto('   (Chopp:Wilson)',
  (select i.nome || ':' || i.garcom_nome from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
    where p.salao_id = '57700000-0000-0000-0000-00000000000a' and p.mesa = '2'), 'Chopp:Wilson');

\echo ''
\echo '2. O aviso no celular'
select t_igual('o que o garçom lançou na mesa não tocou o celular de ninguém',
  (select count(*) from public.push_fila where salao_id = '57700000-0000-0000-0000-00000000000a'), 0);
select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'bar-rosa',
  '{"nome":"Cliente","entrega":"mesa","mesa":"4","pagamento":"na_mesa","itens":[{"produto":"57710000-0000-0000-0000-0000000000b1","quantidade":2}]}'));
select t_texto('o pedido do QR da mesa 4 toca, dizendo a mesa',
  (select titulo || ' — ' || corpo from public.push_fila where salao_id = '57700000-0000-0000-0000-00000000000a'),
  'Pedido novo — Cliente · R$ 24,00 · mesa 4');
select t_como('a7700000-0000-0000-0000-00000000000a', format('select public.lancar_pedido(%L, %L::jsonb)',
  '57700000-0000-0000-0000-00000000000a',
  '{"origem":"telefone","nome":"Carlos","entrega":"retirada","pagamento":"pix","itens":[{"produto":"57710000-0000-0000-0000-0000000000b1","quantidade":1}]}'));
select t_igual('o de telefone, que a própria casa digitou, não toca',
  (select count(*) from public.push_fila where salao_id = '57700000-0000-0000-0000-00000000000a'), 1);

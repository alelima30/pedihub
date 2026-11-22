-- ===========================================================================
-- PediHub — entregadores: acerto do dinheiro, quanto ganha, link (75)
--
-- Na Pizzaria da Rosa: entrega a R$ 8, pizza a R$ 50. Entregadores Lu e Beto;
-- o motoboy ganha R$ 6 por entrega mais R$ 20 de diária.
--   1. o link da Lu: ela vê só as entregas dela, com endereço, telefone e o
--      troco; marca "Entregue" — e vira venda; pedido do Beto não é dela;
--   2. o acerto: dinheiro que cada um recebeu, quanto ganha, quanto devolve;
--      no modo "igual à taxa", ganha o que os clientes pagaram de entrega;
--   3. trocar o link corta o antigo; tirar o nome da lista também;
--   4. a página pública não vê quanto o motoboy ganha; garçom e anônimo
--      não pegam link nem acerto.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a7500000-0000-0000-0000-00000000000a'),  -- Rosa — dona
  ('b7500000-0000-0000-0000-00000000000b');  -- Wilson — garçom
insert into public.perfis (id, nome, telefone) values
  ('a7500000-0000-0000-0000-00000000000a', 'Rosa', '+5511975000001'),
  ('b7500000-0000-0000-0000-00000000000b', 'Wilson', '+5511975000002')
on conflict (id) do update set nome = excluded.nome;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57500000-0000-0000-0000-00000000000a', 'pizza-rosa', 'Pizzaria da Rosa', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"taxaPadrao":8,"entregadores":["Lu","Beto"],"motoboy":{"modo":"fixo","valor":6,"diaria":20}}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57500000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7500000-0000-0000-0000-00000000000a', '57500000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('b7500000-0000-0000-0000-00000000000b', '57500000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('57510000-0000-0000-0000-0000000000b1', '57500000-0000-0000-0000-00000000000a', 'Pizza', 50, true, true, true);
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
create or replace function t_dona(p_sql text) returns jsonb language sql as $$
  select t_como('a7500000-0000-0000-0000-00000000000a', p_sql)
$$;
-- Um pedido de entrega pelo link, já aceito, saído com `p_quem`.
create or replace function t_saiu(p_tel text, p_pag text, p_troco text, p_quem text) returns uuid language plpgsql as $$
declare r jsonb; v uuid;
begin
  r := t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'pizza-rosa', json_build_object(
         'nome', 'Cliente ' || p_tel, 'telefone', p_tel, 'entrega', 'entrega', 'pagamento', p_pag, 'troco', p_troco,
         'endereco', json_build_object('rua', 'Rua das Flores', 'numero', right(p_tel, 2), 'bairro', 'Centro',
                                       'referencia', 'portão azul'),
         'itens', json_build_array(json_build_object('produto', '57510000-0000-0000-0000-0000000000b1', 'quantidade', 1)))::text));
  select id into v from public.pedidos where salao_id = '57500000-0000-0000-0000-00000000000a' and numero = (r->>'numero')::bigint;
  perform t_dona(format('select public.mudar_status_pedido(%L::uuid, %L)', v, 'em_preparo'));
  perform t_dona(format('select public.definir_entregador(%L::uuid, %L)', v, p_quem));
  perform t_dona(format('select public.mudar_status_pedido(%L::uuid, %L)', v, 'saiu'));
  return v;
end $$;
create or replace function t_link(p_token text) returns jsonb language sql as $$
  select t_como(null, format('select public.entregas_do_entregador(%L::uuid)', p_token))
$$;
create or replace function t_entregou(p_token text, p_pedido uuid) returns jsonb language sql as $$
  select t_como(null, format('select public.entregador_entregou(%L::uuid, %L::uuid)', p_token, p_pedido))
$$;
create or replace function t_acerto(p_quem text) returns text language sql as $$
  select x->>'entregas' || ' entregas · dinheiro ' || (x->>'dinheiro') || ' · troco ' || (x->>'troco')
         || ' · ganha ' || (x->>'ganha') || ' · saldo ' || (x->>'saldo')
    from jsonb_array_elements(t_dona(format('select public.acerto_entregadores(%L::uuid, current_date - 1, current_date + 1)',
           '57500000-0000-0000-0000-00000000000a'))) x
   where x->>'entregador' = p_quem
$$;

select t_saiu('11975000101', 'dinheiro', '100', 'Lu') as e1 \gset
select t_saiu('11975000102', 'pix', null, 'Lu') as e2 \gset
select t_saiu('11975000103', 'dinheiro', null, 'Beto') as e3 \gset

\echo ''
\echo '1. O link da Lu'
select t_dona($q$select public.link_do_entregador('57500000-0000-0000-0000-00000000000a', 'Lu')$q$)->>'token' as lu \gset
select t_texto('o link é sempre o mesmo, enquanto não se pede outro',
  t_dona($q$select public.link_do_entregador('57500000-0000-0000-0000-00000000000a', 'Lu')$q$)->>'token', :'lu');
select t_texto('quem não está na lista não ganha link',
  erro_de($$select t_dona($q$select public.link_do_entregador('57500000-0000-0000-0000-00000000000a', 'Zé')$q$)$$),
  'Ponha o entregador na lista (Entrega e pagamento) antes.');
select t_texto('ela vê só as duas dela, na ordem em que saíram',
  (select string_agg(x->>'nome', ', ' order by x->>'numero') from jsonb_array_elements(t_link(:'lu')->'caminho') x),
  'Cliente 11975000101, Cliente 11975000102');
select t_texto('com o endereço, o telefone, o total e o troco',
  (select (x->'endereco'->>'rua') || ', ' || (x->'endereco'->>'numero') || ' (' || (x->'endereco'->>'referencia') || ') · '
          || (x->>'telefone') || ' · ' || (x->>'total') || ' · troco para ' || (x->>'troco')
     from jsonb_array_elements(t_link(:'lu')->'caminho') x where x->>'pagamento' = 'dinheiro'),
  'Rua das Flores, 01 (portão azul) · 11975000101 · 58.00 · troco para 100.00');
select t_texto('e o nome da casa', t_link(:'lu')->>'casa', 'Pizzaria da Rosa');
select t_entregou(:'lu', :'e1'::uuid);
select t_verdade('ela marcou "Entregue": o pedido terminou e virou venda',
  (select status = 'entregue' and comanda_id is not null from public.pedidos where id = :'e1'::uuid));
select t_texto('marcar de novo não vale',
  erro_de(format('select t_entregou(%L, %L::uuid)', :'lu', :'e1')), 'Este pedido não está mais a caminho.');
select t_texto('o pedido do Beto não é dela',
  erro_de(format('select t_entregou(%L, %L::uuid)', :'lu', :'e3')), 'Este pedido não está com você.');
select t_entregou(:'lu', :'e2'::uuid);
select t_texto('o resumo do dia dela: 2 entregas, recebeu 58 em dinheiro, ganha 6+6+20, devolve 26',
  (select (h->>'entregas') || ' · ' || (h->>'dinheiro') || ' · ' || (h->>'ganha') || ' · ' || (h->>'saldo')
     from (select t_link(:'lu')->'hoje' h) z), '2 · 58.00 · 32 · 26.00');
select t_igual('e as duas na lista de entregues de hoje', jsonb_array_length(t_link(:'lu')->'entregues')::bigint, 2);

\echo ''
\echo '2. O acerto'
select t_dona(format('select public.mudar_status_pedido(%L::uuid, %L)', :'e3', 'entregue'));
select t_texto('Lu: 2 entregas, 58 em dinheiro (levou 42 de troco), ganha 32, devolve 26',
  t_acerto('Lu'), '2 entregas · dinheiro 58.00 · troco 42.00 · ganha 32 · saldo 26.00');
select t_texto('Beto: 1 entrega, 58 em dinheiro, ganha 6+20, devolve 32',
  t_acerto('Beto'), '1 entregas · dinheiro 58.00 · troco 0 · ganha 26 · saldo 32.00');
update public.saloes set cfg = jsonb_set(cfg, '{pedidos,motoboy}', '{"modo":"taxa"}')
 where id = '57500000-0000-0000-0000-00000000000a';
select t_texto('no modo "igual à taxa", a Lu ganha as taxas (8+8) e devolve 42',
  t_acerto('Lu'), '2 entregas · dinheiro 58.00 · troco 42.00 · ganha 16.00 · saldo 42.00');

\echo ''
\echo '3. Cortar o link'
select t_dona($q$select public.link_do_entregador('57500000-0000-0000-0000-00000000000a', 'Lu', true)$q$)->>'token' as lu2 \gset
select t_verdade('outro link: o antigo não abre mais', not (t_link(:'lu')->>'ok')::boolean);
select t_texto('nem marca entrega',
  erro_de(format('select t_entregou(%L, %L::uuid)', :'lu', :'e2')), 'Este link de entregador não vale mais. Peça outro ao restaurante.');
select t_verdade('o novo abre', (t_link(:'lu2')->>'ok')::boolean);
update public.saloes set cfg = jsonb_set(cfg, '{pedidos,entregadores}', '["Beto"]')
 where id = '57500000-0000-0000-0000-00000000000a';
select t_verdade('tirar a Lu da lista corta o link dela também', not (t_link(:'lu2')->>'ok')::boolean);

\echo ''
\echo '4. Quem não vê'
select t_falso('a página pública não vê quanto o motoboy ganha',
  t_como(null, $$select public.pedidos_da_casa('pizza-rosa')$$) ? 'motoboy');
select t_falso('nem os nomes', t_como(null, $$select public.pedidos_da_casa('pizza-rosa')$$) ? 'entregadores');
select t_texto('o garçom não pega o link',
  erro_de($$select t_como('b7500000-0000-0000-0000-00000000000b',
    $q$select public.link_do_entregador('57500000-0000-0000-0000-00000000000a', 'Beto')$q$)$$),
  'Só o balcão e a gestão mandam o link do entregador.');
select t_verdade('o anônimo não chama o acerto nem o link',
  erro_de($$select t_como(null, $q$select public.acerto_entregadores('57500000-0000-0000-0000-00000000000a', current_date, current_date)$q$)$$) is not null
  and erro_de($$select t_como(null, $q$select public.link_do_entregador('57500000-0000-0000-0000-00000000000a', 'Beto')$q$)$$) is not null);
select t_verdade('a tabela dos links não abre para a tela',
  not has_table_privilege('authenticated', 'public.entregador_links', 'select')
  and not has_table_privilege('anon', 'public.entregador_links', 'select'));
select t_verdade('um token qualquer não abre nada', not (t_link(gen_random_uuid()::text)->>'ok')::boolean);

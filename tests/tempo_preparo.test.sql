-- ===========================================================================
-- PediHub — tempo de preparo e o aviso de atrasado (74)
--
-- No Bistrô da Lu, mesa 4, o garçom lança de uma vez: um filé (30 min), uma
-- bruschetta de entrada (15 min) e um refrigerante (sem tempo).
--   1. cada item leva o tempo do prato; mudar o cardápio depois não mexe;
--   2. aos 20 minutos: a bruschetta ATRASADA (20 de 15), o filé no prazo, o
--      refri nunca atrasa; o mapa das mesas conta 1 atrasado;
--   3. a cozinha marca a bruschetta pronta: sai do atraso; desmarcar volta;
--   4. pedido do QR esperando "Aceitar" não corre relógio; pedido pronto não
--      atrasa; quem é de fora não marca; o prazo do prato tem limite.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a7400000-0000-0000-0000-00000000000a'),  -- Lu — dona
  ('b7400000-0000-0000-0000-00000000000b'),  -- Wilson — garçom
  ('e7400000-0000-0000-0000-00000000000e');  -- de fora
insert into public.perfis (id, nome, telefone) values
  ('a7400000-0000-0000-0000-00000000000a', 'Lu', '+5511974000001'),
  ('b7400000-0000-0000-0000-00000000000b', 'Wilson', '+5511974000002'),
  ('e7400000-0000-0000-0000-00000000000e', 'Fulano', '+5511974000009')
on conflict (id) do update set nome = excluded.nome;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57400000-0000-0000-0000-00000000000a', 'bistro-lu', 'Bistrô da Lu', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"mesas":10}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57400000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7400000-0000-0000-0000-00000000000a', '57400000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('b7400000-0000-0000-0000-00000000000b', '57400000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel, tempo_preparo) values
  ('57410000-0000-0000-0000-0000000000b1', '57400000-0000-0000-0000-00000000000a', 'Filé', 70, true, true, true, 30),
  ('57410000-0000-0000-0000-0000000000b2', '57400000-0000-0000-0000-00000000000a', 'Bruschetta', 25, true, true, true, 15),
  ('57410000-0000-0000-0000-0000000000b3', '57400000-0000-0000-0000-00000000000a', 'Refrigerante', 8, true, true, true, null);
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
create or replace function t_item(p_nome text) returns uuid language sql as $$
  select i.id from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
   where p.salao_id = '57400000-0000-0000-0000-00000000000a' and i.nome = p_nome order by p.criado_em limit 1
$$;
-- O que a conta da mesa diz de cada item: "nome:minutos/tempo:atrasado".
create or replace function t_relogio() returns text language sql as $$
  select string_agg(x->>'nome' || ':' || coalesce(x->>'minutos', '-') || '/' || coalesce(x->>'tempo', '-')
                    || ':' || (x->>'atrasado'), ' | ' order by x->>'nome')
    from jsonb_array_elements(t_como('b7400000-0000-0000-0000-00000000000b',
      $q$select public.conta_da_mesa('57400000-0000-0000-0000-00000000000a', '4')$q$)->'itens') x
$$;
create or replace function t_atrasados_no_mapa() returns text language sql as $$
  select x->>'atrasados' from jsonb_array_elements(t_como('b7400000-0000-0000-0000-00000000000b',
    $q$select public.mesas_abertas('57400000-0000-0000-0000-00000000000a')$q$)) x where x->>'mesa' = '4'
$$;

\echo ''
\echo '1. O tempo vai junto com o item'
select t_como('b7400000-0000-0000-0000-00000000000b', format('select public.lancar_pedido(%L, %L::jsonb)',
  '57400000-0000-0000-0000-00000000000a',
  '{"origem":"mesa","nome":"Mesa 4","entrega":"mesa","mesa":"4","pagamento":"na_mesa","itens":[
     {"produto":"57410000-0000-0000-0000-0000000000b1","quantidade":1},
     {"produto":"57410000-0000-0000-0000-0000000000b2","quantidade":1},
     {"produto":"57410000-0000-0000-0000-0000000000b3","quantidade":2}]}')) as l1 \gset
select t_texto('filé 30, bruschetta 15, refri sem tempo',
  (select string_agg(nome || ' ' || coalesce(tempo_preparo::text, '-'), ', ' order by ordem)
     from public.pedido_itens where pedido_id = (select id from public.pedidos
       where salao_id = '57400000-0000-0000-0000-00000000000a' and numero = (:'l1'::jsonb->>'numero')::bigint)),
  'Filé 30, Bruschetta 15, Refrigerante -');
select t_texto('acabou de entrar: nada atrasado, relógio no zero',
  t_relogio(), 'Bruschetta:0/15:false | Filé:0/30:false | Refrigerante:0/-:false');
update public.produtos set tempo_preparo = 5 where id = '57410000-0000-0000-0000-0000000000b1';
select t_igual('mudar o tempo no cardápio não muda o item que já está na cozinha',
  (select tempo_preparo from public.pedido_itens where id = t_item('Filé'))::bigint, 30);

\echo ''
\echo '2. Aos 20 minutos'
update public.pedidos set aceito_em = now() - interval '20 minutes 10 seconds'
 where salao_id = '57400000-0000-0000-0000-00000000000a';
select t_texto('a bruschetta passou (20 de 15); o filé está no prazo; o refri não conta',
  t_relogio(), 'Bruschetta:20/15:true | Filé:20/30:false | Refrigerante:20/-:false');
select t_texto('o mapa das mesas acusa 1 atrasado na mesa 4', t_atrasados_no_mapa(), '1');
select t_texto('a lista do painel também: o pedido com 20 min e a bruschetta marcada',
  (select (x->>'minutos') || ' ' || (select string_agg(i->>'nome', ',') from jsonb_array_elements(x->'itens') i
                                      where (i->>'atrasado')::boolean)
     from jsonb_array_elements(t_como('a7400000-0000-0000-0000-00000000000a',
       $q$select public.pedidos_da_loja('57400000-0000-0000-0000-00000000000a', 24)$q$)) x),
  '20 Bruschetta');

\echo ''
\echo '3. A cozinha marca a bruschetta pronta'
select t_como('a7400000-0000-0000-0000-00000000000a',
  format('select public.marcar_item_pronto(%L::uuid, true)', t_item('Bruschetta')));
select t_texto('pronta: sai do atraso e para de contar',
  t_relogio(), 'Bruschetta:-/15:false | Filé:20/30:false | Refrigerante:20/-:false');
select t_texto('o mapa zera', t_atrasados_no_mapa(), '0');
select t_como('a7400000-0000-0000-0000-00000000000a',
  format('select public.marcar_item_pronto(%L::uuid, false)', t_item('Bruschetta')));
select t_texto('tocou errado e desmarcou: volta a acusar', t_atrasados_no_mapa(), '1');
update public.pedidos set aceito_em = now() - interval '45 minutes'
 where salao_id = '57400000-0000-0000-0000-00000000000a';
select t_texto('aos 45 minutos, o filé também', t_atrasados_no_mapa(), '2');

\echo ''
\echo '4. Os cantos'
select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'bistro-lu',
  '{"nome":"Cliente","entrega":"mesa","mesa":"4","pagamento":"na_mesa","itens":[{"produto":"57410000-0000-0000-0000-0000000000b2","quantidade":1}]}')) as q1 \gset
update public.pedidos set criado_em = now() - interval '1 hour'
 where salao_id = '57400000-0000-0000-0000-00000000000a' and numero = (:'q1'::jsonb->>'numero')::bigint;
select t_texto('pedido do QR esperando "Aceitar" não corre relógio (o alarme de pedido novo cuida dele)',
  t_atrasados_no_mapa(), '2');
update public.pedidos set status = 'pronto', pronto_em = now()
 where salao_id = '57400000-0000-0000-0000-00000000000a' and numero = (:'l1'::jsonb->>'numero')::bigint;
select t_texto('o pedido ficou pronto: nada mais atrasado', t_atrasados_no_mapa(), '0');
select t_texto('item de pedido que já saiu da cozinha não se marca',
  erro_de(format($q$select t_como('a7400000-0000-0000-0000-00000000000a', 'select public.marcar_item_pronto(''%s''::uuid, true)')$q$,
    t_item('Filé'))), 'Este pedido já saiu da cozinha.');
select t_texto('quem é de fora não marca',
  erro_de(format($q$select t_como('e7400000-0000-0000-0000-00000000000e', 'select public.marcar_item_pronto(''%s''::uuid, true)')$q$,
    t_item('Filé'))), 'Sem permissão neste estabelecimento.');
select t_verdade('o tempo do prato fica entre 1 e 600 minutos',
  erro_de($$update public.produtos set tempo_preparo = 0 where id = '57410000-0000-0000-0000-0000000000b1'$$) is not null
  and erro_de($$update public.produtos set tempo_preparo = 601 where id = '57410000-0000-0000-0000-0000000000b1'$$) is not null);

-- ===========================================================================
-- PediHub — o cliente é o WhatsApp dele (84)
--
--   1. a dona lança três pedidos no balcão, de três clientes novos: são TRÊS
--      fichas, cada uma com o seu WhatsApp, nenhuma presa à conta da dona;
--   2. no link, o mesmo WhatsApp escrito de três jeitos é uma ficha só — e o
--      nome que a ficha tem não é trocado;
--   3. o cliente com conta cai na ficha da conta dele;
--   4. o conserto: as fichas misturadas do jeito do defeito voltam a ser três,
--      cada pedido (e a venda) no seu dono;
--   5. o aniversário do pedido: preenche a ficha sem data, não troca a que
--      tem, recusa data no futuro e token que não existe;
--   6. 'aniversario' chega ao link (ligado se não disser nada).
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a8400000-0000-0000-0000-00000000000a'),  -- Lia  — dona
  ('c8400000-0000-0000-0000-00000000000c');  -- Duda — cliente com conta
insert into public.perfis (id, nome, telefone) values
  ('a8400000-0000-0000-0000-00000000000a', 'Lia', '+5511970008401'),
  ('c8400000-0000-0000-0000-00000000000c', 'Duda', '+5511970008409')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, tipo, cfg) values
  ('58400000-0000-0000-0000-00000000000a', 'lanche-lia', 'Lanchonete da Lia', 'ativo', 'America/Sao_Paulo',
   'restaurante', '{"pedidos":{"pagamentos":["dinheiro"]}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58400000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a8400000-0000-0000-0000-00000000000a', '58400000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('58410000-0000-0000-0000-0000000000b1', '58400000-0000-0000-0000-00000000000a', 'X-Burger', 20, true, true, true);
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
create or replace function t_balcao(p_nome text, p_tel text) returns jsonb language sql as $$
  select t_como('a8400000-0000-0000-0000-00000000000a', format('select public.lancar_pedido(%L, %L::jsonb)',
    '58400000-0000-0000-0000-00000000000a',
    jsonb_build_object('origem', 'balcao', 'nome', p_nome, 'telefone', p_tel, 'entrega', 'retirada',
      'pagamento', 'dinheiro', 'itens', jsonb_build_array(jsonb_build_object(
        'produto', '58410000-0000-0000-0000-0000000000b1', 'quantidade', 1)))))
$$;
create or replace function t_link(p_quem uuid, p_nome text, p_tel text) returns jsonb language sql as $$
  select t_como(p_quem, format('select public.fazer_pedido(%L, %L::jsonb)', 'lanche-lia',
    jsonb_build_object('nome', p_nome, 'telefone', p_tel, 'entrega', 'retirada',
      'pagamento', 'dinheiro', 'itens', jsonb_build_array(jsonb_build_object(
        'produto', '58410000-0000-0000-0000-0000000000b1', 'quantidade', 1)))))
$$;
-- A ficha de um telefone, e quem são os pedidos dela.
create or replace function t_ficha(p_tel text) returns text language sql as $$
  select coalesce((select c.nome || ' / ' || coalesce(c.telefone, '-') || ' / '
      || coalesce((select string_agg(q.nome, ',' order by q.criado_em) from public.pedidos q
                    where q.cliente_id = c.id), '-')
     from public.clientes c
    where c.salao_id = '58400000-0000-0000-0000-00000000000a' and c.telefone = p_tel), 'sem ficha')
$$;
create or replace function t_fichas() returns bigint language sql as $$
  select count(*) from public.clientes where salao_id = '58400000-0000-0000-0000-00000000000a'
$$;

\echo ''
\echo '1. Três clientes novos no balcão: três fichas'
select t_balcao('Ana',  '(11) 97100-0001');
select t_balcao('Beto', '(11) 97100-0002');
select t_balcao('Caio', '(11) 97100-0003');
select t_igual('três fichas', t_fichas(), 3);
select t_texto('a da Ana, com o WhatsApp dela',  t_ficha('11971000001'), 'Ana / 11971000001 / Ana');
select t_texto('a do Beto, com o dele',          t_ficha('11971000002'), 'Beto / 11971000002 / Beto');
select t_texto('a do Caio, com o dele',          t_ficha('11971000003'), 'Caio / 11971000003 / Caio');
select t_igual('nenhuma presa à conta da dona',
  (select count(*) from public.clientes where perfil_id = 'a8400000-0000-0000-0000-00000000000a'), 0);

\echo ''
\echo '2. No link: o mesmo WhatsApp, escrito de três jeitos'
select t_link(null, 'Aninha', '+55 11 97100-0001');
select t_link(null, 'Ana Paula', '11971000001');
select t_igual('continua uma ficha para a Ana', t_fichas(), 3);
select t_texto('os três pedidos nela, e o nome da ficha não muda',
  t_ficha('11971000001'), 'Ana / 11971000001 / Ana,Aninha,Ana Paula');
select t_link(null, 'Davi', '(11) 97100-0004');
select t_texto('WhatsApp novo, ficha nova', t_ficha('11971000004'), 'Davi / 11971000004 / Davi');

\echo ''
\echo '3. O cliente com conta cai na ficha da conta'
select t_link('c8400000-0000-0000-0000-00000000000c', 'Duda', '(11) 97000-8409');
select t_verdade('a ficha da Duda é a da conta dela',
  exists (select 1 from public.clientes where salao_id = '58400000-0000-0000-0000-00000000000a'
           and perfil_id = 'c8400000-0000-0000-0000-00000000000c' and telefone = '11970008409'));

\echo ''
\echo '4. O conserto das fichas que o defeito misturou'
-- O pedido do Beto (do balcão, já nasce em preparo) foi entregue: virou venda.
select t_como('a8400000-0000-0000-0000-00000000000a', format('select public.mudar_status_pedido(%L, %L)', id, s))
  from public.pedidos q, unnest(array['pronto', 'entregue']) s
 where q.nome = 'Beto' and q.salao_id = '58400000-0000-0000-0000-00000000000a';
-- Do jeito que o defeito deixava: tudo na ficha da Ana, presa à dona, com o número do Caio.
do $$
declare v_ana uuid; v_beto uuid; v_caio uuid;
begin
  select id into v_ana  from public.clientes where telefone = '11971000001';
  select id into v_beto from public.clientes where telefone = '11971000002';
  select id into v_caio from public.clientes where telefone = '11971000003';
  update public.pedidos  set cliente_id = v_ana where cliente_id in (v_beto, v_caio);
  update public.comandas set cliente_id = v_ana where cliente_id in (v_beto, v_caio);
  delete from public.clientes where id in (v_beto, v_caio);
  update public.clientes set perfil_id = 'a8400000-0000-0000-0000-00000000000a', telefone = '11971000003'
   where id = v_ana;
end $$;
select t_texto('antes: uma ficha só, "Ana", com o número do Caio',
  t_ficha('11971000003'), 'Ana / 11971000003 / Ana,Beto,Caio,Aninha,Ana Paula');
select t_igual('o conserto acha uma ficha', public.consertar_fichas_da_equipe(), 1);
select t_texto('a Ana volta ao WhatsApp dela, com os pedidos dela',
  t_ficha('11971000001'), 'Ana / 11971000001 / Ana,Aninha,Ana Paula');
select t_texto('o Beto ganha a ficha dele de volta', t_ficha('11971000002'), 'Beto / 11971000002 / Beto');
select t_texto('o Caio também',                      t_ficha('11971000003'), 'Caio / 11971000003 / Caio');
select t_igual('e a venda do Beto vai junto',
  (select count(*) from public.comandas m join public.clientes c on c.id = m.cliente_id
    where c.telefone = '11971000002'), 1);
select t_igual('a conta da dona saiu da ficha',
  (select count(*) from public.clientes where perfil_id = 'a8400000-0000-0000-0000-00000000000a'), 0);
select t_igual('rodar de novo não acha nada', public.consertar_fichas_da_equipe(), 0);
select t_igual('e a ficha da Duda (conta de cliente) não foi tocada',
  (select count(*) from public.clientes where perfil_id = 'c8400000-0000-0000-0000-00000000000c'), 1);

\echo ''
\echo '5. O aniversário do pedido'
create or replace function t_niver(p_token uuid, p_data text) returns jsonb language sql as $$
  select t_como(null, format('select to_jsonb(public.aniversario_do_pedido(%L::uuid, %L::date))', p_token, p_data))
$$;
select t_texto('o pedido do Davi grava o aniversário',
  t_niver((select token from public.pedidos where nome = 'Davi'), '1990-07-15')::text, 'true');
select t_texto('na ficha dele',
  (select nascimento::text from public.clientes where telefone = '11971000004'), '1990-07-15');
select t_texto('outro pedido não troca a data que já existe',
  t_niver((select token from public.pedidos where nome = 'Davi'), '1985-01-01')::text, 'false');
select t_texto('a data continua a primeira',
  (select nascimento::text from public.clientes where telefone = '11971000004'), '1990-07-15');
select t_texto('data no futuro é recusada',
  erro_de(format($q$select t_niver(%L, %L)$q$, (select token from public.pedidos where nome = 'Davi'),
                 (current_date + 30)::text)), 'Confira a data do aniversário.');
select t_texto('token que não existe não grava nada',
  t_niver('00000000-0000-0000-0000-000000000000', '1990-07-15')::text, 'false');
update public.pedidos set criado_em = now() - interval '3 days' where nome = 'Caio';
select t_texto('nem pedido antigo',
  t_niver((select token from public.pedidos where nome = 'Caio'), '1990-07-15')::text, 'false');

\echo ''
\echo '6. Perguntar ou não, no link'
create or replace function t_casa() returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role anon;
  r := public.pedidos_da_casa('lanche-lia');
  reset role;
  return r;
end $$;
select t_texto('sem dizer nada: pergunta', t_casa()->>'aniversario', 'true');
update public.saloes set cfg = jsonb_set(cfg, '{pedidos,aniversario}', 'false')
 where id = '58400000-0000-0000-0000-00000000000a';
select t_texto('desligado: não pergunta', t_casa()->>'aniversario', 'false');

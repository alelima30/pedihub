-- ===========================================================================
-- PediHub — promoção nos itens do cardápio (79)
--
-- A Burgueria do Tom põe quatro itens em promoção:
--   X-Bacon     R$ 30 → 24,90, sem data de fim;
--   Combo       R$ 40 → 30, até HOJE (ainda vale o dia inteiro);
--   Suco        R$ 20 → 15, até ONTEM (já acabou);
--   Água        R$ 10 → 12 (maior que o preço: não é promoção).
--
--   1. o link recebe só as promoções que valem, com o preço cheio para riscar;
--   2. o pedido do link é cobrado no preço da promoção — quem decide é o banco;
--   3. o pedido do balcão também;
--   4. tirou a promoção, volta ao preço normal; item com preço escondido não
--      aparece na faixa.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a7900000-0000-0000-0000-00000000000a');
insert into public.perfis (id, nome, telefone) values ('a7900000-0000-0000-0000-00000000000a', 'Tom', '+5511979000001')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('57900000-0000-0000-0000-00000000000a', 'burgueria-tom', 'Burgueria do Tom', 'ativo', 'America/Sao_Paulo', '{}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('57900000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7900000-0000-0000-0000-00000000000a', '57900000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, preco_promo, promo_ate, ativo, venda_online, preco_visivel) values
  ('57910000-0000-0000-0000-0000000000b1', '57900000-0000-0000-0000-00000000000a', 'X-Bacon', 30, 24.90, null, true, true, true),
  ('57910000-0000-0000-0000-0000000000b2', '57900000-0000-0000-0000-00000000000a', 'Combo', 40, 30,
     (now() at time zone 'America/Sao_Paulo')::date, true, true, true),
  ('57910000-0000-0000-0000-0000000000b3', '57900000-0000-0000-0000-00000000000a', 'Suco', 20, 15,
     (now() at time zone 'America/Sao_Paulo')::date - 1, true, true, true),
  ('57910000-0000-0000-0000-0000000000b4', '57900000-0000-0000-0000-00000000000a', 'Água', 10, 12, null, true, true, true),
  ('57910000-0000-0000-0000-0000000000b5', '57900000-0000-0000-0000-00000000000a', 'Prato do dia', 35, 28, null, true, true, false);
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
create or replace function t_itens(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('produto', '57910000-0000-0000-0000-0000000000' || x, 'quantidade', 1))
    from unnest(p) x
$$;

\echo ''
\echo '1. O link recebe só as promoções que valem'
select t_como(null, $$select public.pedidos_da_casa('burgueria-tom')$$)->'promocoes' as promos \gset
select t_texto('X-Bacon e Combo, com o preço cheio para riscar (Suco acabou ontem; Água não é promoção)',
  (select string_agg((x->>'cheio') || '→' || (x->>'preco'), ' · ' order by (x->>'cheio')::numeric)
     from jsonb_array_elements(:'promos'::jsonb) x),
  '30.00→24.90 · 40.00→30.00');
select t_texto('o Combo diz até quando vale',
  (select x->>'ate' from jsonb_array_elements(:'promos'::jsonb) x where (x->>'cheio')::numeric = 40),
  ((now() at time zone 'America/Sao_Paulo')::date)::text);
select t_igual('o item de preço escondido não entra na faixa',
  (select count(*) from jsonb_array_elements(:'promos'::jsonb) x
    where x->>'id' = '57910000-0000-0000-0000-0000000000b5'), 0);

\echo ''
\echo '2. O pedido do link é cobrado no preço da promoção'
select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'burgueria-tom',
  jsonb_build_object('nome', 'Ana', 'telefone', '11979000050', 'entrega', 'retirada', 'pagamento', 'pix',
    'itens', t_itens('b1', 'b1', 'b2', 'b3', 'b4'))::text)) as p1 \gset
select t_texto('2 X-Bacon (24,90) + Combo (30) + Suco (20, acabou) + Água (10) = 109,80',
  :'p1'::jsonb->>'subtotal', '109.80');
select t_texto('e cada item fica gravado com o preço cobrado',
  (select string_agg(i.nome || ' ' || i.preco, ' · ' order by i.preco, i.nome)
     from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
    where p.salao_id = '57900000-0000-0000-0000-00000000000a' and p.numero = (:'p1'::jsonb->>'numero')::bigint),
  'Água 10.00 · Suco 20.00 · X-Bacon 24.90 · X-Bacon 24.90 · Combo 30.00');

\echo ''
\echo '3. O balcão também cobra a promoção'
select t_como('a7900000-0000-0000-0000-00000000000a', format('select public.lancar_pedido(%L, %L::jsonb)',
  '57900000-0000-0000-0000-00000000000a',
  jsonb_build_object('origem', 'balcao', 'nome', 'Balcão', 'entrega', 'retirada', 'pagamento', 'dinheiro',
    'itens', t_itens('b1'))::text)) as p2 \gset
select t_texto('X-Bacon no balcão: 24,90', :'p2'::jsonb->>'subtotal', '24.90');

\echo ''
\echo '4. Tirou a promoção, volta ao preço normal'
update public.produtos set preco_promo = null where id = '57910000-0000-0000-0000-0000000000b1';
select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'burgueria-tom',
  jsonb_build_object('nome', 'Ana', 'telefone', '11979000050', 'entrega', 'retirada', 'pagamento', 'pix',
    'itens', t_itens('b1'))::text)) as p3 \gset
select t_texto('X-Bacon sem promoção: 30', :'p3'::jsonb->>'subtotal', '30.00');
select t_igual('e ele sai da faixa do link',
  jsonb_array_length(t_como(null, $$select public.pedidos_da_casa('burgueria-tom')$$)->'promocoes'), 1);
select t_texto('promoção negativa é recusada pelo banco',
  erro_de($$update public.produtos set preco_promo = -1 where id = '57910000-0000-0000-0000-0000000000b4'$$),
  'new row for relation "produtos" violates check constraint "produtos_preco_promo_positivo"');

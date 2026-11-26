-- ===========================================================================
-- PediHub — o cardápio do link em lista, e o número de cada item (82)
--
-- O Paiva's tem os lanches numerados no cardápio de papel e quase nenhuma
-- foto. Ele escolhe "só a lista" e liga os números:
--
--   1. sem escolher nada, o link continua com as fotos e sem número, e a
--      fileira das categorias fica presa no alto;
--   2. "lista" e "numerar" chegam ao link pelo pedidos_da_casa();
--   3. valor torto vira o padrão (fotos, sem número) — nunca um erro na tela;
--   4. o link recebe o número de cada item, em ordem, e só dos itens que a
--      cliente vê (ativo e no link);
--   5. número fora de 1 a 9999 o banco recusa.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a8200000-0000-0000-0000-00000000000a');
insert into public.perfis (id, nome, telefone) values ('a8200000-0000-0000-0000-00000000000a', 'Paiva', '+5511982000001')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, tipo, cfg) values
  ('58200000-0000-0000-0000-00000000000a', 'paivas-burgers', 'Paiva''s Burgers', 'ativo', 'America/Sao_Paulo', 'restaurante', '{}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58200000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a8200000-0000-0000-0000-00000000000a', '58200000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, numero, ativo, venda_online, preco_visivel) values
  ('58210000-0000-0000-0000-0000000000b1', '58200000-0000-0000-0000-00000000000a', 'X-Burguer', 26, 14, true, true, true),
  ('58210000-0000-0000-0000-0000000000b2', '58200000-0000-0000-0000-00000000000a', 'Hot-dog', 15, 1, true, true, true),
  ('58210000-0000-0000-0000-0000000000b3', '58200000-0000-0000-0000-00000000000a', 'Misto', 30, 5, true, true, true),
  ('58210000-0000-0000-0000-0000000000b4', '58200000-0000-0000-0000-00000000000a', 'Refrigerante', 7, null, true, true, true),
  ('58210000-0000-0000-0000-0000000000b5', '58200000-0000-0000-0000-00000000000a', 'Lanche antigo', 20, 99, false, true, true),
  ('58210000-0000-0000-0000-0000000000b6', '58200000-0000-0000-0000-00000000000a', 'Só no balcão', 12, 50, true, false, true);
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
create or replace function t_cardapio() returns jsonb language sql as $$
  select t_como(null, $q$select public.pedidos_da_casa('paivas-burgers')$q$)
$$;

\echo ''
\echo '1. Sem escolher nada: fotos e sem número'
select t_texto('o link recebe o padrão de sempre',
  (t_cardapio()->'cardapio')::text, '{"fixar": true, "estilo": "fotos", "numerar": false}');

\echo ''
\echo '2. Só a lista, numerada'
update public.saloes set cfg = '{"pedidos": {"cardapio": {"estilo": "lista", "numerar": true, "fixar": false}}}'
 where id = '58200000-0000-0000-0000-00000000000a';
select t_texto('o link recebe "lista", "numerar" e a fileira solta',
  (t_cardapio()->'cardapio')::text, '{"fixar": false, "estilo": "lista", "numerar": true}');
select t_texto('e a configuração do painel diz o mesmo',
  (public.cfg_pedidos('58200000-0000-0000-0000-00000000000a')->'cardapio')::text, '{"fixar": false, "estilo": "lista", "numerar": true}');

\echo ''
\echo '3. Valor torto vira o padrão'
update public.saloes set cfg = '{"pedidos": {"cardapio": {"estilo": "grade", "numerar": "sim", "fixar": "talvez"}}}'
 where id = '58200000-0000-0000-0000-00000000000a';
select t_texto('"grade" vira fotos, "sim" não liga os números, e a fileira fica presa',
  (t_cardapio()->'cardapio')::text, '{"fixar": true, "estilo": "fotos", "numerar": false}');
update public.saloes set cfg = '{"pedidos": {"cardapio": "lista"}}'
 where id = '58200000-0000-0000-0000-00000000000a';
select t_texto('e um texto no lugar do objeto também não quebra',
  (t_cardapio()->'cardapio')::text, '{"fixar": true, "estilo": "fotos", "numerar": false}');

\echo ''
\echo '4. O número de cada item chega ao link, em ordem'
select t_texto('Hot-dog 1, Misto 5, X-Burguer 14 — sem o desativado e sem o que não está no link',
  (select string_agg((x->>'numero') || ' ' || p.nome, ' · ' order by (x->>'numero')::int)
     from jsonb_array_elements(t_cardapio()->'numeros') x
     join public.produtos p on p.id = (x->>'id')::uuid),
  '1 Hot-dog · 5 Misto · 14 X-Burguer');
select t_igual('o item sem número não entra na lista dos números',
  (select count(*) from jsonb_array_elements(t_cardapio()->'numeros') x
    where x->>'id' = '58210000-0000-0000-0000-0000000000b4'), 0);
select t_igual('e a lista vem em ordem, mesmo com o 14 cadastrado primeiro',
  (select (t_cardapio()->'numeros'->0->>'numero')::int), 1);

\echo ''
\echo '5. Número fora de 1 a 9999 o banco recusa'
do $$
begin
  begin
    update public.produtos set numero = 0 where id = '58210000-0000-0000-0000-0000000000b4';
    raise exception 'aceitou o número 0';
  exception when check_violation then null;
  end;
  begin
    update public.produtos set numero = 10000 where id = '58210000-0000-0000-0000-0000000000b4';
    raise exception 'aceitou o número 10000';
  exception when check_violation then null;
  end;
end $$;
select t_igual('0 e 10000 recusados; o item continua sem número',
  (select count(*) from public.produtos where id = '58210000-0000-0000-0000-0000000000b4' and numero is null), 1);
update public.produtos set numero = 9999 where id = '58210000-0000-0000-0000-0000000000b4';
select t_igual('9999 pode', (select numero from public.produtos where id = '58210000-0000-0000-0000-0000000000b4'), 9999);

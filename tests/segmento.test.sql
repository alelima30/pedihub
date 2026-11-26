-- ===========================================================================
-- PediHub — o tipo do estabelecimento que a cliente vê (83)
--
--   1. sem escolher, é restaurante;
--   2. "lanchonete" chega ao link pelo pedidos_da_casa();
--   3. valor de fora da lista (ou que não é texto) vira restaurante.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into public.saloes (id, slug, nome, status, fuso, tipo, cfg) values
  ('58300000-0000-0000-0000-00000000000a', 'paivas-83', 'Paivas Burgers', 'ativo', 'America/Sao_Paulo', 'restaurante', '{}');
grant usage on schema auth to anon, authenticated;

create or replace function t_casa() returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role anon;
  r := public.pedidos_da_casa('paivas-83');
  reset role;
  return r;
end $$;

\echo ''
\echo '1. Sem escolher, é restaurante'
select t_texto('o link recebe "restaurante"', t_casa()->>'segmento', 'restaurante');

\echo ''
\echo '2. A lanchonete'
update public.saloes set cfg = '{"pedidos": {"segmento": "lanchonete"}}' where id = '58300000-0000-0000-0000-00000000000a';
select t_texto('o link recebe "lanchonete"', t_casa()->>'segmento', 'lanchonete');
update public.saloes set cfg = '{"pedidos": {"segmento": "food_truck", "cardapio": {"estilo": "lista"}}}'
 where id = '58300000-0000-0000-0000-00000000000a';
select t_texto('e "food_truck", sem mexer no resto da configuração',
  (t_casa()->>'segmento') || ' / ' || (t_casa()->'cardapio'->>'estilo'), 'food_truck / lista');

\echo ''
\echo '3. Valor torto vira restaurante'
update public.saloes set cfg = '{"pedidos": {"segmento": "<b>Lanchonete</b>"}}' where id = '58300000-0000-0000-0000-00000000000a';
select t_texto('texto livre (HTML) não passa', t_casa()->>'segmento', 'restaurante');
update public.saloes set cfg = '{"pedidos": {"segmento": 7}}' where id = '58300000-0000-0000-0000-00000000000a';
select t_texto('número também não', t_casa()->>'segmento', 'restaurante');

-- ===========================================================================
-- PediHub — os planos (66_planos_pedihub)
--
-- Os outros testes de banco ainda conferem os planos do salão, de onde o
-- PediHub nasceu. Este instala os planos do restaurante por cima e confere:
--
--   1. a vitrine: Grátis, Teste, Essencial (R$ 97) e Profissional
--      (R$ 147); os do salão desligados; e o PRECOS.sql diz o mesmo preço
--      que o 66 (senão a próxima colagem do 98_modulos volta o preço antigo);
--   2. o que cada um libera: caixa e relatórios só no pago; WhatsApp
--      automático e crediário só no Profissional;
--   3. o Grátis aceita 50 pedidos no mês e recusa o 51º; o pago não tem teto.
-- ===========================================================================
\set ON_ERROR_STOP on
\ir ../supabase/66_planos_pedihub.sql

insert into public.saloes (id, slug, nome, status, fuso) values
  ('56600000-0000-0000-0000-00000000000a', 'lanche-gratis', 'Lanche Grátis', 'ativo', 'America/Sao_Paulo'),
  ('56600000-0000-0000-0000-00000000000b', 'lanche-pago',   'Lanche Pago',   'ativo', 'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('56600000-0000-0000-0000-00000000000a', 'gratuito',   'ativa', current_date + 20),
  ('56600000-0000-0000-0000-00000000000b', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status,
                                     vence_em = excluded.vence_em;

create or replace function t_pedido(p_salao uuid, p_numero int) returns void language sql as $$
  insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega,
                              subtotal, taxa_entrega, total, pagamento)
  values (p_salao, p_numero, 'Cliente', '5511966000000', 'retirada', 20, 0, 20, 'pix')
$$;

\echo ''
\echo '1. A vitrine'
select t_texto('os planos à venda, na ordem',
  (select string_agg(nome || ' ' || preco_mes, ' | ' order by ordem, codigo)
     from public.planos where ativo),
  'Grátis 0.00 | Teste grátis 0.00 | Essencial 97.00 | Profissional 147.00');
-- O PRECOS.sql aplica o mesmo preço do 66: rodado por cima, nada muda.
\o /dev/null
\ir ../supabase/PRECOS.sql
\o
select t_texto('o PRECOS.sql e o 66 dizem o mesmo preço',
  (select string_agg(nome || ' ' || preco_mes, ' | ' order by ordem, codigo)
     from public.planos where ativo),
  'Grátis 0.00 | Teste grátis 0.00 | Essencial 97.00 | Profissional 147.00');
select t_igual('os do salão estão desligados',
  (select count(*) from public.planos
    where codigo in ('basico','duo','equipe','salao') and ativo), 0);

\echo ''
\echo '2. O que cada um libera'
select t_falso('Grátis: sem caixa',      public.recurso_bool('56600000-0000-0000-0000-00000000000a', 'caixa'));
select t_falso('Grátis: sem relatórios', public.recurso_bool('56600000-0000-0000-0000-00000000000a', 'relatorios'));
select t_verdade('Grátis: com cardápio e pedido pelo link',
  public.recurso_bool('56600000-0000-0000-0000-00000000000a', 'loja'));
select t_verdade('Essencial: caixa e relatórios',
  public.recurso_bool('56600000-0000-0000-0000-00000000000b', 'caixa')
  and public.recurso_bool('56600000-0000-0000-0000-00000000000b', 'relatorios'));
select t_igual('Essencial: sem mensagem automática',
  public.recurso_num('56600000-0000-0000-0000-00000000000b', 'mensagens_mes')::bigint, 0);
select t_igual('Profissional: 1.000 mensagens por mês',
  ((select recursos->>'mensagens_mes' from public.planos where codigo = 'time'))::bigint, 1000);
select t_verdade('Profissional: crediário incluso',
  ((select recursos->>'crediario' from public.planos where codigo = 'time'))::boolean);

\echo ''
\echo '3. O teto do Grátis'
select t_pedido('56600000-0000-0000-0000-00000000000a', g) from generate_series(1, 50) g;
select t_igual('o Grátis aceitou 50 pedidos no mês',
  (select count(*) from public.pedidos where salao_id = '56600000-0000-0000-0000-00000000000a'), 50);
select t_texto('o 51º é recusado, com o caminho do WhatsApp',
  erro_de($$select t_pedido('56600000-0000-0000-0000-00000000000a', 51)$$),
  'Este restaurante chegou ao limite de pedidos pelo link neste mês. Faça o pedido pelo WhatsApp do restaurante.');
select t_pedido('56600000-0000-0000-0000-00000000000b', g) from generate_series(1, 60) g;
select t_igual('o Essencial não tem teto: 60 pedidos',
  (select count(*) from public.pedidos where salao_id = '56600000-0000-0000-0000-00000000000b'), 60);

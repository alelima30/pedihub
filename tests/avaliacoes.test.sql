-- ===========================================================================
-- PediHub — avaliação do pedido (80)
--
-- Na Pastelaria da Ana:
--   1. pedido ainda não entregue não se avalia; entregue, sim — uma vez por
--      pedido, podendo trocar a nota; nota fora de 1..5 é recusada; token
--      errado não acha nada;
--   2. o link mostra a média, o total e só os comentários BONS (4 e 5) que a
--      gestão não escondeu — sem telefone nem sobrenome;
--   3. o painel vê tudo (as ruins também), com os itens do pedido; só a
--      gestão vê e só a gestão esconde; o prazo de 15 dias vale.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a8000000-0000-0000-0000-00000000000a'), ('b8000000-0000-0000-0000-00000000000b');
insert into public.perfis (id, nome, telefone) values
  ('a8000000-0000-0000-0000-00000000000a', 'Ana', '+5511980000001'),
  ('b8000000-0000-0000-0000-00000000000b', 'Garçom Léo', '+5511980000002')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('58000000-0000-0000-0000-00000000000a', 'pastel-ana', 'Pastelaria da Ana', 'ativo', 'America/Sao_Paulo', '{}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58000000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a8000000-0000-0000-0000-00000000000a', '58000000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('b8000000-0000-0000-0000-00000000000b', '58000000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
-- Cinco pedidos: quatro entregues (um há 20 dias) e um ainda em preparo.
insert into public.pedidos (id, salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status, entregue_em, token) values
  ('58100000-0000-0000-0000-000000000001', '58000000-0000-0000-0000-00000000000a', 1, 'Bruna Souza', '11980000011', 'retirada', 20, 0, 20, 'pix', 'entregue', now(), '58200000-0000-0000-0000-000000000001'),
  ('58100000-0000-0000-0000-000000000002', '58000000-0000-0000-0000-00000000000a', 2, 'Carlos Lima', '11980000012', 'retirada', 20, 0, 20, 'pix', 'entregue', now(), '58200000-0000-0000-0000-000000000002'),
  ('58100000-0000-0000-0000-000000000003', '58000000-0000-0000-0000-00000000000a', 3, 'Duda Alves',  '11980000013', 'retirada', 20, 0, 20, 'pix', 'entregue', now(), '58200000-0000-0000-0000-000000000003'),
  ('58100000-0000-0000-0000-000000000004', '58000000-0000-0000-0000-00000000000a', 4, 'Edu Reis',    '11980000014', 'retirada', 20, 0, 20, 'pix', 'em_preparo', null, '58200000-0000-0000-0000-000000000004'),
  ('58100000-0000-0000-0000-000000000005', '58000000-0000-0000-0000-00000000000a', 5, 'Fê Antiga',   '11980000015', 'retirada', 20, 0, 20, 'pix', 'entregue', now() - interval '20 days', '58200000-0000-0000-0000-000000000005');
insert into public.pedido_itens (pedido_id, nome, preco, quantidade) values
  ('58100000-0000-0000-0000-000000000002', 'Pastel de carne', 10, 2);
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
create or replace function t_avaliar(p_token text, p_nota int, p_txt text) returns jsonb language sql as $$
  select t_como(null, format('select public.avaliar_pedido(%L::uuid, %s, %L)', p_token, p_nota, p_txt))
$$;

\echo ''
\echo '1. Quem avalia, e quando'
select t_texto('pedido em preparo ainda não se avalia',
  erro_de($$select t_avaliar('58200000-0000-0000-0000-000000000004', 5, 'ótimo')$$),
  'Dá para avaliar depois que o pedido for entregue.');
select t_texto('entregue: a Bruna dá 5 estrelas com comentário',
  t_avaliar('58200000-0000-0000-0000-000000000001', 5, '  Pastel   quentinho e  sequinho! ')->>'comentario',
  'Pastel quentinho e sequinho!');
select t_texto('nota fora de 1 a 5 é recusada',
  erro_de($$select t_avaliar('58200000-0000-0000-0000-000000000002', 6, null)$$), 'Escolha de 1 a 5 estrelas.');
select t_avaliar('58200000-0000-0000-0000-000000000002', 4, 'Gostei');
select t_avaliar('58200000-0000-0000-0000-000000000002', 2, 'Veio frio');
select t_texto('o Carlos trocou a nota: fica uma avaliação só, com a nota nova',
  (select count(*) || ' · ' || max(nota) || ' · ' || max(comentario) from public.avaliacoes
    where pedido_id = '58100000-0000-0000-0000-000000000002'), '1 · 2 · Veio frio');
select t_avaliar('58200000-0000-0000-0000-000000000003', 4, 'Muito bom, recomendo');
select t_texto('entregue há 20 dias: o prazo de 15 dias acabou',
  erro_de($$select t_avaliar('58200000-0000-0000-0000-000000000005', 5, 'top')$$), 'O prazo para avaliar este pedido já acabou.');
select t_texto('token que não existe não acha nada',
  erro_de($$select t_avaliar('58200000-0000-0000-0000-0000000000ff', 5, 'x')$$), 'Não achei este pedido.');
select t_texto('o acompanhamento sabe a nota que ela deu e que ainda pode trocar',
  (select (x->>'pode') || ' · ' || (x->>'nota') from (select t_como(null,
     $$select public.avaliacao_do_pedido('58200000-0000-0000-0000-000000000001')$$) x) y), 'true · 5');
select t_texto('e o pedido antigo diz que não pode mais',
  t_como(null, $$select public.avaliacao_do_pedido('58200000-0000-0000-0000-000000000005')$$)->>'pode', 'false');
select t_falso('a cliente não lê a tabela direto',
  erro_de($$select t_como(null, 'select to_jsonb(count(*)) from public.avaliacoes')$$) is null);

\echo ''
\echo '2. O que o link mostra'
select t_como(null, $$select public.avaliacoes_da_casa('pastel-ana')$$) as casa \gset
select t_texto('a média conta todas as notas (5, 2, 4) e o total é 3',
  (:'casa'::jsonb->>'media') || ' · ' || (:'casa'::jsonb->>'total'), '3.7 · 3');
select t_texto('só os comentários bons aparecem, com o primeiro nome',
  (select string_agg((x->>'nome') || ': ' || (x->>'comentario'), ' | ' order by x->>'nome')
     from jsonb_array_elements(:'casa'::jsonb->'recentes') x),
  'Bruna: Pastel quentinho e sequinho! | Duda: Muito bom, recomendo');
select t_falso('sem telefone nem sobrenome no que sai', :'casa' ~ '1198000|Souza|Alves');

\echo ''
\echo '3. O painel'
select t_como('a8000000-0000-0000-0000-00000000000a',
  $$select public.avaliacoes_do_restaurante('58000000-0000-0000-0000-00000000000a')$$) as painel \gset
select t_texto('a dona vê as três, a ruim também, e as estrelas por nota',
  (:'painel'::jsonb->>'total') || ' · ' || (:'painel'::jsonb->'estrelas'->>'2') || ' de 2 estrelas · '
  || (:'painel'::jsonb->'estrelas'->>'5') || ' de 5', '3 · 1 de 2 estrelas · 1 de 5');
select t_texto('com o que veio no pedido, para saber o que melhorar',
  (select x->>'itens' from jsonb_array_elements(:'painel'::jsonb->'lista') x where (x->>'numero')::int = 2),
  '2× Pastel de carne');
select t_texto('o garçom não vê as avaliações',
  erro_de($$select t_como('b8000000-0000-0000-0000-00000000000b',
    $q$select public.avaliacoes_do_restaurante('58000000-0000-0000-0000-00000000000a')$q$)$$),
  'Só a gestão do restaurante vê as avaliações.');
select t_como('a8000000-0000-0000-0000-00000000000a', format('select to_jsonb(public.ocultar_avaliacao(%L::uuid, true))',
  (select id from public.avaliacoes where pedido_id = '58100000-0000-0000-0000-000000000003')));
select t_texto('a dona escondeu o comentário da Duda: sai do link',
  (select string_agg(x->>'nome', ',') from jsonb_array_elements(
     t_como(null, $$select public.avaliacoes_da_casa('pastel-ana')$$)->'recentes') x), 'Bruna');
select t_texto('e o garçom não consegue esconder nada',
  erro_de(format('select t_como(%L::uuid, %L)', 'b8000000-0000-0000-0000-00000000000b',
    format('select to_jsonb(public.ocultar_avaliacao(%L::uuid, true))',
      (select id from public.avaliacoes where pedido_id = '58100000-0000-0000-0000-000000000001')))),
  'Só a gestão do restaurante mexe nas avaliações.');

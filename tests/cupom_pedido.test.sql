-- ===========================================================================
-- PediHub — o cupom no pedido do restaurante (68_cupom_no_pedido)
--
-- A Pizzaria do Léo (pizza de base R$ 0 com sabores, refri R$ 10, entrega
-- fixa R$ 6) cria BEMVINDO (10%, um por cliente, até 2 usos) e DEZ (R$ 10).
--
--   1. o desconto vale sobre o SUBTOTAL com os complementos, não sobre a
--      entrega; o total do banco e o uso ficam gravados;
--   2. a mesma pessoa não usa de novo; o pedido cancelado devolve o uso;
--   3. o limite de usos fecha o cupom; código errado e vencido explicam;
--   4. a prévia do link não diz se um número já usou;
--   5. a venda (65) leva o desconto: caixa e relatório batem com o pedido.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a6800000-0000-0000-0000-00000000000a');
insert into public.perfis (id, nome, telefone) values
  ('a6800000-0000-0000-0000-00000000000a', 'Léo', '+5511968000001')
on conflict (id) do update set nome = excluded.nome;
insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('56800000-0000-0000-0000-00000000000a', 'pizza-cupom', 'Pizzaria Cupom', 'ativo', 'America/Sao_Paulo',
   '{"pedidos":{"taxaPadrao":6}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('56800000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a6800000-0000-0000-0000-00000000000a', '56800000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('56810000-0000-0000-0000-0000000000b1', '56800000-0000-0000-0000-00000000000a', 'Pizza grande', 0, true, true, true),
  ('56810000-0000-0000-0000-0000000000b2', '56800000-0000-0000-0000-00000000000a', 'Refrigerante', 10, true, true, true);
insert into public.produto_grupos (id, salao_id, produto_id, nome, min, max, regra) values
  ('56820000-0000-0000-0000-0000000000a1', '56800000-0000-0000-0000-00000000000a',
   '56810000-0000-0000-0000-0000000000b1', 'Sabor', 1, 1, 'soma');
insert into public.produto_opcoes (id, grupo_id, salao_id, nome, preco) values
  ('56830000-0000-0000-0000-0000000000c1', '56820000-0000-0000-0000-0000000000a1',
   '56800000-0000-0000-0000-00000000000a', 'Calabresa', 90);
-- Cupons criados como o painel cria: sem dizer "vale para produto".
insert into public.cupons (salao_id, codigo, tipo, valor, vale_agendamento, vale_produtos, limite_total, um_por_cliente) values
  ('56800000-0000-0000-0000-00000000000a', 'bemvindo', 'pct', 10, true, false, 2, true),
  ('56800000-0000-0000-0000-00000000000a', 'DEZ', 'valor', 10, true, false, null, false);
insert into public.cupons (salao_id, codigo, tipo, valor, fim) values
  -- Ontem NO RESTAURANTE: entre 21h e meia-noite de Brasília o current_date (UTC) já é amanhã.
  ('56800000-0000-0000-0000-00000000000a', 'VELHO', 'pct', 50, (now() at time zone 'America/Sao_Paulo')::date - 1);
grant usage on schema auth to anon, authenticated;

create or replace function t_anon(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  set local role anon;
  execute p_sql into r;
  reset role;
  return r;
end $$;
-- Uma pizza de Calabresa (90) e um refri (10) = 100, entrega 6.
create or replace function t_pedir(p_tel text, p_cupom text) returns jsonb language sql as $$
  select t_anon(format('select public.fazer_pedido(%L, %L::jsonb)', 'pizza-cupom',
    json_build_object('nome', 'Cliente', 'telefone', p_tel, 'entrega', 'entrega', 'pagamento', 'pix',
      'cupom', p_cupom,
      'endereco', json_build_object('rua', 'Rua A', 'numero', '1', 'bairro', 'Centro'),
      'itens', json_build_array(
        json_build_object('produto', '56810000-0000-0000-0000-0000000000b1', 'quantidade', 1,
                          'opcoes', json_build_array('56830000-0000-0000-0000-0000000000c1')),
        json_build_object('produto', '56810000-0000-0000-0000-0000000000b2', 'quantidade', 1)))::text))
$$;

\echo ''
\echo '1. O desconto sobre o subtotal'
select t_verdade('todo cupom do PediHub vale para pedido',
  not exists (select 1 from public.cupons where salao_id = '56800000-0000-0000-0000-00000000000a' and not vale_produtos));
select t_pedir('11968000010', ' bemvindo ') as r1 \gset
select t_texto('10% de 100 = 10; total = 100 − 10 + 6 de entrega = 96',
  (:'r1'::jsonb->>'desconto') || ' / ' || (:'r1'::jsonb->>'total'), '10.00 / 96.00');
select t_texto('o pedido guarda o código e o desconto',
  (select cupom_codigo || ' ' || desconto from public.pedidos
    where salao_id = '56800000-0000-0000-0000-00000000000a' and numero = (:'r1'::jsonb->>'numero')::bigint),
  'BEMVINDO 10.00');
select t_igual('o uso ficou registrado, ligado ao pedido',
  (select count(*) from public.cupom_usos u join public.pedidos p on p.id = u.pedido_id
    where p.salao_id = '56800000-0000-0000-0000-00000000000a'), 1);

\echo ''
\echo '2. Um por cliente, e o cancelado devolve'
select t_texto('o mesmo WhatsApp não usa de novo',
  erro_de($$select t_pedir('11968000010', 'BEMVINDO')$$), 'Você já usou este cupom.');
update public.pedidos set status = 'cancelado', cancelado_em = now()
 where salao_id = '56800000-0000-0000-0000-00000000000a' and telefone = '11968000010';
select t_pedir('11968000010', 'BEMVINDO') as r2 \gset
select t_texto('cancelado o primeiro, ele usa de novo', :'r2'::jsonb->>'desconto', '10.00');

\echo ''
\echo '3. Limite, código errado, vencido'
select t_pedir('11968000020', 'BEMVINDO');
select t_texto('dois usos valendo: o terceiro número não usa mais',
  erro_de($$select t_pedir('11968000030', 'BEMVINDO')$$), 'Este cupom já foi usado o máximo de vezes.');
select t_texto('código que não existe',
  erro_de($$select t_pedir('11968000030', 'NAOEXISTE')$$), 'Cupom não encontrado. Confira as letras e os números.');
select t_texto('cupom vencido diz a data',
  erro_de($$select t_pedir('11968000030', 'VELHO')$$),
  'Este cupom venceu em ' || to_char((now() at time zone 'America/Sao_Paulo')::date - 1, 'DD/MM/YYYY') || '.');
select t_pedir('11968000030', 'DEZ') as r3 \gset
select t_texto('R$ 10 fixo: total 100 − 10 + 6 = 96', :'r3'::jsonb->>'total', '96.00');

\echo ''
\echo '4. A prévia do link'
select t_texto('a prévia calcula sobre o subtotal informado',
  t_anon($$select public.cupom_do_pedido_previa('pizza-cupom', 'DEZ', 55)$$)->>'desconto', '10.00');
select t_verdade('e não devolve o id do cupom',
  not (t_anon($$select public.cupom_do_pedido_previa('pizza-cupom', 'DEZ', 55)$$) ? 'cupom_id'));
select t_verdade('o link sabe que a casa tem cupom',
  (t_anon($$select to_jsonb(public.casa_tem_cupom('pizza-cupom'))$$))::text = 'true');
select t_verdade('a conta interna não é chamada de fora',
  not has_function_privilege('anon', 'public.cupom_do_pedido(uuid,text,numeric,text,boolean)', 'execute'));

\echo ''
\echo '5. A venda leva o desconto'
update public.pedidos set status = 'entregue', entregue_em = now()
 where salao_id = '56800000-0000-0000-0000-00000000000a' and numero = (:'r3'::jsonb->>'numero')::bigint;
select t_texto('a comanda do pedido entregue: 100 − 10 + 6 = 96, e o Pix de 96',
  (select t.total || ' / ' || pg.valor from public.pedidos p
     join public.comandas_totais t on t.id = p.comanda_id
     join public.pagamentos pg on pg.comanda_id = p.comanda_id
    where p.salao_id = '56800000-0000-0000-0000-00000000000a' and p.numero = (:'r3'::jsonb->>'numero')::bigint),
  '96.00 / 96.00');

\echo ''
\echo '6. Esgotado com um toque (69)'
insert into auth.users (id) values ('d6800000-0000-0000-0000-00000000000d');
insert into public.perfis (id, nome, telefone) values ('d6800000-0000-0000-0000-00000000000d', 'Ju', '+5511968000004')
on conflict (id) do nothing;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('d6800000-0000-0000-0000-00000000000d', '56800000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
create or replace function t_ju(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  perform set_config('request.jwt.claim.sub', 'd6800000-0000-0000-0000-00000000000d', true);
  set local role authenticated;
  execute p_sql into r;
  reset role;
  return r;
end $$;
select t_ju($$select public.marcar_esgotado('56810000-0000-0000-0000-0000000000b2', true)$$);
select t_falso('a atendente marcou o refri como esgotado',
  (select ativo from public.produtos where id = '56810000-0000-0000-0000-0000000000b2'));
select t_texto('e o link não deixa pedir',
  erro_de($$select t_pedir('11968000099', '')$$), 'Um dos itens saiu do cardápio. Confira o pedido.');
select t_ju($$select public.marcar_esgotado('56810000-0000-0000-0000-0000000000b2', false)$$);
select t_verdade('voltou: disponível de novo',
  (select ativo from public.produtos where id = '56810000-0000-0000-0000-0000000000b2'));
select t_ju($$update public.produtos set preco = 1 where id = '56810000-0000-0000-0000-0000000000b2' returning to_jsonb(preco)$$);
select t_texto('mas a atendente não muda o preço por fora (o banco ignora a tentativa)',
  (select preco::text from public.produtos where id = '56810000-0000-0000-0000-0000000000b2'), '10.00');

-- ===========================================================================
-- PediHub — Pix online no link (81)
--
-- Na Pizzaria Bella:
--   1. sem o Mercado Pago conectado, o Pix online não aparece nem é aceito;
--   2. a conexão: só a gestão começa; a volta do Mercado Pago grava a conta
--      (uma vez, e só com o "state" certo); o painel vê "conectado" sem ver
--      credencial nenhuma;
--   3. o pedido com Pix online nasce esperando o pagamento: fora da tela de
--      Pedidos, sem aviso no celular e sem WhatsApp para a casa;
--   4. o Pix cai (pix_confirmar, só o servidor): valor errado é recusado; o
--      certo libera para a cozinha, marca PAGO e avisa — uma vez só;
--   5. 30 minutos sem pagar: cancela dizendo o porquê; e se o dinheiro cair
--      depois, o pedido volta a valer;
--   6. o navegador não alcança nenhuma função do servidor.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a8100000-0000-0000-0000-00000000000a'), ('b8100000-0000-0000-0000-00000000000b');
insert into public.perfis (id, nome, telefone) values
  ('a8100000-0000-0000-0000-00000000000a', 'Bella', '+5511981000001'),
  ('b8100000-0000-0000-0000-00000000000b', 'Garçom Rui', '+5511981000002')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, whatsapp, cfg) values
  ('58110000-0000-0000-0000-00000000000a', 'pizza-bella', 'Pizzaria Bella', 'ativo', 'America/Sao_Paulo',
   '11981000001', '{"pedidos":{"pixOnline":true,"mesas":5}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58110000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a8100000-0000-0000-0000-00000000000a', '58110000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('b8100000-0000-0000-0000-00000000000b', '58110000-0000-0000-0000-00000000000a', 'profissional', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('58111000-0000-0000-0000-0000000000b1', '58110000-0000-0000-0000-00000000000a', 'Pizza grande', 50, true, true, true);
insert into public.push_aparelhos (salao_id, perfil_id, endpoint, p256dh, auth) values
  ('58110000-0000-0000-0000-00000000000a', 'a8100000-0000-0000-0000-00000000000a',
   'https://push.exemplo/bella', repeat('p', 64), repeat('a', 16));
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
create or replace function t_servidor(p_sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role service_role;
  execute p_sql into r;
  reset role;
  return r;
end $$;
create or replace function t_pedir(p_extra text) returns jsonb language sql as $$
  select t_como(null, format('select public.fazer_pedido(%L, %L::jsonb)', 'pizza-bella',
    (('{"nome":"Lia","telefone":"11981000099","entrega":"retirada","pagamento":"pix_online",'
      || '"itens":[{"produto":"58111000-0000-0000-0000-0000000000b1","quantidade":1}]}')::jsonb
      || p_extra::jsonb)::text))
$$;
create or replace function t_id(p jsonb) returns uuid language sql as $$
  select id from public.pedidos where token = (p->>'token')::uuid
$$;

\echo ''
\echo '1. Sem o Mercado Pago conectado'
select t_falso('o link não oferece Pix online',
  (t_como(null, $$select public.pedidos_da_casa('pizza-bella')$$)->>'pixOnline')::boolean);
select t_texto('e o pedido com Pix online é recusado',
  erro_de($$select t_pedir('{}')$$),
  'Este restaurante não está recebendo Pix online agora. Escolha outra forma de pagamento.');

\echo ''
\echo '2. A conexão'
select t_texto('o garçom não conecta',
  erro_de($$select t_como('b8100000-0000-0000-0000-00000000000b',
    $q$select to_jsonb(public.mp_conexao_iniciar('58110000-0000-0000-0000-00000000000a'))$q$)$$),
  'Só a gestão do restaurante conecta o Mercado Pago.');
select t_como('a8100000-0000-0000-0000-00000000000a',
  $$select to_jsonb(public.mp_conexao_iniciar('58110000-0000-0000-0000-00000000000a'))$$)#>>'{}' as estado \gset
select t_verdade('a dona começa: um "state" de 64 caracteres', length(:'estado') = 64);
select t_texto('o navegador não consegue concluir a conexão sozinho',
  erro_de(format($q$select t_como(null, %L)$q$, format('select to_jsonb(public.mp_conexao_concluir(%L, %L, %L, %L, %L, now()))',
    :'estado', '123', 'APP_USR-x', 'TG-x', 'APP_USR-pk'))) is not null::text, 'true');
select t_servidor(format('select to_jsonb(public.mp_conexao_concluir(%L, %L, %L, %L, %L, %L::timestamptz))',
  :'estado', '987654321', 'APP_USR-token-da-bella', 'TG-renova', 'APP_USR-pk', (now() + interval '180 days')::text));
select t_texto('a volta do Mercado Pago gravou a conta da Bella',
  (select mp_user_id || ' · ' || access_token from public.mp_contas where salao_id = '58110000-0000-0000-0000-00000000000a'),
  '987654321 · APP_USR-token-da-bella');
select t_texto('o mesmo "state" não serve duas vezes',
  erro_de(format($q$select t_servidor(%L)$q$, format('select to_jsonb(public.mp_conexao_concluir(%L, %L, %L, %L, %L, now()))',
    :'estado', '1', 'x', 'y', 'z'))), 'A conexão expirou. Toque em "Conectar Mercado Pago" de novo.');
select t_como('a8100000-0000-0000-0000-00000000000a',
  $$select public.mp_conta_status('58110000-0000-0000-0000-00000000000a')$$) as st \gset
select t_texto('o painel vê "conectado", com o final da conta', (:'st'::jsonb->>'conectado') || ' · ' || (:'st'::jsonb->>'conta'), 'true · 4321');
select t_falso('e nenhuma credencial na resposta', :'st' ~ 'APP_USR|TG-');
select t_verdade('o link passa a oferecer Pix online',
  (t_como(null, $$select public.pedidos_da_casa('pizza-bella')$$)->>'pixOnline')::boolean);

\echo ''
\echo '3. O pedido nasce esperando o pagamento'
select t_pedir('{}') as p1 \gset
select t_texto('a resposta diz: aguardando pagamento, Pix online',
  (:'p1'::jsonb->>'status') || ' · ' || (:'p1'::jsonb->>'pixOnline') || ' · ' || (:'p1'::jsonb->>'total'),
  'aguardando_pagamento · true · 50.00');
select t_texto('gravado como Pix, pago online, vencendo em 30 minutos',
  (select pagamento || ' · ' || pago_online || ' · ' || (pix_expira_em between now() + interval '29 minutes' and now() + interval '31 minutes')
     from public.pedidos where id = t_id(:'p1'::jsonb)), 'pix · true · true');
select t_igual('fora da tela de Pedidos',
  jsonb_array_length(t_como('a8100000-0000-0000-0000-00000000000a',
    $$select public.pedidos_da_loja('58110000-0000-0000-0000-00000000000a')$$)), 0);
select t_igual('sem aviso no celular', (select count(*) from public.push_fila where salao_id = '58110000-0000-0000-0000-00000000000a'), 0);
select t_igual('e sem WhatsApp para a casa', (select count(*) from public.notificacoes
  where pedido_id = t_id(:'p1'::jsonb) and tipo = 'pedido_novo'), 0);
select t_texto('o acompanhamento sabe que é Pix online, esperando',
  (select (x->>'status') || ' · ' || (x->>'pixOnline') from (select t_como(null,
    format('select public.meu_pedido(%L::uuid)', :'p1'::jsonb->>'token')) x) y), 'aguardando_pagamento · true');
select t_texto('Pix online na mesa não existe',
  erro_de($$select t_pedir('{"entrega":"mesa","mesa":"2"}')$$), 'O Pix online é só para pedidos pelo link.');

\echo ''
\echo '4. O Pix cai'
select t_servidor(format('select public.pix_do_pedido(%L::uuid)', :'p1'::jsonb->>'token')) as dp \gset
select t_texto('o servidor acha o pedido pelo token, com a conta do restaurante',
  (:'dp'::jsonb->>'total') || ' · ' || (:'dp'::jsonb->'conta'->>'access'), '50.00 · APP_USR-token-da-bella');
select t_servidor(format('select to_jsonb(public.pix_anotar(%L::uuid, %L, %L))', t_id(:'p1'::jsonb), 'MP-111', '00020126...pix'));
select t_texto('o valor errado é recusado',
  erro_de(format($q$select t_servidor(%L)$q$, format('select to_jsonb(public.pix_confirmar(%L::uuid, %L, 40))', t_id(:'p1'::jsonb), 'MP-111'))),
  'Valor pago (40) diferente do pedido (50.00).');
select t_servidor(format('select to_jsonb(public.pix_confirmar(%L::uuid, %L, 50))', t_id(:'p1'::jsonb), 'MP-111'));
select t_texto('o certo libera para a cozinha, PAGO',
  (select status || ' · ' || (pago_em is not null) || ' · ' || mp_pagamento_id from public.pedidos where id = t_id(:'p1'::jsonb)),
  'recebido · true · MP-111');
select t_texto('aparece na tela de Pedidos, marcado como pago online',
  (select (x->>'status') || ' · ' || (x->>'pagoOnline') from jsonb_array_elements(t_como('a8100000-0000-0000-0000-00000000000a',
    $$select public.pedidos_da_loja('58110000-0000-0000-0000-00000000000a')$$)) x), 'recebido · true');
select t_igual('o celular da dona toca', (select count(*) from public.push_fila where salao_id = '58110000-0000-0000-0000-00000000000a'), 1);
select t_igual('e o WhatsApp da casa entra na fila', (select count(*) from public.notificacoes
  where pedido_id = t_id(:'p1'::jsonb) and tipo = 'pedido_novo'), 1);
select t_servidor(format('select to_jsonb(public.pix_confirmar(%L::uuid, %L, 50))', t_id(:'p1'::jsonb), 'MP-111'));
select t_texto('o aviso repetido do Mercado Pago não toca nem avisa de novo',
  (select count(*) from public.push_fila where salao_id = '58110000-0000-0000-0000-00000000000a') || ' · '
  || (select count(*) from public.notificacoes where pedido_id = t_id(:'p1'::jsonb) and tipo = 'pedido_novo'), '1 · 1');

\echo ''
\echo '5. Trinta minutos sem pagar'
select t_pedir('{"telefone":"11981000098"}') as p2 \gset
update public.pedidos set pix_expira_em = now() - interval '1 minute' where id = t_id(:'p2'::jsonb);
select t_servidor(format('select to_jsonb(public.pix_vencer(%L::uuid))', t_id(:'p2'::jsonb)));
select t_texto('cancela, dizendo o porquê',
  (select status || ' · ' || motivo from public.pedidos where id = t_id(:'p2'::jsonb)),
  'cancelado · o Pix não foi pago em 30 minutos');
select t_servidor(format('select to_jsonb(public.pix_confirmar(%L::uuid, %L, 50))', t_id(:'p2'::jsonb), 'MP-222'));
select t_texto('o dinheiro caiu depois: o pedido volta a valer',
  (select status || ' · ' || coalesce(motivo, 'sem motivo') from public.pedidos where id = t_id(:'p2'::jsonb)), 'recebido · sem motivo');

\echo ''
\echo '6. O navegador não alcança o servidor'
select t_verdade('pix_confirmar', erro_de(format($q$select t_como(null, %L)$q$,
  format('select to_jsonb(public.pix_confirmar(%L::uuid, %L, 50))', t_id(:'p1'::jsonb), 'x'))) is not null);
select t_verdade('pix_do_pedido', erro_de(format($q$select t_como(null, %L)$q$,
  format('select public.pix_do_pedido(%L::uuid)', :'p1'::jsonb->>'token'))) is not null);
select t_verdade('nem a dona logada', erro_de(format($q$select t_como('a8100000-0000-0000-0000-00000000000a', %L)$q$,
  format('select public.pix_do_pedido(%L::uuid)', :'p1'::jsonb->>'token'))) is not null);
select t_verdade('a tabela das contas não se lê', erro_de($$select t_como('a8100000-0000-0000-0000-00000000000a',
  'select to_jsonb(count(*)) from public.mp_contas')$$) is not null);

\echo ''
\echo '7. Desconectar'
select t_como('a8100000-0000-0000-0000-00000000000a', $$select to_jsonb(public.mp_desconectar('58110000-0000-0000-0000-00000000000a'))$$);
select t_falso('desconectou: o link para de oferecer Pix online na hora',
  (t_como(null, $$select public.pedidos_da_casa('pizza-bella')$$)->>'pixOnline')::boolean);

-- ===========================================================================
-- PediHub — o cliente já cadastrado, no Novo pedido (87)
--
--   1. a equipe recebe, pelo WhatsApp (escrito de qualquer jeito), quantos
--      pedidos a pessoa fez e o último endereço de entrega;
--   2. WhatsApp sem pedido nenhum: zero e sem endereço;
--   3. quem não é da casa não recebe.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a8700000-0000-0000-0000-00000000000a'),  -- dona
  ('c8700000-0000-0000-0000-00000000000c');  -- de fora
insert into public.perfis (id, nome, telefone) values
  ('a8700000-0000-0000-0000-00000000000a', 'Lia', '+5511970008701'),
  ('c8700000-0000-0000-0000-00000000000c', 'Fulano', '+5511970008709')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso, tipo, cfg) values
  ('58700000-0000-0000-0000-00000000000a', 'lanche-87', 'Lanchonete 87', 'ativo', 'America/Sao_Paulo',
   'restaurante', '{"pedidos":{"pagamentos":["dinheiro"]}}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58700000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a8700000-0000-0000-0000-00000000000a', '58700000-0000-0000-0000-00000000000a', 'dono', 'ativo');
insert into public.produtos (id, salao_id, nome, preco, ativo, venda_online, preco_visivel) values
  ('58710000-0000-0000-0000-0000000000b1', '58700000-0000-0000-0000-00000000000a', 'X-Burger', 20, true, true, true);
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
create or replace function t_cli(p_quem uuid, p_tel text) returns jsonb language sql as $$
  select t_como(p_quem, format('select public.cliente_para_pedido(%L, %L)', '58700000-0000-0000-0000-00000000000a', p_tel))
$$;

-- Dois pedidos da Ana: uma retirada e, depois, uma entrega na Rua das Flores.
select t_como(null, $q$select public.fazer_pedido('lanche-87', '{"nome":"Ana","telefone":"11970008720",
  "entrega":"retirada","pagamento":"dinheiro","itens":[{"produto":"58710000-0000-0000-0000-0000000000b1","quantidade":1}]}'::jsonb)$q$);
select t_como('a8700000-0000-0000-0000-00000000000a', $q$select public.lancar_pedido('58700000-0000-0000-0000-00000000000a',
  '{"origem":"telefone","nome":"Ana","telefone":"(11) 97000-8720","entrega":"entrega","pagamento":"dinheiro",
    "endereco":{"rua":"Rua das Flores","numero":"45","bairro":"Centro","referencia":"portão azul"},
    "itens":[{"produto":"58710000-0000-0000-0000-0000000000b1","quantidade":1}]}'::jsonb)$q$);

\echo ''
\echo '1. A equipe recebe o histórico e o último endereço'
select t_texto('dois pedidos', t_cli('a8700000-0000-0000-0000-00000000000a', '+55 11 97000-8720')->>'pedidos', '2');
select t_texto('o último endereço de entrega',
  t_cli('a8700000-0000-0000-0000-00000000000a', '11970008720')->'entrega'->'endereco'->>'rua', 'Rua das Flores');
select t_texto('com o ponto de referência',
  t_cli('a8700000-0000-0000-0000-00000000000a', '11970008720')->'entrega'->'endereco'->>'referencia', 'portão azul');

\echo ''
\echo '2. WhatsApp sem pedido'
select t_texto('zero pedidos', t_cli('a8700000-0000-0000-0000-00000000000a', '11970008799')->>'pedidos', '0');
select t_verdade('e sem endereço', t_cli('a8700000-0000-0000-0000-00000000000a', '11970008799')->'entrega' = 'null'::jsonb);

\echo ''
\echo '3. Quem não é da casa, não'
select t_texto('recusado', erro_de($q$select t_cli('c8700000-0000-0000-0000-00000000000c', '11970008720')$q$),
  'Sem permissão neste estabelecimento.');

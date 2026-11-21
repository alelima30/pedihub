-- ===========================================================================
-- PediHub — avisos no celular (59_push.sql)
--
--   1. quem liga: só a equipe, e cada um só no próprio nome;
--   2. o endereço do aparelho é segredo: ninguém lê de volta;
--   3. horário novo pelo link: balcão + quem atende; a outra profissional não;
--   4. horário marcado pela recepção não toca (a casa já sabe);
--   5. cancelado pela cliente toca; cancelado pela equipe não; sinal vencido toca;
--   6. pedido novo e pedido da loja: só o balcão;
--   7. a fila: pega, entrega, repete, desiste, apaga aparelho morto, vence;
--   8. as chaves do correio: gravam uma vez e nunca são trocadas;
--   9. o teste: só para os aparelhos de quem tocou, um por minuto;
--  10. NADA disto conta na franquia de mensagens.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a5900000-0000-0000-0000-00000000000a'),  -- Ana  — dona
  ('b5900000-0000-0000-0000-00000000000b'),  -- Rita — recepção
  ('d5900000-0000-0000-0000-00000000000d'),  -- Ju   — profissional
  ('d5900000-0000-0000-0000-00000000000e'),  -- Bia  — profissional
  ('c5900000-0000-0000-0000-00000000000c'),  -- Maria — cliente com conta
  ('e5900000-0000-0000-0000-00000000000e');  -- Eva  — dona de outro restaurante
insert into public.perfis (id, nome, telefone) values
  ('a5900000-0000-0000-0000-00000000000a', 'Ana',   '+5511959000001'),
  ('b5900000-0000-0000-0000-00000000000b', 'Rita',  '+5511959000002'),
  ('d5900000-0000-0000-0000-00000000000d', 'Ju',    '+5511959000004'),
  ('d5900000-0000-0000-0000-00000000000e', 'Bia',   '+5511959000005'),
  ('c5900000-0000-0000-0000-00000000000c', 'Maria', '+5511959000003'),
  ('e5900000-0000-0000-0000-00000000000e', 'Eva',   '+5511959000006')
on conflict (id) do update set nome = excluded.nome;

insert into public.saloes (id, slug, nome, status, fuso, cfg) values
  ('59000000-0000-0000-0000-00000000000a', 'push-a', 'Restaurante do Aviso', 'ativo', 'America/Sao_Paulo', '{}'),
  ('59000000-0000-0000-0000-00000000000b', 'push-b', 'Restaurante Vizinho',  'ativo', 'America/Sao_Paulo', '{}');
insert into public.assinaturas (salao_id, plano, status) values
  ('59000000-0000-0000-0000-00000000000a', 'time', 'ativa'),
  ('59000000-0000-0000-0000-00000000000b', 'time', 'ativa');
insert into public.vinculos (perfil_id, salao_id, papel) values
  ('a5900000-0000-0000-0000-00000000000a', '59000000-0000-0000-0000-00000000000a', 'dono'),
  ('b5900000-0000-0000-0000-00000000000b', '59000000-0000-0000-0000-00000000000a', 'recepcao'),
  ('d5900000-0000-0000-0000-00000000000d', '59000000-0000-0000-0000-00000000000a', 'profissional'),
  ('d5900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000a', 'profissional'),
  ('c5900000-0000-0000-0000-00000000000c', '59000000-0000-0000-0000-00000000000a', 'cliente'),
  ('e5900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000b', 'dono');
insert into public.profissionais (id, salao_id, perfil_id, nome, telefone, ativo, aceita_online) values
  ('95900000-0000-0000-0000-00000000000d', '59000000-0000-0000-0000-00000000000a',
   'd5900000-0000-0000-0000-00000000000d', 'Ju',  '11959000004', true, true),
  ('95900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000a',
   'd5900000-0000-0000-0000-00000000000e', 'Bia', '11959000005', true, true);
insert into public.jornadas (profissional_id, dia_semana, inicio, fim)
  select p, d, '08:00', '20:00' from generate_series(0, 6) d,
    unnest(array['95900000-0000-0000-0000-00000000000d','95900000-0000-0000-0000-00000000000e']::uuid[]) p;
insert into public.servicos (id, salao_id, nome, duracao_min, intervalo_min, preco, ativo, aceita_online) values
  ('59100000-0000-0000-0000-0000000000a1', '59000000-0000-0000-0000-00000000000a', 'Corte', 60, 0, 50, true, true);
insert into public.servicos_profissionais (servico_id, profissional_id) values
  ('59100000-0000-0000-0000-0000000000a1', '95900000-0000-0000-0000-00000000000d'),
  ('59100000-0000-0000-0000-0000000000a1', '95900000-0000-0000-0000-00000000000e');
insert into public.clientes (id, salao_id, nome, telefone) values
  ('c5910000-0000-0000-0000-00000000000a', '59000000-0000-0000-0000-00000000000a', 'Joana Lima', '11959001001');
grant usage on schema auth to anon, authenticated;

create or replace function t_como(p_quem uuid, p_sql text) returns text
language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_quem::text, ''), true);
  perform set_config('role', case when p_quem is null then 'anon' else 'authenticated' end, true);
  begin
    execute p_sql into r;
  exception when others then
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claim.sub', '', true);
    return 'ERRO: ' || sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return coalesce(r, '');
end $$;

-- Liga um aparelho como a pessoa (o caminho da tela).
create or replace function t_ligar(p_quem uuid, p_salao uuid, p_ep text) returns text
language sql as $$
  select t_como(p_quem, format($q$select public.push_registrar('%s', '%s',
    'BPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP',
    'AAAAAAAAAAAAAAAAAAAAAA', 'Celular · Chrome')::text$q$, p_salao, p_ep))
$$;
-- Quantos avisos pendentes há para os aparelhos de uma pessoa.
create or replace function t_avisos(p_perfil uuid) returns bigint language sql as $$
  select count(*) from public.push_fila f join public.push_aparelhos a on a.id = f.aparelho_id
   where a.perfil_id = p_perfil and f.status = 'pendente'
$$;
select (current_date + 3) as d \gset
create temporary table t_base as select :'d'::date as d;
create or replace function t_d() returns date language sql as $$ select d from t_base $$;
create or replace function t_em(p_hora text) returns timestamptz language sql as $$
  select (t_d() + p_hora::time) at time zone 'America/Sao_Paulo'
$$;

-- ===========================================================================
\echo ''
\echo '1. Quem liga'
-- ===========================================================================
do $$
declare e text;
begin
  e := t_ligar(null, '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/visitante');
  perform t_verdade('visitante sem login nem chama — ' || e, e like 'ERRO: permission denied%');
  e := t_ligar('c5900000-0000-0000-0000-00000000000c', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/maria');
  perform t_verdade('a cliente com conta não liga aviso do restaurante', e like 'ERRO: Só a equipe do restaurante%');
  e := t_ligar('e5900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/eva');
  perform t_verdade('a dona do restaurante vizinho não liga aviso neste', e like 'ERRO: Só a equipe do restaurante%');

  perform t_verdade('a dona liga',      t_ligar('a5900000-0000-0000-0000-00000000000a', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/ana')  like '{"ok": true}');
  perform t_verdade('a recepção liga',  t_ligar('b5900000-0000-0000-0000-00000000000b', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/rita') like '{"ok": true}');
  perform t_verdade('a Ju liga',        t_ligar('d5900000-0000-0000-0000-00000000000d', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/ju')   like '{"ok": true}');
  perform t_verdade('a Bia liga',       t_ligar('d5900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/bia')  like '{"ok": true}');
  perform t_verdade('a Eva, no restaurante dela, também',
    t_ligar('e5900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000b', 'https://push.exemplo/eva') like '{"ok": true}');

  e := t_ligar('a5900000-0000-0000-0000-00000000000a', '59000000-0000-0000-0000-00000000000a', 'http://inseguro/x');
  perform t_verdade('endereço que não é https é recusado', e like 'ERRO:%');

  perform t_ligar('a5900000-0000-0000-0000-00000000000a', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/ana');
  perform t_igual('ligar de novo o mesmo aparelho não duplica',
    (select count(*) from public.push_aparelhos where endpoint = 'https://push.exemplo/ana'), 1);

  -- O mesmo celular passando de uma pessoa para outra (a dona emprestou o
  -- aparelho à recepção, que entrou com a conta dela): o aviso passa a ser da
  -- nova dona do aparelho, não das duas.
  perform t_ligar('b5900000-0000-0000-0000-00000000000b', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/emprestado');
  perform t_ligar('d5900000-0000-0000-0000-00000000000e', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/emprestado');
  perform t_texto('o aparelho emprestado fica com quem ligou por último',
    (select perfil_id::text from public.push_aparelhos where endpoint = 'https://push.exemplo/emprestado'),
    'd5900000-0000-0000-0000-00000000000e');
  delete from public.push_aparelhos where endpoint = 'https://push.exemplo/emprestado';

  perform t_texto('"ligado aqui?" responde por quem pergunta',
    t_como('a5900000-0000-0000-0000-00000000000a',
      $q$select public.push_ligado('59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/ana')::text$q$), 'true');
  perform t_texto('e não por outra pessoa com o mesmo endereço',
    t_como('b5900000-0000-0000-0000-00000000000b',
      $q$select public.push_ligado('59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/ana')::text$q$), 'false');
end $$;

-- ===========================================================================
\echo ''
\echo '2. O endereço do aparelho é segredo'
-- ===========================================================================
do $$
declare e text;
begin
  e := t_como('a5900000-0000-0000-0000-00000000000a', $q$select count(*)::text from public.push_aparelhos$q$);
  perform t_verdade('ninguém lê a tabela de aparelhos pela API — ' || e, e like 'ERRO: permission denied%');
  e := t_como('a5900000-0000-0000-0000-00000000000a', $q$select count(*)::text from public.push_fila$q$);
  perform t_verdade('nem a fila', e like 'ERRO: permission denied%');
  e := t_como('a5900000-0000-0000-0000-00000000000a', $q$select public.push_config_ler()::text$q$);
  perform t_verdade('nem as chaves do correio', e like 'ERRO: permission denied%');
  e := t_como('a5900000-0000-0000-0000-00000000000a',
    $q$select public.push_meus_aparelhos('59000000-0000-0000-0000-00000000000a')::text$q$);
  perform t_verdade('a lista da tela tem só os aparelhos dela: 1', jsonb_array_length(e::jsonb) = 1);
  perform t_falso('e sem o endereço (o segredo que permite mandar aviso)', e like '%push.exemplo%');

  e := t_como('a5900000-0000-0000-0000-00000000000a', format($q$select public.push_remover_aparelho('%s')::text$q$,
    (select id from public.push_aparelhos where endpoint = 'https://push.exemplo/rita')));
  perform t_texto('a dona não remove o aparelho da recepção', (e::jsonb->>'removidos'), '0');
  perform t_igual('que continua lá', (select count(*) from public.push_aparelhos where endpoint = 'https://push.exemplo/rita'), 1);
end $$;

-- ===========================================================================
\echo ''
\echo '3. Horário novo pelo link'
-- ===========================================================================
insert into public.push_config (chaves) values ('{"publica":"BTeste","privadaJwk":{"kty":"EC"}}');
select t_em('14:00') as as14 \gset
select set_config('role', 'anon', false);
select public.agendar('95900000-0000-0000-0000-00000000000d', :'as14'::timestamptz,
  array['59100000-0000-0000-0000-0000000000a1']::uuid[], 'Maria Souza', '11959003333') is not null as marcou;
reset role;
do $$
declare f record;
begin
  perform t_igual('a dona recebe',      t_avisos('a5900000-0000-0000-0000-00000000000a'), 1);
  perform t_igual('a recepção recebe',  t_avisos('b5900000-0000-0000-0000-00000000000b'), 1);
  perform t_igual('a Ju (quem vai atender) recebe', t_avisos('d5900000-0000-0000-0000-00000000000d'), 1);
  perform t_igual('a Bia, que não tem nada com isso, não', t_avisos('d5900000-0000-0000-0000-00000000000e'), 0);
  perform t_igual('nem a dona do restaurante vizinho', t_avisos('e5900000-0000-0000-0000-00000000000e'), 0);
  select * into f from public.push_fila order by id limit 1;
  perform t_texto('o título', f.titulo, 'Horário novo pelo link');
  perform t_texto('a linha diz quem, quando e com quem', f.corpo,
    'Maria Souza · ' || to_char(t_d(), 'DD/MM') || ' às 14:00 · com Ju');
  perform t_texto('e abre na agenda', f.url, './app.html#agenda');
end $$;

-- ===========================================================================
\echo ''
\echo '4. Marcado pela recepção: não toca'
-- ===========================================================================
delete from public.push_fila;
select t_como('b5900000-0000-0000-0000-00000000000b', format($q$
  insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim, status, origem, valor_previsto)
  values ('59000000-0000-0000-0000-00000000000a', 'c5910000-0000-0000-0000-00000000000a',
          '95900000-0000-0000-0000-00000000000e', '%s', '%s', 'confirmado', 'recepcao', 50) returning 'ok'$q$,
  t_em('10:00'), t_em('11:00'))) as r \gset
select t_texto('a recepção marcou', :'r', 'ok');
select t_igual('e ninguém recebe aviso: a casa já sabe', (select count(*) from public.push_fila), 0);

-- ===========================================================================
\echo ''
\echo '5. Cancelamentos'
-- ===========================================================================
do $$
declare v_tok uuid; e text;
begin
  -- A cliente cancela pelo link (o segredo da marcação, sem login).
  select gerenciar_token into v_tok from public.agendamentos
   where salao_id = '59000000-0000-0000-0000-00000000000a' and origem = 'online' limit 1;
  e := t_como(null, format($q$select public.cancelar_agendamento('%s')::text$q$, v_tok));
  perform t_igual('cancelado pela cliente: a dona recebe', t_avisos('a5900000-0000-0000-0000-00000000000a'), 1);
  perform t_igual('e a Ju, que ia atender', t_avisos('d5900000-0000-0000-0000-00000000000d'), 1);
  perform t_verdade('a linha diz que a vaga voltou',
    (select corpo like '%a vaga voltou a ficar livre' from public.push_fila where titulo = 'Horário cancelado' limit 1));

  delete from public.push_fila;
  -- A recepção cancela o que ela mesma marcou.
  e := t_como('b5900000-0000-0000-0000-00000000000b', $q$
    update public.agendamentos set status = 'cancelado'
     where salao_id = '59000000-0000-0000-0000-00000000000a' and origem = 'recepcao' returning 'ok'$q$);
  perform t_texto('a recepção cancelou', e, 'ok');
  perform t_igual('e ninguém recebe aviso', (select count(*) from public.push_fila), 0);
end $$;

-- O sinal que venceu: quem cancela é o robô (sem login), e a vaga volta.
insert into public.agendamentos (id, salao_id, cliente_id, profissional_id, inicio, fim, status, origem,
                                 valor_previsto, sinal_exigido, sinal_ate)
values ('a5910000-0000-0000-0000-0000000000f1', '59000000-0000-0000-0000-00000000000a',
        'c5910000-0000-0000-0000-00000000000a', '95900000-0000-0000-0000-00000000000d',
        t_em('16:00'), t_em('17:00'), 'pendente', 'recepcao', 50, 20, now() - interval '1 minute');
delete from public.push_fila;
select public.liberar_sinais_vencidos() as liberou \gset
select t_igual('o sinal vencido liberou o horário', :'liberou'::bigint, 1);
select t_verdade('e o balcão fica sabendo que a vaga voltou, com o motivo (dona, recepção e a Ju)',
  (select count(*) = 3 and bool_and(corpo like '%sinal não pago%') from public.push_fila));

-- ===========================================================================
\echo ''
\echo '6. Pedidos: só o balcão'
-- ===========================================================================
delete from public.push_fila;
insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status)
values ('59000000-0000-0000-0000-00000000000a', 1, 'Carlos', '11959007777', 'entrega', 42, 5, 47, 'pix', 'recebido');
do $$ begin
  perform t_igual('pedido novo: a dona e a recepção',
    (select count(*) from public.push_fila), 2);
  perform t_igual('as profissionais não', t_avisos('d5900000-0000-0000-0000-00000000000d') + t_avisos('d5900000-0000-0000-0000-00000000000e'), 0);
  perform t_texto('com nome, valor e o jeito de entregar',
    (select corpo from public.push_fila limit 1), 'Carlos · R$ 47,00 · entrega');
end $$;
delete from public.push_fila;
insert into public.pedidos_loja (salao_id, numero, cliente_id, status, total_estimado)
values ('59000000-0000-0000-0000-00000000000a', 1, 'c5910000-0000-0000-0000-00000000000a', 'novo', 89.9);
do $$ begin
  perform t_igual('pedido da loja: o balcão também', (select count(*) from public.push_fila), 2);
  perform t_texto('com o nome da cliente e o valor',
    (select corpo from public.push_fila limit 1), 'Joana Lima · R$ 89,90');
end $$;

-- ===========================================================================
\echo ''
\echo '7. A fila'
-- ===========================================================================
do $$
declare r record; n int := 0; v_ap uuid;
begin
  perform t_falso('o painel não pega a fila',
    has_function_privilege('authenticated', 'public.push_proxima(int)', 'execute'));
  perform t_verdade('o worker pega', has_function_privilege('service_role', 'public.push_proxima(int)', 'execute'));

  for r in select * from public.push_proxima(10) loop n := n + 1; end loop;
  perform t_igual('pega os dois, com endereço e chaves do aparelho', n, 2);
  perform t_igual('e eles ficam "enviando" (outra volta não pega de novo)',
    (select count(*) from public.push_fila where status = 'enviando'), 2);
  perform t_igual('uma segunda volta, junto, não pega nada', (select count(*) from public.push_proxima(10)), 0);

  perform public.push_resultado((select min(id) from public.push_fila), true);
  perform t_texto('entregue vira enviado, com a hora',
    (select status || ':' || (enviado_em is not null)::text from public.push_fila order by id limit 1), 'enviado:true');

  -- O segundo falha com erro de servidor: volta para a fila.
  perform public.push_resultado((select max(id) from public.push_fila), false, '500');
  perform t_texto('erro passageiro volta para a fila, com o motivo',
    (select status || ':' || motivo from public.push_fila order by id desc limit 1), 'pendente:500');
  perform public.push_proxima(10); perform public.push_resultado((select max(id) from public.push_fila), false, '500');
  perform public.push_proxima(10); perform public.push_resultado((select max(id) from public.push_fila), false, '500');
  perform t_texto('na terceira tentativa, desiste', (select status from public.push_fila order by id desc limit 1), 'falhou');

  -- O aparelho morreu (app desinstalado): o serviço responde 410.
  select aparelho_id into v_ap from public.push_fila order by id limit 1;
  insert into public.push_fila (salao_id, aparelho_id, titulo, corpo)
    values ('59000000-0000-0000-0000-00000000000a', v_ap, 'X', 'y');
  perform public.push_proxima(10);
  perform public.push_resultado((select max(id) from public.push_fila), false, 'sumiu');
  perform t_igual('inscrição morta: o aparelho sai, e a fila dele junto',
    (select count(*) from public.push_aparelhos where id = v_ap), 0);

  -- Aviso velho não toca: "horário novo" de três horas atrás só confunde.
  insert into public.push_fila (salao_id, aparelho_id, titulo, corpo, criado_em)
    select '59000000-0000-0000-0000-00000000000a', id, 'Velho', 'z', now() - interval '3 hours'
      from public.push_aparelhos where endpoint = 'https://push.exemplo/rita';
  perform t_igual('aviso com mais de 2 horas não sai', (select count(*) from public.push_proxima(10)), 0);
  perform t_texto('é cancelado como vencido',
    (select status || ':' || motivo from public.push_fila where titulo = 'Velho'), 'cancelado:venceu');

  -- O worker caiu no meio: o "enviando" esquecido volta.
  insert into public.push_fila (salao_id, aparelho_id, titulo, corpo, status, tentada_em)
    select '59000000-0000-0000-0000-00000000000a', id, 'Órfão', 'z', 'enviando', now() - interval '15 minutes'
      from public.push_aparelhos where endpoint = 'https://push.exemplo/rita';
  perform t_igual('o "enviando" de um worker que caiu volta e sai na próxima volta',
    (select count(*) from public.push_proxima(10) where titulo = 'Órfão'), 1);
end $$;

-- ===========================================================================
\echo ''
\echo '8. As chaves do correio'
-- ===========================================================================
do $$
declare c jsonb;
begin
  c := public.push_config_gravar('{"publica":"BOutra","privadaJwk":{"kty":"EC","d":"x"}}');
  perform t_texto('gravar de novo NÃO troca a chave (mataria toda inscrição)', c->>'publica', 'BTeste');
  perform t_texto('a tela lê a pública', t_como('d5900000-0000-0000-0000-00000000000d',
    $q$select public.push_chave_publica()$q$), 'BTeste');
  perform t_verdade('o visitante não', t_como(null, $q$select public.push_chave_publica()$q$) like 'ERRO:%');
  perform t_falso('e ninguém da API grava chave',
    has_function_privilege('authenticated', 'public.push_config_gravar(jsonb)', 'execute'));
end $$;

-- ===========================================================================
\echo ''
\echo '9. O aviso de teste'
-- ===========================================================================
delete from public.push_fila;
do $$
declare e text;
begin
  e := t_como('d5900000-0000-0000-0000-00000000000d',
    $q$select public.push_testar('59000000-0000-0000-0000-00000000000a')::text$q$);
  perform t_texto('a Ju pede um teste: vai para o aparelho dela', e::jsonb->>'aparelhos', '1');
  perform t_igual('só para ela', t_avisos('d5900000-0000-0000-0000-00000000000d'), 1);
  perform t_igual('ninguém mais recebe', (select count(*) from public.push_fila), 1);
  e := t_como('d5900000-0000-0000-0000-00000000000d',
    $q$select public.push_testar('59000000-0000-0000-0000-00000000000a')::text$q$);
  perform t_igual('tocar de novo no mesmo minuto não manda outro', (select count(*) from public.push_fila), 1);
  e := t_como('e5900000-0000-0000-0000-00000000000e',
    $q$select public.push_testar('59000000-0000-0000-0000-00000000000a')::text$q$);
  perform t_verdade('quem é de fora do restaurante não testa', e like 'ERRO: Só a equipe%');
end $$;

-- ===========================================================================
\echo ''
\echo '10. Nada disto conta na franquia de mensagens'
-- ===========================================================================
do $$ begin
  perform t_igual('a franquia de WhatsApp do restaurante continua em zero',
    public.mensagens_no_mes('59000000-0000-0000-0000-00000000000a'), 0);
  perform t_verdade('e o aviso no celular não passa pela fila do WhatsApp',
    not exists (select 1 from public.notificacoes where corpo like 'Horário novo pelo link%'
                   or corpo like 'Pedido novo%'));
end $$;

-- ===========================================================================
\echo ''
\echo '11. Desligar'
-- ===========================================================================
do $$
declare e text;
begin
  -- Liga de novo (o da seção 7 "morreu" no teste da inscrição morta).
  perform t_ligar('a5900000-0000-0000-0000-00000000000a', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/ana');
  perform t_ligar('b5900000-0000-0000-0000-00000000000b', '59000000-0000-0000-0000-00000000000a', 'https://push.exemplo/rita');
  e := t_como('a5900000-0000-0000-0000-00000000000a',
    $q$select public.push_remover('https://push.exemplo/ana')::text$q$);
  perform t_texto('a dona desliga o aparelho dela', e::jsonb->>'removidos', '1');
  e := t_como('a5900000-0000-0000-0000-00000000000a',
    $q$select public.push_remover('https://push.exemplo/rita')::text$q$);
  perform t_texto('e não desliga o da recepção, mesmo sabendo o endereço', e::jsonb->>'removidos', '0');
end $$;

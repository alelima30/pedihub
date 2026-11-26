-- ===========================================================================
-- PediHub — o cliente é o WhatsApp dele; e o aniversário no pedido (84)
--
-- "Veja se está funcionando para saber que cliente é… é pelo WhatsApp?"
--
-- É. O link acha a ficha pelo WhatsApp (só os números, com ou sem o 55), e o
-- cliente que entrou com a conta, pela conta. O que estava errado era o pedido
-- lançado pela EQUIPE (balcão, telefone, mesa): ali quem está logado é o dono,
-- e a busca pela conta vinha antes do telefone. A primeira ficha nova nascia
-- presa à conta do dono, e todo cliente novo depois caía nela, trocando o
-- WhatsApp da ficha pelo dele. Este arquivo:
--
--   1. ficha_do_cliente(): para a equipe, a conta logada não conta — só o
--      WhatsApp digitado;
--   2. conserta as fichas que já se misturaram: a ficha volta ao WhatsApp do
--      seu primeiro pedido (o do mesmo nome), solta a conta do dono, e cada
--      pedido de outro número vai para a ficha daquele número (com a venda
--      junto);
--   3. aniversario_do_pedido(): o aniversário que o cliente põe no pedido
--      (opcional) vai para a ficha — só se ela ainda não tiver um;
--   4. cfg_pedidos(): a chave 'aniversario' (perguntar ou não no pedido).
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

-- ── 1. A FICHA PELO WHATSAPP ────────────────────────────────────────────────
create or replace function public.ficha_do_cliente(
  p_salao uuid, p_nome text, p_tel text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  /* ⚠ (84) QUEM ESTÁ LOGADO SÓ CONTA QUANDO É O PRÓPRIO CLIENTE. No pedido
     que o dono ou a equipe lança (balcão, telefone, mesa), quem está logado
     é o DONO: a primeira ficha nova nascia presa à conta dele, e todo
     cliente novo depois caía nela — pelo login, antes do telefone —, ainda
     trocando o WhatsApp da ficha pelo do último. Ana, Beto e Caio viravam
     uma ficha só, "Ana", com o número do Caio. Para a equipe, o cliente é o
     WhatsApp que ela digitou. */
  v_perfil  uuid := case when public.e_equipe(p_salao) then null else auth.uid() end;
  v_cliente uuid;
begin
  /* ⚠ O TELEFONE SEM O 55 NA FRENTE. Comparado ao pé da letra,
     "(51) 99999-8888" e "+55 51 99999-8888" eram duas pessoas: nascia uma
     segunda ficha, com o limite de horários dela, o histórico partido em
     dois e a marca "precisa de confirmação" ficando para trás. O celular
     preenche o campo sozinho no formato internacional, então não é caso raro.
     (A conta é a mesma do `telefone_nacional()` do 09, escrita aqui porque
     este arquivo vem antes.) */
  p_tel := nullif(public.so_digitos(p_tel), '');
  if length(p_tel) >= 12 and left(p_tel, 2) = '55' then p_tel := substr(p_tel, 3); end if;

  if v_perfil is not null then
    select c.id into v_cliente from public.clientes c
     where c.salao_id = p_salao and c.perfil_id = v_perfil;
  end if;

  if v_cliente is null and p_tel is not null then
    select c.id into v_cliente from public.clientes c
     where c.salao_id = p_salao and c.telefone = p_tel;
    -- Ficha gravada antes desta regra, com o 55: acha do mesmo jeito.
    if v_cliente is null then
      select c.id into v_cliente from public.clientes c
       where c.salao_id = p_salao and c.telefone = '55' || p_tel
       limit 1;
    end if;
  end if;

  if v_cliente is null then
    insert into public.clientes (salao_id, perfil_id, nome, telefone)
         values (p_salao, v_perfil, p_nome, p_tel)
      returning clientes.id into v_cliente;
    return v_cliente;
  end if;

  /* Reencontrou a ficha. Só preenche o que falta: sobrescrever o nome
     apagaria a correção que a recepção fez na ficha.

     O telefone novo entra apenas se ninguém mais o tiver neste restaurante — a
     outra trava, `ux_cli_tel`, derrubaria a marcação inteira, e a pessoa
     está aqui para marcar horário, não para arrumar cadastro. Na dúvida fica
     o que já estava, e o restaurante conserta pelo painel. */
  update public.clientes c
     set perfil_id = case
           when c.perfil_id is not null then c.perfil_id
           when v_perfil is null then null
           /* A ficha foi achada pelo TELEFONE, não pelo login. Sem SMS não
              existe prova de que o número é de quem digitou: pode ser o do
              marido, o da mãe, ou um dígito trocado. Amarrar a conta à ficha
              nesse caso adotaria o histórico de outra pessoa PARA SEMPRE —
              dali em diante toda marcação cairia lá.

              Com o nome batendo, é a mesma pessoa criando conta depois de já
              ter sido cadastrada no balcão — o caso comum, e esse continua
              amarrando. */
           when public.mesmo_primeiro_nome(c.nome, p_nome) then v_perfil
           else null end,
         telefone  = case
           when p_tel is null or p_tel = c.telefone then c.telefone
           when exists (select 1 from public.clientes o
                         where o.salao_id = p_salao
                           and o.telefone = p_tel
                           and o.id <> c.id) then c.telefone
           else p_tel end
   where c.id = v_cliente;

  return v_cliente;
end $$;
revoke all on function public.ficha_do_cliente(uuid, text, text) from public;

-- ── 2. O CONSERTO DAS FICHAS MISTURADAS ─────────────────────────────────────
/* Só as fichas presas à conta de alguém da EQUIPE do próprio restaurante e
   que têm pedido — o rastro exato do defeito. Rodar de novo não acha nada:
   a conta da equipe sai da ficha no primeiro conserto. */
create or replace function public.consertar_fichas_da_equipe()
returns int language plpgsql security definer set search_path = public as $conserto$
declare
  n       int := 0;
  f       record;
  p       record;
  v_certo text;
  v_outra uuid;
begin
  for f in
    select c.id, c.salao_id, c.nome, c.telefone from public.clientes c
     where c.perfil_id is not null
       and exists (select 1 from public.vinculos v
                    where v.salao_id = c.salao_id and v.perfil_id = c.perfil_id
                      and v.papel in ('dono','admin','recepcao','profissional'))
       and exists (select 1 from public.pedidos q where q.cliente_id = c.id)
  loop
    -- a) o WhatsApp de verdade da ficha: o do primeiro pedido com o mesmo nome
    select q.telefone into v_certo from public.pedidos q
     where q.cliente_id = f.id and coalesce(q.telefone, '') <> ''
       and public.mesmo_primeiro_nome(q.nome, f.nome)
     order by q.criado_em limit 1;
    if v_certo is not null and v_certo is distinct from f.telefone
       and not exists (select 1 from public.clientes o
                        where o.salao_id = f.salao_id and o.telefone = v_certo and o.id <> f.id) then
      update public.clientes set telefone = v_certo where id = f.id;
      f.telefone := v_certo;
    end if;
    -- b) a conta do dono sai da ficha
    update public.clientes set perfil_id = null where id = f.id;
    n := n + 1;
    -- c) cada pedido de outro número vai para a ficha daquele número
    for p in
      select q.id, q.nome, q.telefone, q.comanda_id from public.pedidos q
       where q.cliente_id = f.id and coalesce(q.telefone, '') <> ''
         and q.telefone is distinct from f.telefone
       order by q.criado_em
    loop
      v_outra := null;
      select o.id into v_outra from public.clientes o
       where o.salao_id = f.salao_id and o.id <> f.id
         and (o.telefone = p.telefone or o.telefone = '55' || p.telefone)
       limit 1;
      if v_outra is null then
        insert into public.clientes (salao_id, nome, telefone)
             values (f.salao_id, coalesce(nullif(btrim(p.nome), ''), 'Cliente'), p.telefone)
          returning id into v_outra;
      end if;
      update public.pedidos set cliente_id = v_outra where id = p.id;
      if p.comanda_id is not null then
        update public.comandas set cliente_id = v_outra
         where id = p.comanda_id and cliente_id = f.id;
      end if;
    end loop;
  end loop;
  return n;
end
$conserto$;
revoke all on function public.consertar_fichas_da_equipe() from public, anon, authenticated;
-- Roda uma vez agora, calado: quem cola o arquivo não precisa de uma tabela com "0".
do $roda$ begin perform public.consertar_fichas_da_equipe(); end $roda$;

-- ── 3. O ANIVERSÁRIO DO PEDIDO ──────────────────────────────────────────────
/* Chamado pelo link logo depois do fazer_pedido(), com o token que só quem
   pediu tem. Uma chamada à parte de propósito: o aniversário é opcional, e
   não pode derrubar o pedido. Só preenche ficha SEM data — a que o dono
   corrigiu, ou a que o cliente já deu, não muda. Só no dia do pedido. */
create or replace function public.aniversario_do_pedido(p_token uuid, p_nascimento date)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_cli uuid;
begin
  if p_token is null or p_nascimento is null then return false; end if;
  if p_nascimento > current_date or p_nascimento < date '1900-01-01' then
    raise exception 'Confira a data do aniversário.' using errcode = 'check_violation';
  end if;
  select q.cliente_id into v_cli from public.pedidos q
   where q.token = p_token and q.criado_em > now() - interval '1 day';
  if v_cli is null then return false; end if;
  update public.clientes set nascimento = p_nascimento
   where id = v_cli and nascimento is null;
  return found;
end $$;
revoke all on function public.aniversario_do_pedido(uuid, date) from public;
grant execute on function public.aniversario_do_pedido(uuid, date) to anon, authenticated;

-- ── 4. PERGUNTAR OU NÃO ─────────────────────────────────────────────────────
create or replace function public.cfg_pedidos(p_salao uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'aceitando', coalesce((p->>'aceitando')::boolean, true),
    'entrega',   coalesce((p->>'entrega')::boolean, true),
    'retirada',  coalesce((p->>'retirada')::boolean, true),
    'taxaPadrao', greatest(coalesce(case when p->>'taxaPadrao' ~ '^[0-9]+([.][0-9]+)?$'
                                         then (p->>'taxaPadrao')::numeric end, 0), 0),
    'taxas', coalesce((select jsonb_agg(jsonb_build_object(
                         'bairro', btrim(t->>'bairro'),
                         'taxa', greatest(coalesce(case when t->>'taxa' ~ '^[0-9]+([.][0-9]+)?$'
                                                        then (t->>'taxa')::numeric end, 0), 0)))
                         from jsonb_array_elements(case when jsonb_typeof(p->'taxas') = 'array'
                                                        then p->'taxas' else '[]'::jsonb end) t
                        where coalesce(btrim(t->>'bairro'), '') <> ''), '[]'::jsonb),
    'minimo', greatest(coalesce(case when p->>'minimo' ~ '^[0-9]+([.][0-9]+)?$'
                                     then (p->>'minimo')::numeric end, 0), 0),
    'tempo', nullif(left(btrim(coalesce(p->>'tempo', '')), 40), ''),
    'pagamentos', coalesce((select jsonb_agg(x) from jsonb_array_elements_text(
                              case when jsonb_typeof(p->'pagamentos') = 'array'
                                   then p->'pagamentos' else '[]'::jsonb end) x
                             where x in ('pix','dinheiro','debito','credito','cartao')),
                           '["pix","dinheiro","debito","credito"]'::jsonb),
    -- 81: oferecer "Pix online" no link (só vale com o Mercado Pago conectado).
    'pixOnline', coalesce(case when p->>'pixOnline' in ('true','false') then (p->>'pixOnline')::boolean end, false),
    /* 82: como o cardápio aparece no link — com as fotos (o de sempre) ou só
       a lista, como o cardápio impresso —, se cada item mostra o número, e se
       a fileira das categorias fica presa no alto enquanto se rola tudo. */
    'cardapio', jsonb_build_object(
       'estilo',  case when p->'cardapio'->>'estilo' = 'lista' then 'lista' else 'fotos' end,
       'numerar', coalesce(case when p->'cardapio'->>'numerar' in ('true','false')
                                then (p->'cardapio'->>'numerar')::boolean end, false),
       -- a fileira das categorias presa no alto, acompanhando a rolagem (ligada se não disser nada)
       'fixar',   coalesce(case when p->'cardapio'->>'fixar' in ('true','false')
                                then (p->'cardapio'->>'fixar')::boolean end, true)),
    /* 83: o tipo do estabelecimento que a cliente vê (Lanchonete, Pizzaria…).
       Só os da lista; o resto vira restaurante. Ver funcionamento.js. */
    'segmento', case when p->>'segmento' in ('restaurante','lanchonete','hamburgueria','pizzaria',
                        'acaiteria','pastelaria','padaria','cafeteria','doceria','sorveteria',
                        'marmitaria','espetaria','bar','adega','food_truck')
                     then p->>'segmento' else 'restaurante' end,
    /* 84: perguntar o aniversário no pedido do link (o cliente pode pular).
       Ligado se não disser nada. */
    'aniversario', coalesce(case when p->>'aniversario' in ('true','false')
                                 then (p->>'aniversario')::boolean end, true),
    'avisarCliente', coalesce((p->>'avisarCliente')::boolean, true),
    'avisarCasa',    coalesce((p->>'avisarCasa')::boolean, true),
    'mesas', least(greatest(coalesce(case when p->>'mesas' ~ '^[0-9]{1,3}$' then (p->>'mesas')::int end, 0), 0), 200),
    'entregadores', coalesce((select jsonb_agg(left(btrim(e), 40)) from jsonb_array_elements_text(
                       case when jsonb_typeof(p->'entregadores') = 'array' then p->'entregadores' else '[]'::jsonb end) e
                      where btrim(e) <> ''), '[]'::jsonb),
    -- 75: quanto o motoboy ganha.
    'motoboy', jsonb_build_object(
       'modo',   case when p->'motoboy'->>'modo' = 'fixo' then 'fixo' else 'taxa' end,
       'valor',  least(greatest(coalesce(case when p->'motoboy'->>'valor' ~ '^[0-9]{1,4}([.][0-9]+)?$'
                                              then (p->'motoboy'->>'valor')::numeric end, 0), 0), 1000),
       'diaria', least(greatest(coalesce(case when p->'motoboy'->>'diaria' ~ '^[0-9]{1,4}([.][0-9]+)?$'
                                              then (p->'motoboy'->>'diaria')::numeric end, 0), 0), 5000)),
    'fidelidade', jsonb_build_object(
       'ligado',   coalesce((p->'fidelidade'->>'ligado')::boolean, false),
       'pedidos',  least(greatest(coalesce(case when p->'fidelidade'->>'pedidos' ~ '^[0-9]{1,2}$'
                                                then (p->'fidelidade'->>'pedidos')::int end, 10), 2), 50),
       'desconto', least(greatest(coalesce(case when p->'fidelidade'->>'desconto' ~ '^[0-9]{1,2}([.][0-9]+)?$'
                                                then (p->'fidelidade'->>'desconto')::numeric end, 10), 1), 50)))
  from (select case when jsonb_typeof(s.cfg->'pedidos') = 'object'
                    then s.cfg->'pedidos' else '{}'::jsonb end as p
          from public.saloes s where s.id = p_salao) x
$$;

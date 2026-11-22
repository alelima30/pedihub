-- ===========================================================================
-- 71_mesas_entregadores_fidelidade.sql — o salão de verdade do restaurante
--
--   MESAS        o QR de cada mesa abre o cardápio já em "Mesa 5": sem
--                endereço, sem taxa, telefone opcional, e o pagamento pode
--                ficar "na mesa, no fim" (`na_mesa`). Ao entregar, a equipe
--                diz como foi pago (`pagamento_da_mesa`); se ninguém disser,
--                a venda entra como "não informado".
--   ENTREGADORES a lista de nomes fica na configuração dos pedidos; ao sair
--                para entrega, a equipe diz quem levou (`definir_entregador`),
--                e o acerto do período soma entregas e taxas de cada um.
--   FIDELIDADE   a cada N pedidos entregues para o mesmo WhatsApp, o próximo
--                sai com X% de desconto, sozinho. Não soma com cupom.
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

alter table public.pedidos add column if not exists mesa text;
alter table public.pedidos add column if not exists entregador text;

-- tipo_entrega ganha 'mesa' e pagamento ganha 'na_mesa': troca as travas.
do $$
declare r record;
begin
  for r in select conname, pg_get_constraintdef(oid) as d from pg_constraint
            where conrelid = 'public.pedidos'::regclass and contype = 'c' loop
    if r.d like '%tipo_entrega%' or (r.d like '%pagamento%' and r.d like '%cartao%') then
      execute format('alter table public.pedidos drop constraint %I', r.conname);
    end if;
  end loop;
end $$;
alter table public.pedidos add constraint pedidos_tipo_entrega_check
  check (tipo_entrega in ('entrega', 'retirada', 'mesa'));
-- Já com débito e crédito (72): colado de novo num banco que JÁ TEM pedido
-- no débito, uma lista sem eles é recusada pelo banco ("violated by some
-- row") e derruba a colagem inteira do 98_modulos.sql.
alter table public.pedidos add constraint pedidos_pagamento_check
  check (pagamento in ('pix', 'dinheiro', 'debito', 'credito', 'cartao', 'na_mesa'));

-- ---------------------------------------------------------------------------
-- 1) A CONFIGURAÇÃO (a do 37, com mesas, entregadores e fidelidade)
-- ---------------------------------------------------------------------------
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
                             where x in ('pix','dinheiro','cartao')),
                           '["pix","dinheiro","cartao"]'::jsonb),
    'avisarCliente', coalesce((p->>'avisarCliente')::boolean, true),
    'avisarCasa',    coalesce((p->>'avisarCasa')::boolean, true),
    -- 71: quantas mesas recebem pedido pelo QR (0 = nenhuma).
    'mesas', least(greatest(coalesce(case when p->>'mesas' ~ '^[0-9]{1,3}$' then (p->>'mesas')::int end, 0), 0), 200),
    -- 71: os entregadores da casa (só os nomes, para escolher ao sair).
    'entregadores', coalesce((select jsonb_agg(left(btrim(e), 40)) from jsonb_array_elements_text(
                       case when jsonb_typeof(p->'entregadores') = 'array' then p->'entregadores' else '[]'::jsonb end) e
                      where btrim(e) <> ''), '[]'::jsonb),
    -- 71: a cada `pedidos` entregues, `desconto` % no próximo.
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

-- ---------------------------------------------------------------------------
-- 2) O NÚCLEO DO PEDIDO (o do 70, com mesa e fidelidade)
-- ---------------------------------------------------------------------------
create or replace function public.registrar_pedido(p_salao uuid, p_pedido jsonb, p_origem text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  s          public.saloes;
  c          jsonb;
  v_nome     text;
  v_tel      text;
  v_modo     text;
  v_end      jsonb;
  v_bairro   text;
  v_taxa     numeric(10,2) := 0;
  v_pag      text;
  v_troco    numeric(10,2);
  v_obs      text;
  v_subtotal numeric(10,2) := 0;
  v_total    numeric(10,2);
  v_cliente  uuid;
  v_pedido   uuid;
  v_numero   bigint;
  v_token    uuid;
  v_ordem    smallint := 0;
  v_qtd      int;
  v_item     jsonb;
  v_calc     jsonb;
  v_linhas   jsonb := '[]'::jsonb;
  v_cod      text;
  v_cupom    jsonb;
  v_desc     numeric(10,2) := 0;
  pr         record;
  v_link     boolean := coalesce(p_origem, 'link') = 'link';
  v_mesa     text;
  v_fid      boolean := false;
  v_fcfg     jsonb;
  v_entreg   int;
  v_resg     int;
begin
  select * into s from public.saloes where id = p_salao and status = 'ativo';
  if s.id is null then
    raise exception 'Estabelecimento não encontrado.' using errcode = 'no_data_found';
  end if;
  if s.tipo <> 'restaurante' then
    raise exception 'Este estabelecimento não recebe pedidos pelo link.'
      using errcode = 'check_violation';
  end if;
  if not coalesce(public.recurso_bool(s.id, 'loja'), false) then
    raise exception 'Os pedidos pelo link não estão disponíveis para este estabelecimento agora.'
      using errcode = 'check_violation';
  end if;
  c := public.cfg_pedidos(s.id);
  if v_link and not (c->>'aceitando')::boolean then
    raise exception 'O % não está recebendo pedidos agora.', s.nome
      using errcode = 'check_violation';
  end if;
  if v_link and not public.aberto_agora(s.id) then
    raise exception 'O % está fechado agora. Os pedidos voltam quando abrir.', s.nome
      using errcode = 'check_violation';
  end if;

  v_nome := nullif(left(btrim(coalesce(p_pedido->>'nome', '')), 80), '');
  v_tel  := public.so_digitos(p_pedido->>'telefone');
  if v_nome is null then
    raise exception 'Diga o seu nome para o pedido.' using errcode = 'check_violation';
  end if;
  -- No balcão o telefone é opcional (quem pede no caixa não precisa dar).
  -- Na mesa (71) o telefone é opcional: quem pede está ali, sentado.
  if ((v_link and coalesce(p_pedido->>'entrega', '') <> 'mesa') or v_tel is not null)
     and (v_tel is null or length(v_tel) < 10 or length(v_tel) > 13) then
    raise exception 'Confira o WhatsApp: precisa do DDD.' using errcode = 'check_violation';
  end if;
  v_tel := coalesce(v_tel, '');

  v_modo := p_pedido->>'entrega';
  if v_modo not in ('entrega', 'retirada', 'mesa') or v_modo is null then
    raise exception 'Escolha entre entrega e retirada.' using errcode = 'check_violation';
  end if;
  -- A mesa (71): o número vem do QR da mesa; no link, tem de existir.
  if v_modo = 'mesa' then
    v_mesa := nullif(left(btrim(coalesce(p_pedido->>'mesa', '')), 10), '');
    if v_link and (coalesce((c->>'mesas')::int, 0) = 0
                   or v_mesa !~ '^[0-9]{1,3}$' or v_mesa::int < 1 or v_mesa::int > (c->>'mesas')::int) then
      raise exception 'Esta mesa não recebe pedido pelo link. Chame o garçom.' using errcode = 'check_violation';
    end if;
    if v_mesa is null then
      raise exception 'Diga o número da mesa.' using errcode = 'check_violation';
    end if;
  end if;
  if v_link and v_modo <> 'mesa' and not (c->>v_modo)::boolean then
    raise exception '%', case v_modo when 'entrega' then 'Este estabelecimento não faz entrega — só retirada.'
                                     else 'Este estabelecimento não faz retirada — só entrega.' end
      using errcode = 'check_violation';
  end if;

  if v_modo = 'entrega' then
    v_end := case when jsonb_typeof(p_pedido->'endereco') = 'object' then p_pedido->'endereco' else '{}'::jsonb end;
    v_end := jsonb_build_object(
      'rua',         nullif(left(btrim(coalesce(v_end->>'rua', '')), 120), ''),
      'numero',      nullif(left(btrim(coalesce(v_end->>'numero', '')), 20), ''),
      'complemento', nullif(left(btrim(coalesce(v_end->>'complemento', '')), 80), ''),
      'bairro',      nullif(left(btrim(coalesce(v_end->>'bairro', '')), 80), ''),
      'referencia',  nullif(left(btrim(coalesce(v_end->>'referencia', '')), 120), ''));
    if v_end->>'rua' is null or v_end->>'numero' is null or v_end->>'bairro' is null then
      raise exception 'Para entregar, preencha a rua, o número e o bairro.'
        using errcode = 'check_violation';
    end if;
    v_bairro := v_end->>'bairro';
    if jsonb_array_length(c->'taxas') > 0 then
      select (t->>'taxa')::numeric, t->>'bairro' into v_taxa, v_bairro
        from jsonb_array_elements(c->'taxas') t
       where public.virar_slug(t->>'bairro') = public.virar_slug(v_end->>'bairro')
       limit 1;
      if not found then
        if v_link then
          raise exception 'O % não entrega no bairro %.', s.nome, v_end->>'bairro'
            using errcode = 'check_violation';
        end if;
        v_taxa := 0;
        v_bairro := v_end->>'bairro';
      end if;
      v_end := v_end || jsonb_build_object('bairro', v_bairro);
    else
      v_taxa := (c->>'taxaPadrao')::numeric;
    end if;
    -- No balcão a taxa pode ser combinada na hora, e vale a digitada.
    if not v_link and coalesce(p_pedido->>'taxa', '') <> '' then
      if not (p_pedido->>'taxa') ~ '^[0-9]+([.,][0-9]{1,2})?$' then
        raise exception 'Confira a taxa de entrega.' using errcode = 'check_violation';
      end if;
      v_taxa := replace(p_pedido->>'taxa', ',', '.')::numeric;
    end if;
  end if;

  v_pag := p_pedido->>'pagamento';
  if v_pag is null or v_pag not in ('pix', 'dinheiro', 'cartao', 'na_mesa')
     or (v_pag = 'na_mesa' and v_modo <> 'mesa')
     or (v_link and v_pag <> 'na_mesa' and not (c->'pagamentos') ? v_pag) then
    raise exception 'Escolha como vai pagar.' using errcode = 'check_violation';
  end if;
  v_obs := nullif(left(btrim(coalesce(p_pedido->>'observacao', '')), 300), '');

  if jsonb_typeof(p_pedido->'itens') <> 'array' or jsonb_array_length(p_pedido->'itens') = 0 then
    raise exception 'O pedido está vazio.' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_pedido->'itens') > 50 then
    raise exception 'Itens demais num pedido só.' using errcode = 'check_violation';
  end if;

  if v_link and v_tel <> '' and (select count(*) from public.pedidos p
       where p.salao_id = s.id and p.telefone = v_tel and p.status = 'recebido') >= 3 then
    raise exception 'Você já tem pedidos esperando a confirmação. Aguarde ou cancele um antes de fazer outro.'
      using errcode = 'check_violation';
  end if;
  if v_link and (select count(*) from public.pedidos p
       where p.salao_id = s.id and p.criado_em > now() - interval '10 minutes') >= 60 then
    raise exception 'Muitos pedidos agora. Tente de novo em alguns minutos.'
      using errcode = 'check_violation';
  end if;

  -- O preço de cada item sai do cadastro — agora com as opções (67).
  for v_item in select value from jsonb_array_elements(p_pedido->'itens') loop
    v_qtd := case when coalesce(v_item->>'quantidade', '') ~ '^[0-9]{1,2}$'
                  then (v_item->>'quantidade')::int end;
    if v_qtd is null or v_qtd < 1 or v_qtd > 99 then
      raise exception 'Confira a quantidade dos itens.' using errcode = 'check_violation';
    end if;
    select pr2.id, pr2.nome, pr2.preco, pr2.preco_visivel into pr
      from public.produtos pr2
     where pr2.id::text = coalesce(v_item->>'produto', '') and pr2.salao_id = s.id
       and pr2.ativo and (pr2.venda_online or not v_link);
    if pr.id is null then
      raise exception 'Um dos itens saiu do cardápio. Confira o pedido.'
        using errcode = 'check_violation';
    end if;
    if v_link and not pr.preco_visivel then
      raise exception 'O item % está sem preço no cardápio e não pode ser pedido pelo link.', pr.nome
        using errcode = 'check_violation';
    end if;
    begin
      v_calc := public.preco_com_opcoes(pr.id, pr.preco, v_item->'opcoes');
    exception when check_violation then
      raise exception '%: %', pr.nome, sqlerrm using errcode = 'check_violation';
    end;
    v_subtotal := v_subtotal + (v_calc->>'preco')::numeric * v_qtd;
    v_linhas := v_linhas || jsonb_build_object(
      'produto', pr.id,
      'nome', left(pr.nome || coalesce(' — ' || nullif(v_calc->>'texto', ''), ''), 400),
      'preco', (v_calc->>'preco')::numeric, 'quantidade', v_qtd,
      'opcoes', case when jsonb_array_length(v_calc->'opcoes') > 0 then v_calc->'opcoes' end,
      'observacao', nullif(left(btrim(coalesce(v_item->>'observacao', '')), 160), ''));
  end loop;

  if v_link and v_modo <> 'mesa' and v_subtotal < (c->>'minimo')::numeric then
    raise exception 'O pedido mínimo é de %.', public.reais((c->>'minimo')::numeric)
      using errcode = 'check_violation';
  end if;
  /* O cupom (68): sobre o subtotal dos itens, nunca sobre a entrega. O
     mínimo do pedido é conferido ANTES do desconto, como em todo delivery. */
  v_cod := nullif(upper(regexp_replace(coalesce(p_pedido->>'cupom', ''), '\s', '', 'g')), '');
  if v_cod is not null then
    v_cupom := public.cupom_do_pedido(s.id, v_cod, v_subtotal, v_tel, true);
    if v_cupom->>'motivo' is not null then
      raise exception '%', v_cupom->>'motivo' using errcode = 'check_violation';
    end if;
    v_desc := least((v_cupom->>'desconto')::numeric, v_subtotal);
  end if;
  /* A FIDELIDADE (71): a cada N pedidos entregues para o mesmo WhatsApp, o
     próximo sai com o desconto — sozinho, sem código. Não soma com cupom:
     quem digitou um cupom fica com ele, e a fidelidade espera o próximo. */
  v_fcfg := c->'fidelidade';
  if v_cupom is null and v_tel <> '' and coalesce((v_fcfg->>'ligado')::boolean, false) then
    select count(*) filter (where p.status = 'entregue'),
           count(*) filter (where p.cupom_codigo = 'FIDELIDADE' and p.status <> 'cancelado')
      into v_entreg, v_resg
      from public.pedidos p where p.salao_id = s.id and p.telefone = v_tel;
    if v_entreg / greatest((v_fcfg->>'pedidos')::int, 1) > v_resg then
      v_desc := round(v_subtotal * (v_fcfg->>'desconto')::numeric / 100, 2);
      v_fid := true;
    end if;
  end if;
  v_total := v_subtotal - v_desc + v_taxa;

  if v_pag = 'dinheiro' and coalesce(p_pedido->>'troco', '') <> '' then
    if not (p_pedido->>'troco') ~ '^[0-9]+([.,][0-9]{1,2})?$' then
      raise exception 'Confira o valor do troco.' using errcode = 'check_violation';
    end if;
    v_troco := replace(p_pedido->>'troco', ',', '.')::numeric;
    if v_troco < v_total then
      raise exception 'O troco precisa ser para um valor maior que o total (%).', public.reais(v_total)
        using errcode = 'check_violation';
    end if;
  end if;

  if v_tel <> '' then
    begin
      v_cliente := public.ficha_do_cliente(s.id, v_nome, v_tel);
    exception when others then
      v_cliente := null;
    end;
  end if;

  v_numero := public.proximo_numero(s.id, 'pedido');
  insert into public.pedidos
    (salao_id, numero, cliente_id, nome, telefone, tipo_entrega, endereco, bairro,
     subtotal, taxa_entrega, total, pagamento, troco_para, observacao, cupom_codigo, desconto,
     origem, status, aceito_em, mesa)
  values (s.id, v_numero, v_cliente, v_nome, v_tel, v_modo,
          case when v_modo = 'entrega' then v_end end,
          case when v_modo = 'entrega' then v_bairro end,
          v_subtotal, v_taxa, v_total, v_pag, v_troco, v_obs,
          case when v_cupom is not null then v_cupom->>'codigo' when v_fid then 'FIDELIDADE' end, v_desc,
          coalesce(p_origem, 'link'),
          case when v_link then 'recebido' else 'em_preparo' end,
          case when v_link then null else now() end,
          case when v_modo = 'mesa' then v_mesa end)
  returning id, token into v_pedido, v_token;

  if v_cupom is not null then
    insert into public.cupom_usos (cupom_id, salao_id, origem, telefone, desconto, pedido_id)
         values ((v_cupom->>'cupom_id')::uuid, s.id, 'produtos',
                 nullif(public.telefone_nacional(nullif(v_tel, '')), ''), v_desc, v_pedido);
  end if;

  for v_item in select value from jsonb_array_elements(v_linhas) loop
    v_ordem := v_ordem + 1;
    insert into public.pedido_itens (pedido_id, produto_id, nome, preco, quantidade, observacao, ordem, opcoes)
    values (v_pedido, (v_item->>'produto')::uuid, v_item->>'nome', (v_item->>'preco')::numeric,
            (v_item->>'quantidade')::int, v_item->>'observacao', v_ordem,
            case when jsonb_typeof(v_item->'opcoes') = 'array' then v_item->'opcoes' end);
  end loop;

  if v_link and (c->>'avisarCasa')::boolean then
    perform public.enfileirar_pedido(v_pedido, 'pedido_novo', coalesce(s.whatsapp, s.telefone));
  end if;

  return jsonb_build_object('numero', v_numero, 'token', v_token,
                            'subtotal', v_subtotal, 'desconto', v_desc, 'taxa', v_taxa, 'total', v_total,
                            'fidelidade', v_fid,
                            'status', case when v_link then 'recebido' else 'em_preparo' end);
end $$;



create or replace function public.pedido_vira_venda(p_pedido uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  p       public.pedidos%rowtype;
  v_cli   uuid;
  v_com   uuid;
  v_total numeric;
begin
  select * into p from public.pedidos where id = p_pedido for update;
  if p.id is null or p.status <> 'entregue' or p.comanda_id is not null then
    return p.comanda_id;
  end if;

  -- A comanda pede uma ficha. A do pedido, ou a que der para achar/criar agora.
  v_cli := p.cliente_id;
  if v_cli is null then
    begin
      v_cli := public.ficha_do_cliente(p.salao_id, p.nome, p.telefone);
    exception when others then
      v_cli := null;
    end;
  end if;
  -- Pedido de balcão sem telefone: a ficha "Cliente do balcão" da casa.
  if v_cli is null and coalesce(p.telefone, '') = '' then
    v_cli := public.ficha_do_balcao(p.salao_id);
  end if;
  if v_cli is null then
    update public.pedidos
       set venda_erro = 'Não deu para criar a ficha do cliente; a venda não entrou no caixa.'
     where id = p.id;
    return null;
  end if;

  insert into public.comandas (salao_id, cliente_id, status, acrescimo, desconto, desconto_motivo)
       values (p.salao_id, v_cli, 'aberta', coalesce(p.taxa_entrega, 0), coalesce(p.desconto, 0),
               case when coalesce(p.desconto, 0) > 0 then 'Cupom ' || coalesce(p.cupom_codigo, '') end)
    returning id into v_com;

  insert into public.comanda_itens (comanda_id, tipo, produto_id, descricao, qtd, preco_unit)
  select v_com, 'produto', i.produto_id, i.nome, i.quantidade, i.preco
    from public.pedido_itens i
   where i.pedido_id = p.id
   order by i.ordem;

  select t.total into v_total from public.comandas_totais t where t.id = v_com;
  if coalesce(v_total, 0) > 0 then
    insert into public.pagamentos (comanda_id, forma, valor)
         values (v_com, case p.pagamento when 'cartao' then 'credito' when 'na_mesa' then 'nao_informado'
                                 else p.pagamento end,
                 round(v_total, 2));
  end if;
  update public.comandas set status = 'fechada', fechada_em = coalesce(p.entregue_em, now())
   where id = v_com;

  update public.pedidos
     set comanda_id = v_com, venda_erro = null,
         cliente_id = coalesce(cliente_id, v_cli)
   where id = p.id;
  return v_com;
end $$;


-- ---------------------------------------------------------------------------
-- 3) O QUE A EQUIPE FAZ: QUEM LEVOU, E COMO A MESA PAGOU
-- ---------------------------------------------------------------------------
create or replace function public.definir_entregador(p_pedido uuid, p_nome text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  select * into v from public.pedidos where id = p_pedido;
  if v.id is null or not public.e_equipe(v.salao_id) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  if v.tipo_entrega <> 'entrega' then
    raise exception 'Só pedido de entrega tem entregador.' using errcode = 'check_violation';
  end if;
  update public.pedidos set entregador = nullif(left(btrim(coalesce(p_nome, '')), 40), '') where id = v.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.pagamento_da_mesa(p_pedido uuid, p_forma text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.pedidos;
begin
  select * into v from public.pedidos where id = p_pedido for update;
  if v.id is null or not public.e_equipe(v.salao_id) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  if v.pagamento <> 'na_mesa' or v.status in ('entregue', 'cancelado') then
    raise exception 'Este pedido já tem a forma de pagamento.' using errcode = 'check_violation';
  end if;
  if p_forma not in ('pix', 'dinheiro', 'cartao') then
    raise exception 'Escolha Pix, dinheiro ou cartão.' using errcode = 'check_violation';
  end if;
  update public.pedidos set pagamento = p_forma where id = v.id;
  return jsonb_build_object('ok', true);
end $$;

/* O acerto dos entregadores: quantas entregas e quanto de taxa, por pessoa,
   no período (pela data da entrega, no horário do restaurante). */
create or replace function public.acerto_entregadores(p_salao uuid, p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_fuso text;
begin
  if not public.ve_agenda_toda(p_salao) then
    raise exception 'Só o balcão e a gestão veem o acerto.' using errcode = 'insufficient_privilege';
  end if;
  select coalesce(fuso, 'America/Sao_Paulo') into v_fuso from public.saloes where id = p_salao;
  return coalesce((
    select jsonb_agg(jsonb_build_object('entregador', x.quem, 'entregas', x.n, 'taxas', x.taxas,
                                        'total', x.total) order by x.n desc, x.quem)
      from (select coalesce(p.entregador, 'Sem entregador') as quem, count(*) as n,
                   coalesce(sum(p.taxa_entrega), 0) as taxas, coalesce(sum(p.total), 0) as total
              from public.pedidos p
             where p.salao_id = p_salao and p.status = 'entregue' and p.tipo_entrega = 'entrega'
               and (p.entregue_em at time zone v_fuso)::date between p_de and p_ate
             group by 1) x), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 4) O QUE A CLIENTE E O PAINEL LEEM
-- ---------------------------------------------------------------------------
create or replace function public.pecas_pedido(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'nome',    split_part(btrim(p.nome), ' ', 1),
    'empresa', s.nome,
    'numero',  p.numero::text,
    'total',   public.reais(p.total),
    'tempo',   coalesce(public.cfg_pedidos(p.salao_id)->>'tempo', 'em breve'),
    'modo',    case when p.tipo_entrega = 'entrega'
                    then 'entrega' || coalesce(' no bairro ' || nullif(btrim(p.bairro), ''), '')
                    when p.tipo_entrega = 'mesa' then 'na mesa ' || coalesce(p.mesa, '')
                    else 'retirada no balcão' end,
    'motivo',  coalesce(nullif(btrim(p.motivo), ''), 'não informado'),
    'itens',   (select count(*) from public.pedido_itens i where i.pedido_id = p.id))
  from public.pedidos p join public.saloes s on s.id = p.salao_id
  where p.id = p_pedido
$$;

create or replace function public.meu_pedido(p_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'numero', p.numero, 'status', p.status, 'criado_em', p.criado_em,
    'entrega', p.tipo_entrega, 'bairro', p.bairro,
    'subtotal', p.subtotal, 'taxa', p.taxa_entrega, 'total', p.total,
    'desconto', p.desconto, 'cupom', p.cupom_codigo, 'mesa', p.mesa,
    'fidelidade', case when coalesce((public.cfg_pedidos(s.id)->'fidelidade'->>'ligado')::boolean, false)
                        and coalesce(p.telefone, '') <> '' then (
      select jsonb_build_object(
               'pedidos', (f->>'pedidos')::int, 'desconto', (f->>'desconto')::numeric,
               'faltam', (f->>'pedidos')::int - (x.entregues % (f->>'pedidos')::int),
               'temDesconto', x.entregues / (f->>'pedidos')::int > x.resgates)
        from (select public.cfg_pedidos(s.id)->'fidelidade' as f) ff,
             lateral (select count(*) filter (where q.status = 'entregue') as entregues,
                             count(*) filter (where q.cupom_codigo = 'FIDELIDADE' and q.status <> 'cancelado') as resgates
                        from public.pedidos q where q.salao_id = s.id and q.telefone = p.telefone) x) end,
    'pagamento', p.pagamento, 'troco', p.troco_para, 'motivo', p.motivo,
    'cancelado_por', p.cancelado_por,
    'itens', (select coalesce(jsonb_agg(jsonb_build_object(
                'nome', i.nome, 'quantidade', i.quantidade, 'preco', i.preco,
                'observacao', i.observacao) order by i.ordem), '[]'::jsonb)
                from public.pedido_itens i where i.pedido_id = p.id),
    'casa', s.nome, 'slug', s.slug, 'whatsapp', coalesce(s.whatsapp, s.telefone),
    'tempo', public.cfg_pedidos(s.id)->>'tempo')
  from public.pedidos p join public.saloes s on s.id = p.salao_id
  where p.token = p_token
$$;

create or replace function public.pedidos_da_casa(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.saloes; c jsonb;
begin
  select * into s from public.saloes where slug = p_slug and status = 'ativo';
  if s.id is null then return jsonb_build_object('ligado', false); end if;
  c := public.cfg_pedidos(s.id);
  -- 71: os nomes dos entregadores não saem para a página pública.
  return (c - 'entregadores') || jsonb_build_object(
    'ligado', s.tipo = 'restaurante' and coalesce(public.recurso_bool(s.id, 'loja'), false),
    'aberto', (c->>'aceitando')::boolean and public.aberto_agora(s.id),
    -- No restaurante a agenda só aparece se o dono LIGOU os serviços à mão
    -- (uma reserva de mesa, um rodízio com hora marcada).
    'servicosTambem', coalesce(s.cfg->>'usaServicos', '') = 'true');
end $$;

create or replace function public.pedidos_da_loja(p_salao uuid, p_horas int default 24)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.'
      using errcode = 'insufficient_privilege';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', p.id, 'numero', p.numero, 'status', p.status,
             'nome', p.nome, 'telefone', p.telefone, 'entrega', p.tipo_entrega,
             'endereco', p.endereco, 'bairro', p.bairro,
             'subtotal', p.subtotal, 'taxa', p.taxa_entrega, 'total', p.total,
             'desconto', p.desconto, 'cupom', p.cupom_codigo, 'vendaErro', p.venda_erro,
             'origem', p.origem, 'mesa', p.mesa, 'entregador', p.entregador,
             'pagamento', p.pagamento, 'troco', p.troco_para,
             'observacao', p.observacao, 'motivo', p.motivo,
             'cancelado_por', p.cancelado_por,
             'criado_em', p.criado_em, 'aceito_em', p.aceito_em,
             'saiu_em', p.saiu_em, 'pronto_em', p.pronto_em,
             'entregue_em', p.entregue_em, 'cancelado_em', p.cancelado_em,
             'itens', (select coalesce(jsonb_agg(jsonb_build_object(
                         'nome', i.nome, 'quantidade', i.quantidade, 'preco', i.preco,
                         'observacao', i.observacao) order by i.ordem), '[]'::jsonb)
                         from public.pedido_itens i where i.pedido_id = p.id))
           order by p.criado_em desc)
      from public.pedidos p
     where p.salao_id = p_salao
       and (p.status not in ('entregue', 'cancelado')
            or p.criado_em > now() - make_interval(hours => greatest(1, least(coalesce(p_horas, 24), 24 * 31))))
  ), '[]'::jsonb);
end $$;



revoke all on function public.cfg_pedidos(uuid) from public, anon, authenticated;
revoke all on function public.registrar_pedido(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.pedido_vira_venda(uuid) from public, anon, authenticated;
revoke all on function public.pecas_pedido(uuid) from public, anon, authenticated;
revoke all on function public.meu_pedido(uuid) from public;
grant execute on function public.meu_pedido(uuid) to anon, authenticated;
revoke all on function public.pedidos_da_loja(uuid, int) from public, anon;
grant execute on function public.pedidos_da_loja(uuid, int) to authenticated;
revoke all on function public.definir_entregador(uuid, text) from public, anon;
grant execute on function public.definir_entregador(uuid, text) to authenticated;
revoke all on function public.pagamento_da_mesa(uuid, text) from public, anon;
grant execute on function public.pagamento_da_mesa(uuid, text) to authenticated;
revoke all on function public.acerto_entregadores(uuid, date, date) from public, anon;
grant execute on function public.acerto_entregadores(uuid, date, date) to authenticated;
revoke all on function public.pedidos_da_casa(text) from public;
grant execute on function public.pedidos_da_casa(text) to anon, authenticated;

-- ===========================================================================
-- PediHub — o cartão fidelidade reconhece a cliente pelo celular (78)
--
-- A fidelidade conta os pedidos ENTREGUES do mesmo celular, naquele
-- restaurante, sem login. Só que o celular era comparado como foi digitado:
-- "(51) 99999-8888" e "+55 51 99999-8888" viravam duas pessoas, e quem pediu
-- uma vez digitando e outra com o preenchimento automático do celular via o
-- cartão recomeçar do zero. O mesmo valia para a trava de "3 pedidos ainda
-- não aceitos" do mesmo número.
--
-- Agora o pedido grava o celular sempre no formato nacional (sem o 55), o
-- mesmo da ficha da cliente (05) e do cupom (68), e os pedidos antigos são
-- acertados uma vez. O WhatsApp e o link do entregador já põem o 55 na hora
-- de chamar (telefone55, enviar-notificacoes).
-- ===========================================================================

-- 1) O núcleo do pedido (o do 72), com o celular no formato nacional.
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
  /* (78) O MESMO CELULAR É A MESMA PESSOA. Gravado sempre sem o 55 na frente,
     como a ficha da cliente (05) e o cupom (68). Antes, "(51) 99999-8888" e
     "+55 51 99999-8888" — o celular preenche sozinho no formato internacional
     — contavam como duas clientes: o cartão fidelidade recomeçava do zero. */
  v_tel  := public.telefone_nacional(p_pedido->>'telefone');
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
  if v_pag is null or v_pag not in ('pix', 'dinheiro', 'debito', 'credito', 'cartao', 'na_mesa')
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

-- 2) Os pedidos que já existem: o mesmo formato, para a conta casar.
--    (Nenhum gatilho olha a troca do telefone: o 65 só olha o status.)
update public.pedidos
   set telefone = public.telefone_nacional(telefone)
 where telefone ~ '^55[0-9]{10,11}$';

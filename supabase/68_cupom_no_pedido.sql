-- ===========================================================================
-- 68_cupom_no_pedido.sql — o cupom de desconto no pedido do restaurante
--
-- O cupom (34_cupons) nasceu para o agendamento e a loja do salão, e calcula
-- o desconto sobre o preço do CADASTRO do produto. No pedido do restaurante
-- o item tem complementos (67): a pizza de base R$ 0 custa R$ 88 com os
-- sabores. Então o cupom do pedido vale sobre o SUBTOTAL que o banco
-- calculou, com as mesmas regras do cupom de sempre — ativo, validade,
-- limite de usos, um por cliente (pelo WhatsApp) — e nunca sobre a taxa de
-- entrega.
--
--   · pedidos ganha `cupom_codigo` e `desconto`; total = subtotal − desconto
--     + entrega; o mínimo do pedido conta ANTES do desconto;
--   · o uso fica em `cupom_usos` com o pedido; pedido CANCELADO devolve o uso
--     (não conta no limite nem no "um por cliente");
--   · a venda (65) leva o desconto para a comanda — caixa e relatórios batem;
--   · no PediHub todo cupom vale para pedido: o gatilho marca vale_produtos.
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

alter table public.pedidos add column if not exists cupom_codigo text;
alter table public.pedidos add column if not exists desconto numeric(10,2) not null default 0
  check (desconto >= 0);
alter table public.cupom_usos add column if not exists pedido_id uuid
  references public.pedidos(id) on delete cascade;

/* No PediHub o cupom é de pedido. Quem cria pelo painel nem vê a escolha. */
create or replace function public.cupom_vale_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.vale_produtos := true;
  return new;
end $$;
drop trigger if exists cupom_vale_pedido on public.cupons;
create trigger cupom_vale_pedido before insert or update on public.cupons
  for each row execute function public.cupom_vale_pedido();
update public.cupons set vale_produtos = true where not vale_produtos;

-- ---------------------------------------------------------------------------
-- 1) A CONTA DO CUPOM NO PEDIDO
--    p_tel nulo = prévia (não pergunta "esse número já usou?", que seria uma
--    porta para descobrir quem é cliente de quem).
-- ---------------------------------------------------------------------------
create or replace function public.cupom_do_pedido(
  p_salao uuid, p_codigo text, p_subtotal numeric, p_tel text, p_travar boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c      public.cupons%rowtype;
  v_cod  text := upper(regexp_replace(coalesce(p_codigo, ''), '\s', '', 'g'));
  v_tel  text := nullif(public.telefone_nacional(p_tel), '');
  v_hoje date;
  v_usos int;
  v_desc numeric(10,2);
begin
  if not coalesce(public.recurso_bool(p_salao, 'cupons'), false) then
    return jsonb_build_object('motivo', 'Este restaurante não está aceitando cupons agora.');
  end if;
  if v_cod = '' then
    return jsonb_build_object('motivo', 'Digite o código do cupom.');
  end if;
  select * into c from public.cupons x where x.salao_id = p_salao and x.codigo = v_cod and x.ativo;
  if not found then
    return jsonb_build_object('motivo', 'Cupom não encontrado. Confira as letras e os números.');
  end if;
  if p_travar then perform 1 from public.cupons x where x.id = c.id for update; end if;

  select (now() at time zone coalesce(s.fuso, 'America/Sao_Paulo'))::date into v_hoje
    from public.saloes s where s.id = p_salao;
  if c.inicio is not null and v_hoje < c.inicio then
    return jsonb_build_object('motivo', 'Este cupom começa a valer em ' || to_char(c.inicio, 'DD/MM/YYYY') || '.');
  end if;
  if c.fim is not null and v_hoje > c.fim then
    return jsonb_build_object('motivo', 'Este cupom venceu em ' || to_char(c.fim, 'DD/MM/YYYY') || '.');
  end if;

  -- Os usos que contam: os de pedido não cancelado (e os antigos, sem pedido).
  if c.limite_total is not null then
    select count(*) into v_usos from public.cupom_usos u
      left join public.pedidos pe on pe.id = u.pedido_id
     where u.cupom_id = c.id and (u.pedido_id is null or pe.status <> 'cancelado');
    if v_usos >= c.limite_total then
      return jsonb_build_object('motivo', 'Este cupom já foi usado o máximo de vezes.');
    end if;
  end if;
  if c.um_por_cliente and v_tel is not null and exists (
       select 1 from public.cupom_usos u left join public.pedidos pe on pe.id = u.pedido_id
        where u.cupom_id = c.id and u.telefone = v_tel
          and (u.pedido_id is null or pe.status <> 'cancelado')) then
    return jsonb_build_object('motivo', 'Você já usou este cupom.');
  end if;

  if coalesce(p_subtotal, 0) <= 0 then
    return jsonb_build_object('motivo', 'Escolha os itens antes de usar o cupom.');
  end if;
  v_desc := case when c.tipo = 'pct' then round(p_subtotal * c.valor / 100, 2)
                 else least(c.valor, p_subtotal) end;
  return jsonb_build_object('cupom_id', c.id, 'codigo', c.codigo, 'desconto', v_desc,
    'rotulo', case when c.tipo = 'pct'
                then replace(trim(trailing '.' from trim(trailing '0' from c.valor::text)), '.', ',') || '%'
                else 'R$ ' || replace(to_char(c.valor, 'FM999999990.00'), '.', ',') end,
    'motivo', null);
end $$;

-- A prévia, para o link: pelo apelido, sem telefone, e sem o id do cupom.
create or replace function public.cupom_do_pedido_previa(p_slug text, p_codigo text, p_subtotal numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_salao uuid; r jsonb;
begin
  select id into v_salao from public.saloes where slug = p_slug and status = 'ativo';
  if v_salao is null then return jsonb_build_object('motivo', 'Estabelecimento não encontrado.'); end if;
  r := public.cupom_do_pedido(v_salao, p_codigo, p_subtotal, null, false);
  return r - 'cupom_id';
end $$;

/* O link pergunta se vale mostrar o campo "Tem cupom?". */
create or replace function public.casa_tem_cupom(p_slug text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.recurso_bool(s.id, 'cupons'), false) and exists (
           select 1 from public.cupons c
            where c.salao_id = s.id and c.ativo
              and (c.fim is null or c.fim >= (now() at time zone coalesce(s.fuso, 'America/Sao_Paulo'))::date))
    from public.saloes s where s.slug = p_slug and s.status = 'ativo'
$$;

-- ---------------------------------------------------------------------------
-- 2) A VENDA LEVA O DESCONTO (a função do 65, com a linha do desconto)
-- ---------------------------------------------------------------------------
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
         values (v_com, case p.pagamento when 'cartao' then 'credito' else p.pagamento end,
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
-- 3) FAZER O PEDIDO — o do 37, com as opções de cada item (67) e o cupom
-- ---------------------------------------------------------------------------
create or replace function public.fazer_pedido(p_slug text, p_pedido jsonb)
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
begin
  select * into s from public.saloes where slug = p_slug and status = 'ativo';
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
  if not (c->>'aceitando')::boolean then
    raise exception 'O % não está recebendo pedidos agora.', s.nome
      using errcode = 'check_violation';
  end if;
  if not public.aberto_agora(s.id) then
    raise exception 'O % está fechado agora. Os pedidos voltam quando abrir.', s.nome
      using errcode = 'check_violation';
  end if;

  v_nome := nullif(left(btrim(coalesce(p_pedido->>'nome', '')), 80), '');
  v_tel  := public.so_digitos(p_pedido->>'telefone');
  if v_nome is null then
    raise exception 'Diga o seu nome para o pedido.' using errcode = 'check_violation';
  end if;
  if v_tel is null or length(v_tel) < 10 or length(v_tel) > 13 then
    raise exception 'Confira o WhatsApp: precisa do DDD.' using errcode = 'check_violation';
  end if;

  v_modo := p_pedido->>'entrega';
  if v_modo not in ('entrega', 'retirada') or v_modo is null then
    raise exception 'Escolha entre entrega e retirada.' using errcode = 'check_violation';
  end if;
  if not (c->>v_modo)::boolean then
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
        raise exception 'O % não entrega no bairro %.', s.nome, v_end->>'bairro'
          using errcode = 'check_violation';
      end if;
      v_end := v_end || jsonb_build_object('bairro', v_bairro);
    else
      v_taxa := (c->>'taxaPadrao')::numeric;
    end if;
  end if;

  v_pag := p_pedido->>'pagamento';
  if v_pag is null or not (c->'pagamentos') ? v_pag then
    raise exception 'Escolha como vai pagar.' using errcode = 'check_violation';
  end if;
  v_obs := nullif(left(btrim(coalesce(p_pedido->>'observacao', '')), 300), '');

  if jsonb_typeof(p_pedido->'itens') <> 'array' or jsonb_array_length(p_pedido->'itens') = 0 then
    raise exception 'O pedido está vazio.' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_pedido->'itens') > 50 then
    raise exception 'Itens demais num pedido só.' using errcode = 'check_violation';
  end if;

  if (select count(*) from public.pedidos p
       where p.salao_id = s.id and p.telefone = v_tel and p.status = 'recebido') >= 3 then
    raise exception 'Você já tem pedidos esperando a confirmação. Aguarde ou cancele um antes de fazer outro.'
      using errcode = 'check_violation';
  end if;
  if (select count(*) from public.pedidos p
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
       and pr2.ativo and pr2.venda_online;
    if pr.id is null then
      raise exception 'Um dos itens saiu do cardápio. Confira o pedido.'
        using errcode = 'check_violation';
    end if;
    if not pr.preco_visivel then
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

  if v_subtotal < (c->>'minimo')::numeric then
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

  begin
    v_cliente := public.ficha_do_cliente(s.id, v_nome, v_tel);
  exception when others then
    v_cliente := null;
  end;

  v_numero := public.proximo_numero(s.id, 'pedido');
  insert into public.pedidos
    (salao_id, numero, cliente_id, nome, telefone, tipo_entrega, endereco, bairro,
     subtotal, taxa_entrega, total, pagamento, troco_para, observacao, cupom_codigo, desconto)
  values (s.id, v_numero, v_cliente, v_nome, v_tel, v_modo,
          case when v_modo = 'entrega' then v_end end,
          case when v_modo = 'entrega' then v_bairro end,
          v_subtotal, v_taxa, v_total, v_pag, v_troco, v_obs,
          case when v_cupom is not null then v_cupom->>'codigo' end, v_desc)
  returning id, token into v_pedido, v_token;

  if v_cupom is not null then
    insert into public.cupom_usos (cupom_id, salao_id, origem, telefone, desconto, pedido_id)
         values ((v_cupom->>'cupom_id')::uuid, s.id, 'produtos',
                 nullif(public.telefone_nacional(v_tel), ''), v_desc, v_pedido);
  end if;

  for v_item in select value from jsonb_array_elements(v_linhas) loop
    v_ordem := v_ordem + 1;
    insert into public.pedido_itens (pedido_id, produto_id, nome, preco, quantidade, observacao, ordem, opcoes)
    values (v_pedido, (v_item->>'produto')::uuid, v_item->>'nome', (v_item->>'preco')::numeric,
            (v_item->>'quantidade')::int, v_item->>'observacao', v_ordem,
            case when jsonb_typeof(v_item->'opcoes') = 'array' then v_item->'opcoes' end);
  end loop;

  if (c->>'avisarCasa')::boolean then
    perform public.enfileirar_pedido(v_pedido, 'pedido_novo', coalesce(s.whatsapp, s.telefone));
  end if;

  return jsonb_build_object('numero', v_numero, 'token', v_token,
                            'subtotal', v_subtotal, 'desconto', v_desc, 'taxa', v_taxa, 'total', v_total,
                            'status', 'recebido');
end $$;


-- ---------------------------------------------------------------------------
-- 4) O PAINEL VÊ O CUPOM (a lista do 37, com o desconto)
-- ---------------------------------------------------------------------------
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

revoke all on function public.cupom_do_pedido(uuid, text, numeric, text, boolean) from public, anon, authenticated;
revoke all on function public.cupom_do_pedido_previa(text, text, numeric) from public;
grant execute on function public.cupom_do_pedido_previa(text, text, numeric) to anon, authenticated;
revoke all on function public.casa_tem_cupom(text) from public;
grant execute on function public.casa_tem_cupom(text) to anon, authenticated;
revoke all on function public.pedido_vira_venda(uuid) from public, anon, authenticated;
revoke all on function public.fazer_pedido(text, jsonb) from public;
grant execute on function public.fazer_pedido(text, jsonb) to anon, authenticated;
revoke all on function public.pedidos_da_loja(uuid, int) from public, anon;
grant execute on function public.pedidos_da_loja(uuid, int) to authenticated;

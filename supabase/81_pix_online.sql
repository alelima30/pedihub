-- ===========================================================================
-- PediHub — Pix online no link, na conta do restaurante (81)
--
-- O restaurante conecta a conta DELE do Mercado Pago (botão "Conectar", o
-- OAuth do Mercado Pago: login e "Autorizar", sem copiar chave). A cliente
-- escolhe "Pix online", recebe o QR e o copia-e-cola, paga, e o pedido chega
-- na cozinha já PAGO. O dinheiro cai na conta do restaurante, não passa pelo
-- PediHub.
--
--   * o pedido nasce 'aguardando_pagamento': fora da tela de Pedidos, sem
--     sino, sem aviso no celular e sem WhatsApp para o restaurante;
--   * quando o Pix cai, `pix_confirmar` (só o servidor) passa a 'recebido',
--     grava `pago_em`, e AÍ o restaurante é avisado;
--   * 30 minutos sem pagar, o pedido é cancelado ("o Pix não foi pago");
--   * as credenciais do Mercado Pago ficam em `mp_contas`, que ninguém lê
--     além do servidor (RLS ligado, sem policy, sem grant).
--
-- O Pix é gravado como pagamento 'pix' com `pago_online` — o caixa, a venda e
-- os relatórios continuam vendo um Pix, como sempre.
-- ===========================================================================

-- ── As contas do Mercado Pago dos restaurantes ─────────────────────────────
create table if not exists public.mp_contas (
  salao_id      uuid primary key references public.saloes(id) on delete cascade,
  mp_user_id    text not null,
  access_token  text not null,
  refresh_token text,
  public_key    text,
  expira_em     timestamptz,
  conectado_em  timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
alter table public.mp_contas enable row level security;
revoke all on public.mp_contas from public, anon, authenticated;

-- O "state" do OAuth: amarra a volta do Mercado Pago ao restaurante que
-- pediu, e vale 15 minutos.
create table if not exists public.mp_conexoes (
  estado     text primary key,
  salao_id   uuid not null references public.saloes(id) on delete cascade,
  perfil_id  uuid,
  criado_em  timestamptz not null default now()
);
alter table public.mp_conexoes enable row level security;
revoke all on public.mp_conexoes from public, anon, authenticated;

-- ── O pedido pago online ───────────────────────────────────────────────────
alter table public.pedidos add column if not exists pago_online boolean not null default false;
alter table public.pedidos add column if not exists pago_em timestamptz;
alter table public.pedidos add column if not exists mp_pagamento_id text;
alter table public.pedidos add column if not exists pix_copia_cola text;
alter table public.pedidos add column if not exists pix_qr text;   -- a imagem do QR (PNG em base64) que o Mercado Pago devolve
alter table public.pedidos add column if not exists pix_expira_em timestamptz;

-- O status novo. A trava do 37 nasceu inline (nome automático): troca pela
-- mesma lista com 'aguardando_pagamento'.
do $$
declare r record;
begin
  for r in select conname from pg_constraint
            where conrelid = 'public.pedidos'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%em_preparo%' loop
    execute format('alter table public.pedidos drop constraint %I', r.conname);
  end loop;
end $$;
alter table public.pedidos add constraint pedidos_status_check
  check (status in ('aguardando_pagamento', 'recebido', 'em_preparo', 'saiu', 'pronto', 'entregue', 'cancelado'));

-- ── 1) A configuração (a do 75), com a opção de Pix online ─────────────────
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

-- ── 2) O núcleo do pedido (o do 79), com o Pix online ──────────────────────
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
  v_online   boolean := false;   -- 81: Pix online, pago antes de ir para a cozinha
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
  /* (81) PIX ONLINE: só pelo link, fora da mesa, e só com o Mercado Pago do
     restaurante conectado e a opção ligada. Grava como 'pix' (o caixa e a
     venda já sabem lidar) e marca `pago_online`; o pedido nasce esperando o
     pagamento e só vai para a cozinha quando o Pix cair. */
  if v_pag = 'pix_online' then
    if not v_link or v_modo = 'mesa' then
      raise exception 'O Pix online é só para pedidos pelo link.' using errcode = 'check_violation';
    end if;
    if not coalesce((c->>'pixOnline')::boolean, false)
       or not exists (select 1 from public.mp_contas m where m.salao_id = s.id) then
      raise exception 'Este restaurante não está recebendo Pix online agora. Escolha outra forma de pagamento.'
        using errcode = 'check_violation';
    end if;
    v_pag := 'pix'; v_online := true;
  end if;
  if v_pag is null or v_pag not in ('pix', 'dinheiro', 'debito', 'credito', 'cartao', 'na_mesa')
     or (v_pag = 'na_mesa' and v_modo <> 'mesa')
     or (v_link and not v_online and v_pag <> 'na_mesa' and not (c->'pagamentos') ? v_pag) then
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
       where p.salao_id = s.id and p.telefone = v_tel and p.status in ('recebido', 'aguardando_pagamento')) >= 3 then
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
    -- (79) O preço que vale HOJE: o da promoção, se houver uma no prazo.
    select pr2.id, pr2.nome,
           public.preco_vigente(pr2.preco, pr2.preco_promo, pr2.promo_ate, s.fuso) as preco,
           pr2.preco_visivel into pr
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
     origem, status, aceito_em, mesa, pago_online, pix_expira_em)
  values (s.id, v_numero, v_cliente, v_nome, v_tel, v_modo,
          case when v_modo = 'entrega' then v_end end,
          case when v_modo = 'entrega' then v_bairro end,
          v_subtotal, v_taxa, v_total, v_pag, v_troco, v_obs,
          case when v_cupom is not null then v_cupom->>'codigo' when v_fid then 'FIDELIDADE' end, v_desc,
          coalesce(p_origem, 'link'),
          case when v_online then 'aguardando_pagamento' when v_link then 'recebido' else 'em_preparo' end,
          case when v_link then null else now() end,
          case when v_modo = 'mesa' then v_mesa end,
          v_online, case when v_online then now() + interval '30 minutes' end)
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

  -- (81) O Pix online só avisa o restaurante quando o pagamento cai (pix_confirmar).
  if v_link and not v_online and (c->>'avisarCasa')::boolean then
    perform public.enfileirar_pedido(v_pedido, 'pedido_novo', coalesce(s.whatsapp, s.telefone));
  end if;

  return jsonb_build_object('numero', v_numero, 'token', v_token,
                            'subtotal', v_subtotal, 'desconto', v_desc, 'taxa', v_taxa, 'total', v_total,
                            'fidelidade', v_fid,
                            'pixOnline', v_online,
                            'status', case when v_online then 'aguardando_pagamento'
                                           when v_link then 'recebido' else 'em_preparo' end);
end $$;

-- ── 3) O que o link pergunta ao abrir (o do 79), com o Pix online ──────────
create or replace function public.pedidos_da_casa(p_slug text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare s public.saloes; c jsonb;
begin
  select * into s from public.saloes where slug = p_slug and status = 'ativo';
  if s.id is null then return jsonb_build_object('ligado', false); end if;
  c := public.cfg_pedidos(s.id);
  return (c - 'entregadores' - 'motoboy') || jsonb_build_object(
    'ligado', s.tipo = 'restaurante' and coalesce(public.recurso_bool(s.id, 'loja'), false),
    'aberto', (c->>'aceitando')::boolean and public.aberto_agora(s.id),
    'servicosTambem', coalesce(s.cfg->>'usaServicos', '') = 'true',
    -- (81) Pix online: a opção ligada E o Mercado Pago conectado.
    'pixOnline', coalesce((c->>'pixOnline')::boolean, false)
                 and exists (select 1 from public.mp_contas m where m.salao_id = s.id),
    /* (79) Os itens em promoção HOJE, com o preço cheio para riscar. Só os
       que a cliente vê no cardápio (ativo, no link, com preço à mostra). */
    'promocoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'preco', v.preco, 'cheio', p.preco, 'ate', p.promo_ate)
             order by p.nome)
        from public.produtos p,
             lateral (select public.preco_vigente(p.preco, p.preco_promo, p.promo_ate, s.fuso) as preco) v
       where p.salao_id = s.id and p.ativo and p.venda_online and p.preco_visivel
         and v.preco < p.preco), '[]'::jsonb));
end $$;
revoke all on function public.pedidos_da_casa(text) from public;
grant execute on function public.pedidos_da_casa(text) to anon, authenticated;

-- ── 4) A tela de Pedidos (o do 74): o Pix que não caiu fica de fora ────────
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
             'garcom', p.garcom_nome, 'conta', p.conta_id,
             'pagamento', p.pagamento, 'troco', p.troco_para,
             'pagoOnline', p.pago_online, 'pagoEm', p.pago_em,
             'observacao', p.observacao, 'motivo', p.motivo,
             'cancelado_por', p.cancelado_por,
             'criado_em', p.criado_em, 'aceito_em', p.aceito_em,
             'saiu_em', p.saiu_em, 'pronto_em', p.pronto_em,
             'entregue_em', p.entregue_em, 'cancelado_em', p.cancelado_em,
             'minutos', public.minutos_na_cozinha(p.status, p.aceito_em),
             'itens', (select coalesce(jsonb_agg(jsonb_build_object(
                         'id', i.id, 'nome', i.nome, 'quantidade', i.quantidade, 'preco', i.preco,
                         'garcom', i.garcom_nome, 'observacao', i.observacao,
                         'tempo', i.tempo_preparo, 'pronto', i.pronto_em is not null,
                         'atrasado', public.item_atrasado(p.status, p.aceito_em, i.tempo_preparo, i.pronto_em))
                         order by i.ordem), '[]'::jsonb)
                         from public.pedido_itens i where i.pedido_id = p.id))
           order by p.criado_em desc)
      from public.pedidos p
     where p.salao_id = p_salao
       -- (81) O Pix online que ainda não caiu não é pedido para a cozinha.
       and p.status <> 'aguardando_pagamento'
       and not (p.pago_online and p.pago_em is null)
       and (p.status not in ('entregue', 'cancelado')
            or p.criado_em > now() - make_interval(hours => greatest(1, least(coalesce(p_horas, 24), 24 * 31))))
  ), '[]'::jsonb);
end $$;

-- ── 5) O acompanhamento da cliente (o do 71), com o Pix ────────────────────
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
    'pixOnline', p.pago_online, 'pagoEm', p.pago_em, 'pixExpiraEm', p.pix_expira_em,
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
revoke all on function public.meu_pedido(uuid) from public;
grant execute on function public.meu_pedido(uuid) to anon, authenticated;

-- ── 6) O aviso no celular (o do 77): toca quando o Pix cai ─────────────────
create or replace function public.tg_push_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Quem lançou foi a própria equipe (garçom na mesa, telefone, balcão):
  -- não há o que avisar a ela mesma.
  if coalesce(new.origem, 'link') <> 'link' then return null; end if;
  -- (81) O Pix online toca quando o pagamento cai: na troca de
  -- 'aguardando_pagamento' para 'recebido', e não ao nascer.
  if new.status = 'aguardando_pagamento' then return null; end if;
  if tg_op = 'UPDATE' and not (old.status = 'aguardando_pagamento' and new.status = 'recebido') then
    return null;
  end if;
  perform public.push_avisar(new.salao_id, public.push_quem_cuida(new.salao_id),
    'Pedido novo',
    coalesce(nullif(btrim(coalesce(new.nome, '')), ''), 'Cliente')
      || ' · R$ ' || replace(to_char(coalesce(new.total, 0), 'FM999990.00'), '.', ',')
      || case new.tipo_entrega when 'entrega' then ' · entrega'
                               when 'mesa' then ' · mesa ' || coalesce(new.mesa, '')
                               else ' · retirada' end,
    './app.html#pedidos',
    'pedido:' || new.id);
  return null;
end $$;
drop trigger if exists tg_push_pedido_pago on public.pedidos;
create trigger tg_push_pedido_pago
  after update of status on public.pedidos
  for each row when (old.status = 'aguardando_pagamento' and new.status = 'recebido')
  execute function public.tg_push_pedido();

-- ═══════════════════════════════════════════════════════════════════════════
-- AS FUNÇÕES DO PIX ONLINE
-- As de "service_role" só o servidor (as funções de borda) chama; nenhuma
-- delas é alcançável pelo navegador.
-- ═══════════════════════════════════════════════════════════════════════════

-- O painel: está conectado? (sem nenhuma credencial na resposta)
create or replace function public.mp_conta_status(p_salao uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((select jsonb_build_object('conectado', true, 'desde', m.conectado_em,
                                             'conta', right(m.mp_user_id, 4))
                     from public.mp_contas m where m.salao_id = p_salao),
                  jsonb_build_object('conectado', false));
end $$;
revoke all on function public.mp_conta_status(uuid) from public, anon;
grant execute on function public.mp_conta_status(uuid) to authenticated;

-- O painel: começar a conexão (a borda chama com a sessão do dono).
create or replace function public.mp_conexao_iniciar(p_salao uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_estado text;
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só a gestão do restaurante conecta o Mercado Pago.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.mp_conexoes where criado_em < now() - interval '1 day';
  v_estado := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.mp_conexoes (estado, salao_id, perfil_id) values (v_estado, p_salao, auth.uid());
  return v_estado;
end $$;
revoke all on function public.mp_conexao_iniciar(uuid) from public, anon;
grant execute on function public.mp_conexao_iniciar(uuid) to authenticated;

-- O servidor: a volta do Mercado Pago, com as credenciais da conta.
create or replace function public.mp_conexao_concluir(p_estado text, p_user_id text, p_access text,
                                                      p_refresh text, p_public_key text, p_expira_em timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_salao uuid;
begin
  delete from public.mp_conexoes
   where estado = p_estado and criado_em > now() - interval '15 minutes'
  returning salao_id into v_salao;
  if v_salao is null then
    raise exception 'A conexão expirou. Toque em "Conectar Mercado Pago" de novo.' using errcode = 'check_violation';
  end if;
  if coalesce(p_access, '') = '' or coalesce(p_user_id, '') = '' then
    raise exception 'O Mercado Pago não devolveu a conta.' using errcode = 'check_violation';
  end if;
  insert into public.mp_contas (salao_id, mp_user_id, access_token, refresh_token, public_key, expira_em)
  values (v_salao, p_user_id, p_access, p_refresh, p_public_key, p_expira_em)
  on conflict (salao_id) do update
    set mp_user_id = excluded.mp_user_id, access_token = excluded.access_token,
        refresh_token = excluded.refresh_token, public_key = excluded.public_key,
        expira_em = excluded.expira_em, conectado_em = now(), atualizado_em = now();
  -- Quem conecta quer usar: o Pix online já aparece no link (dá para desligar em Entrega e pagamento).
  update public.saloes
     set cfg = coalesce(cfg, '{}'::jsonb)
             || jsonb_build_object('pedidos', case when jsonb_typeof(cfg->'pedidos') = 'object'
                                                   then cfg->'pedidos' else '{}'::jsonb end
                                              || '{"pixOnline": true}'::jsonb)
   where id = v_salao;
  return v_salao;
end $$;
revoke all on function public.mp_conexao_concluir(text, text, text, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.mp_conexao_concluir(text, text, text, text, text, timestamptz) to service_role;

-- O servidor: guardar a credencial renovada.
create or replace function public.mp_token_atualizar(p_salao uuid, p_access text, p_refresh text, p_expira_em timestamptz)
returns void language sql security definer set search_path = public as $$
  update public.mp_contas
     set access_token = p_access, refresh_token = coalesce(p_refresh, refresh_token),
         expira_em = p_expira_em, atualizado_em = now()
   where salao_id = p_salao;
$$;
revoke all on function public.mp_token_atualizar(uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.mp_token_atualizar(uuid, text, text, timestamptz) to service_role;

-- O painel: desconectar. O Pix online some do link na hora.
create or replace function public.mp_desconectar(p_salao uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só a gestão do restaurante desconecta o Mercado Pago.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.mp_contas where salao_id = p_salao;
end $$;
revoke all on function public.mp_desconectar(uuid) from public, anon;
grant execute on function public.mp_desconectar(uuid) to authenticated;

-- O servidor: tudo o que a borda precisa para cobrar ou conferir um pedido,
-- achado pelo token da cliente (ou pelo id, na volta do aviso do Mercado Pago).
create or replace function public.pix_do_pedido(p_token uuid default null, p_pedido uuid default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'id', p.id, 'numero', p.numero, 'status', p.status, 'total', p.total,
           'nome', p.nome, 'salao', p.salao_id, 'casa', s.nome,
           'pagoOnline', p.pago_online, 'pagoEm', p.pago_em,
           'mpPagamentoId', p.mp_pagamento_id, 'copiaCola', p.pix_copia_cola, 'qr', p.pix_qr,
           'expiraEm', p.pix_expira_em,
           'conta', case when m.salao_id is not null then jsonb_build_object(
                      'userId', m.mp_user_id, 'access', m.access_token, 'refresh', m.refresh_token,
                      'expiraEm', m.expira_em) end)
    from public.pedidos p
    join public.saloes s on s.id = p.salao_id
    left join public.mp_contas m on m.salao_id = p.salao_id
   where (p_token is not null and p.token = p_token) or (p_pedido is not null and p.id = p_pedido)
   limit 1
$$;
revoke all on function public.pix_do_pedido(uuid, uuid) from public, anon, authenticated;
grant execute on function public.pix_do_pedido(uuid, uuid) to service_role;

-- O servidor: guardar o Pix criado (o mesmo QR volta se a cliente recarregar).
create or replace function public.pix_anotar(p_pedido uuid, p_mp_id text, p_copia_cola text, p_qr text default null)
returns void language sql security definer set search_path = public as $$
  update public.pedidos set mp_pagamento_id = p_mp_id, pix_copia_cola = p_copia_cola,
         pix_qr = case when length(coalesce(p_qr, '')) between 1 and 60000 then p_qr end
   where id = p_pedido and status = 'aguardando_pagamento';
$$;
revoke all on function public.pix_anotar(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.pix_anotar(uuid, text, text, text) to service_role;

-- O servidor: o Pix caiu. Confere o valor, libera para a cozinha e avisa.
create or replace function public.pix_confirmar(p_pedido uuid, p_mp_id text, p_valor numeric)
returns boolean language plpgsql security definer set search_path = public as $$
declare v public.pedidos; c jsonb; s public.saloes;
begin
  select * into v from public.pedidos where id = p_pedido for update;
  if v.id is null or not v.pago_online then return false; end if;
  if v.pago_em is not null then return true; end if;            -- aviso repetido
  if p_valor is null or abs(p_valor - v.total) > 0.01 then
    raise exception 'Valor pago (%) diferente do pedido (%).', p_valor, v.total using errcode = 'check_violation';
  end if;
  -- Pagou depois de vencer: o dinheiro caiu, então o pedido volta a valer.
  update public.pedidos
     set status = case when status in ('aguardando_pagamento', 'cancelado') then 'recebido' else status end,
         pago_em = now(), mp_pagamento_id = coalesce(p_mp_id, mp_pagamento_id),
         motivo = case when status = 'cancelado' then null else motivo end,
         cancelado_por = case when status = 'cancelado' then null else cancelado_por end,
         cancelado_em = case when status = 'cancelado' then null else cancelado_em end
   where id = p_pedido;
  select * into s from public.saloes where id = v.salao_id;
  c := public.cfg_pedidos(v.salao_id);
  if (c->>'avisarCasa')::boolean then
    perform public.enfileirar_pedido(v.id, 'pedido_novo', coalesce(s.whatsapp, s.telefone));
  end if;
  return true;
end $$;
revoke all on function public.pix_confirmar(uuid, text, numeric) from public, anon, authenticated;
grant execute on function public.pix_confirmar(uuid, text, numeric) to service_role;

-- O servidor: venceu sem pagar. Cancela, dizendo o porquê.
create or replace function public.pix_vencer(p_pedido uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  update public.pedidos
     set status = 'cancelado', cancelado_em = now(), cancelado_por = 'casa',
         motivo = 'o Pix não foi pago em 30 minutos'
   where id = p_pedido and status = 'aguardando_pagamento' and pago_em is null
     and pix_expira_em < now();
  return found;
end $$;
revoke all on function public.pix_vencer(uuid) from public, anon, authenticated;
grant execute on function public.pix_vencer(uuid) to service_role;

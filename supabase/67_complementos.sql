-- ===========================================================================
-- 67_complementos.sql — complementos e variações do cardápio
--
-- Sem isto, pizzaria, hamburgueria, açaí e marmita não montam o cardápio:
-- "Pizza grande" precisa de sabores (meio a meio), borda e adicionais;
-- "X-Burger" precisa de ponto da carne e extras. Cada item do cardápio
-- ganha GRUPOS de opções:
--
--   produto_grupos   "Tamanho", "Sabores", "Borda", "Adicionais"...
--                    min / max  quantas opções a pessoa escolhe (min 0 =
--                               opcional; min 1 max 1 = escolha obrigatória)
--                    regra      como as opções entram no preço:
--                                 soma   cada opção soma (adicionais)
--                                 maior  vale a mais cara (meio a meio,
--                                        o jeito mais comum de pizzaria)
--                                 media  a média das escolhidas
--   produto_opcoes   "Calabresa" R$ 0, "Catupiry" R$ 8, "Bacon" R$ 5...
--
-- ── ⚠ O PREÇO É DO BANCO, COMO SEMPRE ─────────────────────────────────────
-- A página manda QUAIS opções (os ids). O preço do item, a regra do meio a
-- meio, o mínimo e o máximo de cada grupo são conferidos aqui, no
-- `preco_com_opcoes()`. Uma opção de outro item, de outro restaurante ou
-- desligada é recusada.
--
-- ── O PEDIDO GUARDA A FOTOGRAFIA ─────────────────────────────────────────
-- `pedido_itens.nome` passa a levar as opções escritas ("Pizza grande —
-- ½ Calabresa, ½ Frango · Borda: Catupiry") e `preco` é o preço da unidade
-- já com elas. Assim o painel, a impressão, a mensagem, o acompanhamento da
-- cliente e a venda (65) mostram tudo sem mudar nada — e mudar o cardápio
-- amanhã não reescreve o pedido de hoje. A lista estruturada fica em
-- `pedido_itens.opcoes`.
--
-- Leitura e escrita só por funções: as tabelas não abrem para a tela.
-- Pode rodar mais de uma vez.
-- ===========================================================================

create table if not exists public.produto_grupos (
  id          uuid primary key default gen_random_uuid(),
  salao_id    uuid not null references public.saloes(id) on delete cascade,
  produto_id  uuid not null references public.produtos(id) on delete cascade,
  nome        text not null check (length(btrim(nome)) between 1 and 60),
  min         smallint not null default 0 check (min between 0 and 20),
  max         smallint not null default 1 check (max between 1 and 20),
  regra       text not null default 'soma' check (regra in ('soma', 'maior', 'media')),
  ordem       smallint not null default 1,
  check (min <= max)
);
create index if not exists ix_grupo_produto on public.produto_grupos(produto_id, ordem);

create table if not exists public.produto_opcoes (
  id        uuid primary key default gen_random_uuid(),
  grupo_id  uuid not null references public.produto_grupos(id) on delete cascade,
  salao_id  uuid not null references public.saloes(id) on delete cascade,
  nome      text not null check (length(btrim(nome)) between 1 and 60),
  preco     numeric(10,2) not null default 0 check (preco >= 0),
  ativo     boolean not null default true,
  ordem     smallint not null default 1
);
create index if not exists ix_opcao_grupo on public.produto_opcoes(grupo_id, ordem);

alter table public.produto_grupos enable row level security;
alter table public.produto_grupos force row level security;
alter table public.produto_opcoes enable row level security;
alter table public.produto_opcoes force row level security;
revoke all on public.produto_grupos from public, anon, authenticated;
revoke all on public.produto_opcoes from public, anon, authenticated;

alter table public.pedido_itens add column if not exists opcoes jsonb;

-- ---------------------------------------------------------------------------
-- 1) OS GRUPOS DE UM ITEM — para o cadastro do cardápio (equipe lê, gestão grava)
-- ---------------------------------------------------------------------------
create or replace function public.grupos_do_produto(p_produto uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', g.id, 'nome', g.nome, 'min', g.min, 'max', g.max, 'regra', g.regra,
           'opcoes', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', o.id, 'nome', o.nome, 'preco', o.preco, 'ativo', o.ativo)
                         order by o.ordem, o.nome)
                       from public.produto_opcoes o where o.grupo_id = g.id), '[]'::jsonb))
         order by g.ordem, g.nome), '[]'::jsonb)
    from public.produto_grupos g
   where g.produto_id = p_produto
$$;

create or replace function public.opcoes_do_produto(p_produto uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_salao uuid;
begin
  select salao_id into v_salao from public.produtos where id = p_produto;
  if v_salao is null or not public.e_equipe(v_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  return public.grupos_do_produto(p_produto);
end $$;

/* Grava TODOS os grupos de um item de uma vez: o que veio substitui o que
   havia. Os ids que vierem e existirem são mantidos (o pedido antigo aponta
   para eles só como fotografia, então trocar não quebra nada). */
create or replace function public.salvar_opcoes_do_produto(p_produto uuid, p_grupos jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_salao uuid; g jsonb; o jsonb; v_grupo uuid; v_og smallint := 0; v_oo smallint;
  v_min int; v_max int; v_nome text;
begin
  select salao_id into v_salao from public.produtos where id = p_produto;
  if v_salao is null or not public.e_gestor(v_salao) then
    raise exception 'Só a gestão muda o cardápio.' using errcode = 'insufficient_privilege';
  end if;
  if p_grupos is null or jsonb_typeof(p_grupos) <> 'array' then
    raise exception 'Os complementos vieram num formato que não entendo.' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_grupos) > 15 then
    raise exception 'No máximo 15 grupos de complementos por item.' using errcode = 'check_violation';
  end if;

  delete from public.produto_grupos where produto_id = p_produto;
  for g in select value from jsonb_array_elements(p_grupos) loop
    v_og := v_og + 1;
    v_nome := nullif(left(btrim(coalesce(g->>'nome', '')), 60), '');
    if v_nome is null then
      raise exception 'Dê um nome a cada grupo (por exemplo: Tamanho, Borda, Adicionais).'
        using errcode = 'check_violation';
    end if;
    if jsonb_typeof(g->'opcoes') <> 'array' or jsonb_array_length(g->'opcoes') = 0 then
      raise exception 'O grupo "%" está sem opções.', v_nome using errcode = 'check_violation';
    end if;
    if jsonb_array_length(g->'opcoes') > 60 then
      raise exception 'O grupo "%" tem opções demais (máximo 60).', v_nome using errcode = 'check_violation';
    end if;
    v_min := coalesce(nullif(g->>'min', '')::int, 0);
    v_max := coalesce(nullif(g->>'max', '')::int, 1);
    if v_min < 0 or v_max < 1 or v_min > v_max or v_max > 20 then
      raise exception 'No grupo "%", confira o mínimo e o máximo.', v_nome using errcode = 'check_violation';
    end if;
    if v_min > jsonb_array_length(g->'opcoes') then
      raise exception 'O grupo "%" pede mais escolhas do que tem opções.', v_nome using errcode = 'check_violation';
    end if;
    insert into public.produto_grupos (id, salao_id, produto_id, nome, min, max, regra, ordem)
    values (coalesce(nullif(g->>'id', '')::uuid, gen_random_uuid()), v_salao, p_produto, v_nome,
            v_min, v_max,
            case when g->>'regra' in ('soma', 'maior', 'media') then g->>'regra' else 'soma' end,
            v_og)
    returning id into v_grupo;
    v_oo := 0;
    for o in select value from jsonb_array_elements(g->'opcoes') loop
      v_oo := v_oo + 1;
      if nullif(btrim(coalesce(o->>'nome', '')), '') is null then
        raise exception 'No grupo "%", uma opção está sem nome.', v_nome using errcode = 'check_violation';
      end if;
      if coalesce(o->>'preco', '0') !~ '^[0-9]+([.,][0-9]{1,2})?$' then
        raise exception 'No grupo "%", confira o preço de "%".', v_nome, o->>'nome'
          using errcode = 'check_violation';
      end if;
      insert into public.produto_opcoes (id, grupo_id, salao_id, nome, preco, ativo, ordem)
      values (coalesce(nullif(o->>'id', '')::uuid, gen_random_uuid()), v_grupo, v_salao,
              left(btrim(o->>'nome'), 60),
              replace(coalesce(nullif(o->>'preco', ''), '0'), ',', '.')::numeric,
              coalesce((o->>'ativo')::boolean, true), v_oo);
    end loop;
  end loop;
  return public.grupos_do_produto(p_produto);
end $$;

-- ---------------------------------------------------------------------------
-- 2) O CARDÁPIO DO LINK — os grupos de cada item à venda (público)
-- ---------------------------------------------------------------------------
create or replace function public.opcoes_da_casa(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(pr.id, public.grupos_do_produto(pr.id)), '{}'::jsonb)
    from public.saloes s
    join public.produtos pr on pr.salao_id = s.id and pr.ativo and pr.venda_online
   where s.slug = p_slug and s.status = 'ativo'
     and exists (select 1 from public.produto_grupos g where g.produto_id = pr.id)
$$;

-- ---------------------------------------------------------------------------
-- 3) O PREÇO DE UM ITEM COM AS OPÇÕES — a única conta, no banco
-- ---------------------------------------------------------------------------
create or replace function public.preco_com_opcoes(p_produto uuid, p_base numeric, p_opcoes jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g       record;
  v_ids   uuid[];
  v_sel   record;
  v_preco numeric := coalesce(p_base, 0);
  v_partes text[] := '{}';
  v_lista jsonb := '[]'::jsonb;
  v_txt   text;
  v_frac  text;
begin
  if p_opcoes is not null and jsonb_typeof(p_opcoes) <> 'array' then
    raise exception 'As opções do item vieram num formato que não entendo.' using errcode = 'check_violation';
  end if;
  begin
    select coalesce(array_agg(distinct x::uuid), '{}') into v_ids
      from jsonb_array_elements_text(coalesce(p_opcoes, '[]'::jsonb)) x;
  exception when others then
    raise exception 'Uma das opções do item não existe mais. Confira o pedido.' using errcode = 'check_violation';
  end;

  -- Toda opção escolhida tem de ser deste item e estar ligada.
  if exists (select 1 from unnest(v_ids) i
              where not exists (select 1 from public.produto_opcoes o
                                  join public.produto_grupos gg on gg.id = o.grupo_id
                                 where o.id = i and gg.produto_id = p_produto and o.ativo)) then
    raise exception 'Uma das opções escolhidas não está mais disponível. Confira o pedido.'
      using errcode = 'check_violation';
  end if;

  for g in select * from public.produto_grupos where produto_id = p_produto order by ordem, nome loop
    select count(*) as n, coalesce(sum(o.preco), 0) as soma, coalesce(max(o.preco), 0) as maior,
           coalesce(avg(o.preco), 0) as media,
           string_agg(o.nome, ', ' order by o.ordem, o.nome) as nomes,
           array_agg(o.nome order by o.ordem, o.nome) as lista
      into v_sel
      from public.produto_opcoes o where o.grupo_id = g.id and o.id = any(v_ids);
    if v_sel.n < g.min then
      raise exception '%', case when g.min = 1 then format('Escolha %s.', lower(g.nome))
                                else format('Em "%s", escolha pelo menos %s.', g.nome, g.min) end
        using errcode = 'check_violation';
    end if;
    if v_sel.n > g.max then
      raise exception 'Em "%", escolha no máximo %.', g.nome, g.max using errcode = 'check_violation';
    end if;
    if v_sel.n = 0 then continue; end if;

    v_preco := v_preco + round(case g.regra when 'maior' then v_sel.maior
                                            when 'media' then v_sel.media
                                            else v_sel.soma end, 2);
    -- Meio a meio: "½ Calabresa, ½ Frango" (um terço, um quarto...).
    if g.regra <> 'soma' and v_sel.n > 1 then
      v_frac := case v_sel.n when 2 then '½' when 3 then '⅓' when 4 then '¼' else '1/' || v_sel.n end;
      select string_agg(v_frac || ' ' || n, ', ') into v_txt from unnest(v_sel.lista) n;
    else
      v_txt := v_sel.nomes;
    end if;
    v_partes := v_partes || (g.nome || ': ' || v_txt);
    v_lista := v_lista || jsonb_build_object('grupo', g.nome, 'opcoes', to_jsonb(v_sel.lista));
  end loop;

  return jsonb_build_object('preco', round(v_preco, 2),
                            'texto', array_to_string(v_partes, ' · '),
                            'opcoes', v_lista);
end $$;

-- ---------------------------------------------------------------------------
-- 4) FAZER O PEDIDO — o do 37, agora com as opções de cada item
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
  v_total := v_subtotal + v_taxa;

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
     subtotal, taxa_entrega, total, pagamento, troco_para, observacao)
  values (s.id, v_numero, v_cliente, v_nome, v_tel, v_modo,
          case when v_modo = 'entrega' then v_end end,
          case when v_modo = 'entrega' then v_bairro end,
          v_subtotal, v_taxa, v_total, v_pag, v_troco, v_obs)
  returning id, token into v_pedido, v_token;

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
                            'subtotal', v_subtotal, 'taxa', v_taxa, 'total', v_total,
                            'status', 'recebido');
end $$;

revoke all on function public.grupos_do_produto(uuid) from public, anon, authenticated;
revoke all on function public.opcoes_do_produto(uuid) from public, anon;
grant execute on function public.opcoes_do_produto(uuid) to authenticated;
revoke all on function public.salvar_opcoes_do_produto(uuid, jsonb) from public, anon;
grant execute on function public.salvar_opcoes_do_produto(uuid, jsonb) to authenticated;
revoke all on function public.opcoes_da_casa(text) from public;
grant execute on function public.opcoes_da_casa(text) to anon, authenticated;
revoke all on function public.preco_com_opcoes(uuid, numeric, jsonb) from public, anon, authenticated;
revoke all on function public.fazer_pedido(text, jsonb) from public;
grant execute on function public.fazer_pedido(text, jsonb) to anon, authenticated;

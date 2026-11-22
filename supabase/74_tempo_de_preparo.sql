-- ===========================================================================
-- PediHub — tempo de preparo de cada prato, e o aviso de ATRASADO (74)
--
-- A ideia veio do salão: "esse prato demora 30 minutos; a entrada, 15. Passou
-- dos 15 e a entrada não saiu? O sistema acusa, em vermelho, e o garçom sabe
-- o que cobrar na cozinha."
--
--   * produtos.tempo_preparo   minutos que o prato leva (em branco = não conta);
--   * pedido_itens.tempo_preparo   COPIADO na hora do pedido, como o nome e o
--     preço: mudar o cardápio depois não muda o que já está na cozinha;
--   * pedido_itens.pronto_em   a cozinha marca item a item: a entrada fica
--     pronta antes do prato do mesmo pedido, e não pode continuar "atrasada";
--   * o relógio começa quando o pedido entra em preparo (`aceito_em`): o que
--     o garçom lança já nasce em preparo; o do QR, quando alguém aceita.
--
-- ATRASADO = pedido em preparo, item não marcado pronto, com tempo definido,
-- e já passou do tempo. Quem calcula é o banco (o relógio do celular do
-- garçom pode estar errado); as telas releem a cada 20 segundos.
-- ===========================================================================

alter table public.produtos add column if not exists tempo_preparo smallint;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'produtos_tempo_preparo_faixa') then
    alter table public.produtos add constraint produtos_tempo_preparo_faixa
      check (tempo_preparo is null or tempo_preparo between 1 and 600);
  end if;
end $$;

alter table public.pedido_itens add column if not exists tempo_preparo smallint;
alter table public.pedido_itens add column if not exists pronto_em timestamptz;

-- O item leva o tempo do prato na hora em que é pedido.
create or replace function public.item_com_tempo()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.produto_id is not null then
    select p.tempo_preparo into new.tempo_preparo from public.produtos p where p.id = new.produto_id;
  else
    new.tempo_preparo := null;
  end if;
  new.pronto_em := null;
  return new;
end $$;
drop trigger if exists item_com_tempo on public.pedido_itens;
create trigger item_com_tempo before insert on public.pedido_itens
  for each row execute function public.item_com_tempo();

-- Os minutos na cozinha e o "atrasado", num lugar só (as três listas usam).
create or replace function public.minutos_na_cozinha(p_status text, p_aceito timestamptz)
returns int language sql stable set search_path = public as $$
  select case when p_status = 'em_preparo' and p_aceito is not null
              then greatest(0, floor(extract(epoch from now() - p_aceito) / 60))::int end
$$;
create or replace function public.item_atrasado(p_status text, p_aceito timestamptz, p_tempo int, p_pronto timestamptz)
returns boolean language sql stable set search_path = public as $$
  select coalesce(p_status = 'em_preparo' and p_pronto is null and p_tempo is not null
                  and p_aceito is not null and now() - p_aceito > make_interval(mins => p_tempo), false)
$$;

-- ---------------------------------------------------------------------------
-- 1) A COZINHA MARCA O ITEM PRONTO (ou desmarca, se tocou errado)
-- ---------------------------------------------------------------------------
create or replace function public.marcar_item_pronto(p_item uuid, p_pronto boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_salao uuid; v_status text;
begin
  select p.salao_id, p.status into v_salao, v_status
    from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id where i.id = p_item;
  if v_salao is null or not public.e_equipe(v_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  if v_status not in ('recebido', 'em_preparo') then
    raise exception 'Este pedido já saiu da cozinha.';
  end if;
  update public.pedido_itens
     set pronto_em = case when coalesce(p_pronto, true) then coalesce(pronto_em, now()) end
   where id = p_item;
  return jsonb_build_object('id', p_item, 'pronto', coalesce(p_pronto, true));
end $$;

-- ---------------------------------------------------------------------------
-- 2) A CONTA DA MESA: cada item com o tempo, os minutos e o atrasado
-- ---------------------------------------------------------------------------
create or replace function public.conta_da_mesa(p_salao uuid, p_mesa text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.mesa_contas;
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  select * into c from public.mesa_contas where salao_id = p_salao and mesa = p_mesa and fechada_em is null;
  if c.id is null then return jsonb_build_object('aberta', false, 'mesa', p_mesa); end if;
  return jsonb_build_object(
    'aberta', true, 'id', c.id, 'mesa', c.mesa, 'abertaEm', c.aberta_em,
    'total', coalesce((select sum(p.total) from public.pedidos p where p.conta_id = c.id and p.status <> 'cancelado'), 0),
    'esperando', (select count(*) from public.pedidos p where p.conta_id = c.id and p.status = 'recebido'),
    'atrasados', (select count(*) from public.pedidos p join public.pedido_itens i on i.pedido_id = p.id
                   where p.conta_id = c.id and public.item_atrasado(p.status, p.aceito_em, i.tempo_preparo, i.pronto_em)),
    'itens', coalesce((select jsonb_agg(jsonb_build_object(
        'id', i.id, 'nome', i.nome, 'quantidade', i.quantidade, 'preco', i.preco, 'observacao', i.observacao,
        'garcom', coalesce(i.garcom_nome, case when p.origem = 'link' then 'Cliente (QR)' end),
        'status', p.status, 'pedido', p.numero, 'em', p.criado_em,
        'tempo', i.tempo_preparo, 'pronto', i.pronto_em is not null,
        'minutos', case when i.pronto_em is null then public.minutos_na_cozinha(p.status, p.aceito_em) end,
        'atrasado', public.item_atrasado(p.status, p.aceito_em, i.tempo_preparo, i.pronto_em))
        order by p.criado_em, i.ordem)
      from public.pedidos p join public.pedido_itens i on i.pedido_id = p.id
     where p.conta_id = c.id and p.status <> 'cancelado'), '[]'::jsonb));
end $$;

create or replace function public.mesas_abertas(p_salao uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'mesa', c.mesa, 'abertaEm', c.aberta_em,
      'total', coalesce((select sum(p.total) from public.pedidos p where p.conta_id = c.id and p.status <> 'cancelado'), 0),
      'itens', coalesce((select sum(i.quantidade) from public.pedidos p join public.pedido_itens i on i.pedido_id = p.id
                          where p.conta_id = c.id and p.status <> 'cancelado'), 0),
      'esperando', (select count(*) from public.pedidos p where p.conta_id = c.id and p.status = 'recebido'),
      'prontos', (select count(*) from public.pedidos p where p.conta_id = c.id and p.status = 'pronto'),
      'atrasados', (select count(*) from public.pedidos p join public.pedido_itens i on i.pedido_id = p.id
                     where p.conta_id = c.id and public.item_atrasado(p.status, p.aceito_em, i.tempo_preparo, i.pronto_em))))
    from public.mesa_contas c where c.salao_id = p_salao and c.fechada_em is null), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 3) A LISTA DO PAINEL (a do 73, com o tempo de cada item)
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
             'origem', p.origem, 'mesa', p.mesa, 'entregador', p.entregador,
             'garcom', p.garcom_nome, 'conta', p.conta_id,
             'pagamento', p.pagamento, 'troco', p.troco_para,
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
       and (p.status not in ('entregue', 'cancelado')
            or p.criado_em > now() - make_interval(hours => greatest(1, least(coalesce(p_horas, 24), 24 * 31))))
  ), '[]'::jsonb);
end $$;

revoke all on function public.item_com_tempo() from public, anon, authenticated;
revoke all on function public.minutos_na_cozinha(text, timestamptz) from public, anon;
grant execute on function public.minutos_na_cozinha(text, timestamptz) to authenticated;
revoke all on function public.item_atrasado(text, timestamptz, int, timestamptz) from public, anon;
grant execute on function public.item_atrasado(text, timestamptz, int, timestamptz) to authenticated;
revoke all on function public.marcar_item_pronto(uuid, boolean) from public, anon;
grant execute on function public.marcar_item_pronto(uuid, boolean) to authenticated;
revoke all on function public.conta_da_mesa(uuid, text) from public, anon;
grant execute on function public.conta_da_mesa(uuid, text) to authenticated;
revoke all on function public.mesas_abertas(uuid) from public, anon;
grant execute on function public.mesas_abertas(uuid) to authenticated;
revoke all on function public.pedidos_da_loja(uuid, int) from public, anon;
grant execute on function public.pedidos_da_loja(uuid, int) to authenticated;

-- ===========================================================================
-- 65_pedido_vira_venda.sql — o pedido entregue entra no faturamento
--
-- O pedido do restaurante (37_pedidos) tinha andamento — recebido, em
-- preparo, saiu, entregue — mas não virava dinheiro em lugar nenhum: o Caixa,
-- o Dashboard e os Relatórios contam COMANDAS, e o pedido nunca abria uma.
-- Um restaurante que vendeu R$ 5 mil pelo link via R$ 0 no relatório.
--
-- Agora, no instante em que o pedido vira `entregue`, nasce uma comanda
-- FECHADA com ele — o mesmo caminho da venda da loja (53_pedidos_loja):
--
--   · os itens com o nome e o PREÇO DO PEDIDO (o que o cliente pagou, e não
--     o do cardápio de hoje);
--   · a taxa de entrega como acréscimo da comanda;
--   · o pagamento na forma que o cliente escolheu: Pix, dinheiro ou cartão
--     (o cartão na entrega entra como crédito: a maquininha não diz qual);
--   · o estoque baixa, como em qualquer venda (26_estoque).
--
-- E daí em diante é venda como outra qualquer: aparece no caixa do dia, no
-- faturamento, no ticket médio e no "o que mais saiu".
--
-- ── ⚠ ENTREGAR NUNCA FALHA POR CAUSA DISTO ────────────────────────────────
-- Se a venda não puder ser gravada (a ficha do cliente não pôde ser criada,
-- por exemplo), o pedido fica entregue do mesmo jeito e o motivo fica em
-- `pedidos.venda_erro`. Travar a entrega na mão do motoboy seria pior.
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

alter table public.pedidos
  add column if not exists comanda_id uuid references public.comandas(id) on delete set null;
alter table public.pedidos
  add column if not exists venda_erro text;

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

  insert into public.comandas (salao_id, cliente_id, status, acrescimo)
       values (p.salao_id, v_cli, 'aberta', coalesce(p.taxa_entrega, 0))
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
revoke all on function public.pedido_vira_venda(uuid) from public, anon, authenticated;

/* O gatilho: só na passagem para `entregue`, uma vez. Qualquer erro vira
   recado no próprio pedido, e a entrega segue. */
create or replace function public.pedido_entregue_vira_venda()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    perform public.pedido_vira_venda(new.id);
  exception when others then
    update public.pedidos set venda_erro = left('A venda não entrou no caixa: ' || sqlerrm, 300)
     where id = new.id;
  end;
  return null;
end $$;

drop trigger if exists pedido_entregue_vira_venda on public.pedidos;
create trigger pedido_entregue_vira_venda
  after update of status on public.pedidos
  for each row
  when (new.status = 'entregue' and old.status is distinct from 'entregue')
  execute function public.pedido_entregue_vira_venda();

-- ===========================================================================
-- 73_conta_da_mesa_garcom.sql — a conta da mesa e o garçom de cada item
--
-- O salão de verdade: a mesa abre uma CONTA, e tudo o que se pede nela vai
-- somando — o prato que o garçom lançou, o vinho que outro garçom lançou
-- depois, o pedido que o próprio cliente fez pelo QR. No fim, fecha-se a
-- conta: com ou sem os 10% de serviço, numa forma de pagamento, e tudo
-- entra no caixa.
--
-- E cada item diz QUEM lançou — pelo login de quem estava com o celular.
-- O responsável não é da mesa nem da praça: é do item. Se o Wilson lançou
-- o prato e o freelancer lançou o vinho, cada um sai com o seu nome.
--
--   mesa_contas            a conta aberta de cada mesa (uma por vez)
--   pedidos.conta_id       o pedido pertence à conta da mesa
--   pedidos.garcom_*       quem lançou o pedido (auth.uid(), e o nome)
--   pedido_itens.garcom_nome   o nome, item a item (a fotografia)
--   lancar_pedido()        a equipe também lança pela MESA
--   conta_da_mesa()        o que a mesa já pediu, item a item, com o garçom
--   mesas_abertas()        o mapa: quais mesas estão com conta, quanto e há quanto
--   fechar_conta_mesa()    fecha: serviço, forma de pagamento — e vira venda
--
-- O pedido da conta só vira venda quando a CONTA fecha (antes, a forma de
-- pagamento não existe). As praças (Praça 1 = mesas 1 a 5...) são só
-- organização da tela e ficam na configuração (`cfg.pedidos.pracas`).
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

create table if not exists public.mesa_contas (
  id            uuid primary key default gen_random_uuid(),
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  mesa          text not null,
  aberta_em     timestamptz not null default now(),
  fechada_em    timestamptz,
  fechada_por   uuid references auth.users(id) on delete set null,
  pagamento     text,
  taxa_servico  numeric(10,2) not null default 0 check (taxa_servico >= 0),
  pessoas       int check (pessoas is null or pessoas between 1 and 50),
  total         numeric(10,2)
);
create unique index if not exists ux_conta_aberta on public.mesa_contas(salao_id, mesa) where fechada_em is null;
create index if not exists ix_conta_salao on public.mesa_contas(salao_id, aberta_em desc);
alter table public.mesa_contas enable row level security;
alter table public.mesa_contas force row level security;
revoke all on public.mesa_contas from public, anon, authenticated;

alter table public.pedidos add column if not exists conta_id uuid references public.mesa_contas(id) on delete set null;
alter table public.pedidos add column if not exists garcom_id uuid references auth.users(id) on delete set null;
alter table public.pedidos add column if not exists garcom_nome text;
alter table public.pedido_itens add column if not exists garcom_nome text;

/* Ao nascer o pedido: na mesa, entra na conta aberta (ou abre uma); e se
   quem lançou foi alguém da equipe (logado), o nome dele vai junto. */
create or replace function public.pedido_na_conta()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.tipo_entrega = 'mesa' and new.conta_id is null and coalesce(new.mesa, '') <> '' then
    select id into new.conta_id from public.mesa_contas
     where salao_id = new.salao_id and mesa = new.mesa and fechada_em is null;
    if new.conta_id is null then
      insert into public.mesa_contas (salao_id, mesa) values (new.salao_id, new.mesa)
      returning id into new.conta_id;
    end if;
  end if;
  if coalesce(new.origem, 'link') <> 'link' and auth.uid() is not null and new.garcom_id is null then
    new.garcom_id := auth.uid();
    new.garcom_nome := coalesce((select nullif(btrim(split_part(pf.nome, ' ', 1)), '') from public.perfis pf where pf.id = auth.uid()),
                                'Equipe');
  end if;
  return new;
end $$;
drop trigger if exists pedido_na_conta on public.pedidos;
create trigger pedido_na_conta before insert on public.pedidos
  for each row execute function public.pedido_na_conta();

create or replace function public.item_com_garcom()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.garcom_nome is null then
    select garcom_nome into new.garcom_nome from public.pedidos where id = new.pedido_id;
  end if;
  return new;
end $$;
drop trigger if exists item_com_garcom on public.pedido_itens;
create trigger item_com_garcom before insert on public.pedido_itens
  for each row execute function public.item_com_garcom();

/* A venda (65) espera a conta: pedido de conta ABERTA, servido, ainda não é
   venda — a forma de pagamento só existe quando a conta fecha. */
create or replace function public.pedido_entregue_vira_venda()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.conta_id is not null and exists (select 1 from public.mesa_contas c
                                          where c.id = new.conta_id and c.fechada_em is null) then
    return null;
  end if;
  begin
    perform public.pedido_vira_venda(new.id);
  exception when others then
    update public.pedidos set venda_erro = left('A venda não entrou no caixa: ' || sqlerrm, 300)
     where id = new.id;
  end;
  return null;
end $$;

-- ---------------------------------------------------------------------------
-- 1) A EQUIPE LANÇA TAMBÉM PELA MESA
-- ---------------------------------------------------------------------------
create or replace function public.lancar_pedido(p_salao uuid, p_pedido jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_origem text := coalesce(nullif(p_pedido->>'origem', ''), 'balcao');
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  if v_origem not in ('telefone', 'balcao', 'mesa') then
    raise exception 'Origem de pedido desconhecida.' using errcode = 'check_violation';
  end if;
  return public.registrar_pedido(p_salao, p_pedido, v_origem);
end $$;

-- ---------------------------------------------------------------------------
-- 2) O QUE A MESA JÁ PEDIU, E O MAPA DAS MESAS
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
    'itens', coalesce((select jsonb_agg(jsonb_build_object(
        'nome', i.nome, 'quantidade', i.quantidade, 'preco', i.preco, 'observacao', i.observacao,
        'garcom', coalesce(i.garcom_nome, case when p.origem = 'link' then 'Cliente (QR)' end),
        'status', p.status, 'pedido', p.numero, 'em', p.criado_em)
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
      'prontos', (select count(*) from public.pedidos p where p.conta_id = c.id and p.status = 'pronto')))
    from public.mesa_contas c where c.salao_id = p_salao and c.fechada_em is null), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 3) FECHAR A CONTA
--    p_servico_pct: 0 ou os 10% (até 20); vale sobre o que a mesa consumiu.
--    Tudo o que está na conta vira servido e, com a conta fechada, venda —
--    na forma escolhida. O serviço entra no caixa como uma venda à parte.
-- ---------------------------------------------------------------------------
create or replace function public.fechar_conta_mesa(p_salao uuid, p_mesa text, p_forma text,
                                                    p_servico_pct numeric default 0, p_pessoas int default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c        public.mesa_contas;
  v_sub    numeric(10,2);
  v_serv   numeric(10,2);
  v_com    uuid;
  v_cli    uuid;
  p        record;
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  if p_forma not in ('pix', 'dinheiro', 'debito', 'credito') then
    raise exception 'Escolha Pix, dinheiro, débito ou crédito.' using errcode = 'check_violation';
  end if;
  if coalesce(p_servico_pct, 0) < 0 or coalesce(p_servico_pct, 0) > 20 then
    raise exception 'A taxa de serviço vai de 0 a 20%%.' using errcode = 'check_violation';
  end if;
  select * into c from public.mesa_contas
   where salao_id = p_salao and mesa = p_mesa and fechada_em is null for update;
  if c.id is null then
    raise exception 'A mesa % não tem conta aberta.', p_mesa using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.pedidos where conta_id = c.id and status = 'recebido') then
    raise exception 'Há pedido desta mesa esperando "Aceitar". Aceite ou cancele antes de fechar.'
      using errcode = 'check_violation';
  end if;
  select coalesce(sum(total), 0) into v_sub from public.pedidos where conta_id = c.id and status <> 'cancelado';
  v_serv := round(v_sub * coalesce(p_servico_pct, 0) / 100, 2);

  update public.mesa_contas set fechada_em = now(), fechada_por = auth.uid(), pagamento = p_forma,
         taxa_servico = v_serv, pessoas = p_pessoas, total = v_sub + v_serv
   where id = c.id;

  -- A forma de pagamento vale para todos os pedidos da conta; os que ainda
  -- não estavam servidos passam a estar (o gatilho faz a venda).
  update public.pedidos set pagamento = p_forma where conta_id = c.id and status <> 'cancelado';
  for p in select id, status from public.pedidos where conta_id = c.id and status <> 'cancelado' loop
    if p.status = 'entregue' then
      begin
        perform public.pedido_vira_venda(p.id);
      exception when others then
        update public.pedidos set venda_erro = left('A venda não entrou no caixa: ' || sqlerrm, 300) where id = p.id;
      end;
    else
      update public.pedidos set status = 'entregue', entregue_em = now() where id = p.id;
    end if;
  end loop;

  -- Os 10%: uma venda à parte, na mesma forma.
  if v_serv > 0 then
    v_cli := public.ficha_do_balcao(p_salao);
    insert into public.comandas (salao_id, cliente_id, status) values (p_salao, v_cli, 'aberta') returning id into v_com;
    insert into public.comanda_itens (comanda_id, tipo, descricao, qtd, preco_unit)
         values (v_com, 'produto', 'Taxa de serviço (' || trim(to_char(p_servico_pct, 'FM990.##')) || '%) — Mesa ' || p_mesa, 1, v_serv);
    insert into public.pagamentos (comanda_id, forma, valor) values (v_com, p_forma, v_serv);
    update public.comandas set status = 'fechada', fechada_em = now() where id = v_com;
  end if;

  return jsonb_build_object('ok', true, 'subtotal', v_sub, 'servico', v_serv, 'total', v_sub + v_serv,
                            'porPessoa', case when coalesce(p_pessoas, 0) > 0
                                              then round((v_sub + v_serv) / p_pessoas, 2) end);
end $$;

-- ---------------------------------------------------------------------------
-- 4) A LISTA DO PAINEL leva o garçom e a conta (a do 71, com chaves a mais)
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
             'itens', (select coalesce(jsonb_agg(jsonb_build_object(
                         'nome', i.nome, 'quantidade', i.quantidade, 'preco', i.preco, 'garcom', i.garcom_nome,
                         'observacao', i.observacao) order by i.ordem), '[]'::jsonb)
                         from public.pedido_itens i where i.pedido_id = p.id))
           order by p.criado_em desc)
      from public.pedidos p
     where p.salao_id = p_salao
       and (p.status not in ('entregue', 'cancelado')
            or p.criado_em > now() - make_interval(hours => greatest(1, least(coalesce(p_horas, 24), 24 * 31))))
  ), '[]'::jsonb);
end $$;




revoke all on function public.pedido_na_conta() from public, anon, authenticated;
revoke all on function public.item_com_garcom() from public, anon, authenticated;
revoke all on function public.lancar_pedido(uuid, jsonb) from public, anon;
grant execute on function public.lancar_pedido(uuid, jsonb) to authenticated;
revoke all on function public.conta_da_mesa(uuid, text) from public, anon;
grant execute on function public.conta_da_mesa(uuid, text) to authenticated;
revoke all on function public.mesas_abertas(uuid) from public, anon;
grant execute on function public.mesas_abertas(uuid) to authenticated;
revoke all on function public.fechar_conta_mesa(uuid, text, text, numeric, int) from public, anon;
grant execute on function public.fechar_conta_mesa(uuid, text, text, numeric, int) to authenticated;
revoke all on function public.pedidos_da_loja(uuid, int) from public, anon;
grant execute on function public.pedidos_da_loja(uuid, int) to authenticated;

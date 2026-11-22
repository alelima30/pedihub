-- ===========================================================================
-- PediHub — entregadores: o acerto do dinheiro, quanto o motoboy ganha e o
-- link do entregador no celular (75)
--
--   1. QUANTO ELE GANHA (cfg.pedidos.motoboy):
--        modo 'taxa'  — o que os clientes pagaram de entrega (como era);
--        modo 'fixo'  — `valor` por entrega, seja qual for a taxa cobrada;
--        `diaria`     — somada por dia em que ele fez entrega (0 = não usa).
--   2. O ACERTO: por entregador, no período — entregas, o dinheiro que ele
--      recebeu na porta (pedido pago em dinheiro), quanto ganha e o saldo:
--      positivo, ele DEVOLVE ao caixa; negativo, a casa PAGA a ele.
--   3. O LINK DO ENTREGADOR: um endereço secreto por pessoa (token), sem
--      login — motoboy é muitas vezes freelancer. Ele vê só as entregas que
--      estão com ele ("saiu para entrega"), com endereço, telefone, o que
--      cobrar e o troco, e marca "Entregue". Tirar o nome da lista ou gerar
--      outro link corta o antigo na hora.
--
-- O que é da casa (quanto o motoboy ganha, os nomes) NÃO sai na página
-- pública do cardápio.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 0) A CONFIGURAÇÃO ganha `motoboy` (a do 72, com a chave a mais)
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
                             where x in ('pix','dinheiro','debito','credito','cartao')),
                           '["pix","dinheiro","debito","credito"]'::jsonb),
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

-- A página pública não leva nem os nomes nem quanto o motoboy ganha.
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
    'servicosTambem', coalesce(s.cfg->>'usaServicos', '') = 'true');
end $$;

-- ---------------------------------------------------------------------------
-- 1) A CONTA DE CADA ENTREGADOR no período (uso interno: quem chama confere
--    a permissão). `p_nome` nulo = todos.
-- ---------------------------------------------------------------------------
create or replace function public.contas_dos_entregadores(p_salao uuid, p_de date, p_ate date, p_nome text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_fuso text; m jsonb;
begin
  select coalesce(fuso, 'America/Sao_Paulo') into v_fuso from public.saloes where id = p_salao;
  m := public.cfg_pedidos(p_salao)->'motoboy';
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'entregador', x.quem, 'entregas', x.n, 'dias', x.dias,
             'taxas', x.taxas, 'total', x.total, 'dinheiro', x.dinheiro, 'troco', x.troco,
             'ganha', x.ganha, 'saldo', x.dinheiro - x.ganha)
           order by x.n desc, x.quem)
      from (select y.*,
                   case when y.quem = 'Sem entregador' then 0
                        else (case when m->>'modo' = 'fixo' then y.n * (m->>'valor')::numeric else y.taxas end)
                             + y.dias * (m->>'diaria')::numeric end as ganha
              from (select coalesce(p.entregador, 'Sem entregador') as quem, count(*) as n,
                           count(distinct (p.entregue_em at time zone v_fuso)::date) as dias,
                           coalesce(sum(p.taxa_entrega), 0) as taxas, coalesce(sum(p.total), 0) as total,
                           coalesce(sum(p.total) filter (where p.pagamento = 'dinheiro'), 0) as dinheiro,
                           coalesce(sum(p.troco_para - p.total) filter (where p.pagamento = 'dinheiro'
                                       and p.troco_para > p.total), 0) as troco
                      from public.pedidos p
                     where p.salao_id = p_salao and p.status = 'entregue' and p.tipo_entrega = 'entrega'
                       and (p.entregue_em at time zone v_fuso)::date between p_de and p_ate
                       and (p_nome is null or p.entregador = p_nome)
                     group by 1) y) x), '[]'::jsonb);
end $$;

-- O acerto da tela (o do 71, agora com o dinheiro e quanto cada um ganha).
create or replace function public.acerto_entregadores(p_salao uuid, p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.ve_agenda_toda(p_salao) then
    raise exception 'Só o balcão e a gestão veem o acerto.' using errcode = 'insufficient_privilege';
  end if;
  return public.contas_dos_entregadores(p_salao, p_de, p_ate, null);
end $$;

-- ---------------------------------------------------------------------------
-- 2) O LINK DE CADA ENTREGADOR
-- ---------------------------------------------------------------------------
create table if not exists public.entregador_links (
  salao_id  uuid not null references public.saloes(id) on delete cascade,
  nome      text not null,
  token     uuid not null default gen_random_uuid() unique,
  criado_em timestamptz not null default now(),
  primary key (salao_id, nome)
);
alter table public.entregador_links enable row level security;
alter table public.entregador_links force row level security;
revoke all on public.entregador_links from anon, authenticated;

-- A gestão pega (ou troca, com p_novo) o link de quem está na lista.
create or replace function public.link_do_entregador(p_salao uuid, p_nome text, p_novo boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_nome text := left(btrim(coalesce(p_nome, '')), 40); v_token uuid;
begin
  if not public.ve_agenda_toda(p_salao) then
    raise exception 'Só o balcão e a gestão mandam o link do entregador.' using errcode = 'insufficient_privilege';
  end if;
  if not (public.cfg_pedidos(p_salao)->'entregadores') ? v_nome then
    raise exception 'Ponha o entregador na lista (Entrega e pagamento) antes.' using errcode = 'check_violation';
  end if;
  insert into public.entregador_links (salao_id, nome) values (p_salao, v_nome)
  on conflict (salao_id, nome) do update
     set token = case when coalesce(p_novo, false) then gen_random_uuid() else entregador_links.token end,
         criado_em = case when coalesce(p_novo, false) then now() else entregador_links.criado_em end
  returning token into v_token;
  return jsonb_build_object('nome', v_nome, 'token', v_token);
end $$;

-- Quem é o dono do link — e só vale se o nome ainda estiver na lista da casa.
create or replace function public.entregador_do_link(p_token uuid)
returns public.entregador_links language sql stable security definer set search_path = public as $$
  select l.* from public.entregador_links l join public.saloes s on s.id = l.salao_id
   where l.token = p_token and s.status = 'ativo'
     and (public.cfg_pedidos(l.salao_id)->'entregadores') ? l.nome
$$;

-- O que o entregador vê: as entregas com ele e o resumo do dia.
create or replace function public.entregas_do_entregador(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare l public.entregador_links; s public.saloes; v_hoje date;
begin
  l := public.entregador_do_link(p_token);
  if l.salao_id is null then return jsonb_build_object('ok', false); end if;
  select * into s from public.saloes where id = l.salao_id;
  v_hoje := (now() at time zone coalesce(s.fuso, 'America/Sao_Paulo'))::date;
  return jsonb_build_object(
    'ok', true, 'entregador', l.nome, 'casa', s.nome,
    'telefoneCasa', coalesce(s.whatsapp, s.telefone),
    'cidade', concat_ws(' - ', nullif(btrim(s.endereco->>'cidade'), ''), nullif(btrim(s.endereco->>'uf'), '')),
    'caminho', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'numero', p.numero, 'nome', p.nome, 'telefone', p.telefone,
        'endereco', p.endereco, 'bairro', p.bairro, 'total', p.total, 'pagamento', p.pagamento,
        'troco', p.troco_para, 'observacao', p.observacao, 'saiuEm', p.saiu_em,
        'itens', (select coalesce(jsonb_agg(jsonb_build_object('nome', i.nome, 'quantidade', i.quantidade)
                    order by i.ordem), '[]'::jsonb) from public.pedido_itens i where i.pedido_id = p.id))
        order by p.saiu_em, p.numero)
      from public.pedidos p
     where p.salao_id = l.salao_id and p.status = 'saiu' and p.tipo_entrega = 'entrega' and p.entregador = l.nome), '[]'::jsonb),
    'hoje', coalesce(public.contas_dos_entregadores(l.salao_id, v_hoje, v_hoje, l.nome)->0, jsonb_build_object(
        'entregador', l.nome, 'entregas', 0, 'dinheiro', 0, 'ganha', 0, 'saldo', 0)),
    'entregues', coalesce((select jsonb_agg(jsonb_build_object('numero', p.numero, 'bairro', p.bairro,
        'total', p.total, 'pagamento', p.pagamento, 'entregueEm', p.entregue_em) order by p.entregue_em desc)
      from public.pedidos p
     where p.salao_id = l.salao_id and p.status = 'entregue' and p.tipo_entrega = 'entrega' and p.entregador = l.nome
       and (p.entregue_em at time zone coalesce(s.fuso, 'America/Sao_Paulo'))::date = v_hoje), '[]'::jsonb));
end $$;

-- O entregador marca "Entregue" — só pedido que está com ele, a caminho.
create or replace function public.entregador_entregou(p_token uuid, p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.entregador_links; v public.pedidos;
begin
  l := public.entregador_do_link(p_token);
  if l.salao_id is null then
    raise exception 'Este link de entregador não vale mais. Peça outro ao restaurante.' using errcode = 'insufficient_privilege';
  end if;
  select * into v from public.pedidos where id = p_pedido for update;
  if v.id is null or v.salao_id <> l.salao_id or v.entregador is distinct from l.nome then
    raise exception 'Este pedido não está com você.' using errcode = 'insufficient_privilege';
  end if;
  if v.status <> 'saiu' then
    raise exception 'Este pedido não está mais a caminho.' using errcode = 'check_violation';
  end if;
  update public.pedidos set status = 'entregue', entregue_em = now() where id = v.id;
  update public.notificacoes set status = 'cancelado', motivo = 'o pedido mudou de etapa'
   where pedido_id = v.id and status = 'pendente';
  return jsonb_build_object('ok', true, 'numero', v.numero);
end $$;

revoke all on function public.contas_dos_entregadores(uuid, date, date, text) from public, anon, authenticated;
revoke all on function public.entregador_do_link(uuid) from public, anon, authenticated;
revoke all on function public.acerto_entregadores(uuid, date, date) from public, anon;
grant execute on function public.acerto_entregadores(uuid, date, date) to authenticated;
revoke all on function public.link_do_entregador(uuid, text, boolean) from public, anon;
grant execute on function public.link_do_entregador(uuid, text, boolean) to authenticated;
revoke all on function public.entregas_do_entregador(uuid) from public;
grant execute on function public.entregas_do_entregador(uuid) to anon, authenticated;
revoke all on function public.entregador_entregou(uuid, uuid) from public;
grant execute on function public.entregador_entregou(uuid, uuid) to anon, authenticated;
revoke all on function public.cfg_pedidos(uuid) from public, anon, authenticated;
revoke all on function public.pedidos_da_casa(text) from public;
grant execute on function public.pedidos_da_casa(text) to anon, authenticated;

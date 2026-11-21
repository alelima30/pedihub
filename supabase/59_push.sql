-- ===========================================================================
-- 59_push.sql — avisos no celular (push), sem gastar a franquia de mensagens
--
-- ── O QUE É ───────────────────────────────────────────────────────────────
-- O aviso que faz o celular tocar com o app fechado, como o WhatsApp faz:
-- horário novo pelo link, horário cancelado pela cliente, pedido novo. É o
-- Web Push do próprio navegador — de graça, sem Meta no meio, e por isso
-- NUNCA desconta da franquia de mensagens do plano.
--
-- Cada pessoa da equipe liga no próprio aparelho (Meu negócio →
-- Notificações). No iPhone só funciona com o PediHub instalado na tela de
-- início; no Android funciona direto. Quem nunca ligou não recebe nada, e
-- nada deste arquivo muda o WhatsApp das clientes.
--
-- ── AS TRÊS PEÇAS ─────────────────────────────────────────────────────────
-- push_config    as chaves do correio (VAPID). O worker gera UMA vez e
--                guarda aqui; a pública vai ao painel na hora de ligar.
--                Trocar as chaves mataria TODAS as inscrições — por isso
--                `push_config_gravar` se recusa a sobrescrever.
-- push_aparelhos cada celular/computador que pediu para ser avisado, amarrado
--                à PESSOA (perfil) e ao salão. A pessoa vê e remove só os
--                dela. O endereço (endpoint) é um segredo do navegador:
--                quem o tem consegue mandar aviso — então ninguém além do
--                worker o lê de volta.
-- push_fila      o que falta entregar, uma linha por aparelho, no mesmo
--                desenho da fila do WhatsApp: o worker pega com
--                `push_proxima`, entrega, e anota com `push_resultado`.
--                Nada é marcado enviado sem ter sido enviado.
--
-- ── QUEM É AVISADO (v1) ───────────────────────────────────────────────────
-- Quem cuida do balcão (dono, admin, recepção) recebe tudo; quem atende
-- recebe o que é da própria agenda. Sempre limitado a quem LIGOU o aviso
-- naquele aparelho.
--
--   horário novo pelo link       → balcão + quem vai atender
--   horário cancelado de fora    → balcão + quem ia atender (inclui o
--     (pela cliente, ou o sinal     cancelamento automático por sinal
--      que venceu)                  vencido — o horário voltou a ficar livre)
--   pedido novo (restaurante)    → balcão
--   pedido da loja               → balcão
--
-- Cancelamento FEITO PELA EQUIPE não avisa: foi a própria casa que mexeu.
-- A peneira é `e_equipe()`: quem cancela de dentro está logado com papel de
-- equipe; a cliente (com ou sem login) e o worker do sinal, não.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) AS CHAVES DO CORREIO
-- ---------------------------------------------------------------------------
create table if not exists public.push_config (
  um        boolean primary key default true check (um),   -- uma linha só
  chaves    jsonb not null,       -- { publica, privadaJwk, contato }
  criado_em timestamptz not null default now()
);
alter table public.push_config enable row level security;
revoke all on table public.push_config from public, anon, authenticated;

create or replace function public.push_config_ler()
returns jsonb language sql stable security definer set search_path = public as $$
  select chaves from public.push_config
$$;

-- Grava SÓ quando ainda não há chave. Sobrescrever desligaria o aviso de
-- todo mundo sem ninguém perceber: as inscrições dos aparelhos são amarradas
-- à chave pública, e uma chave nova as torna todas inválidas.
create or replace function public.push_config_gravar(p_chaves jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if jsonb_typeof(p_chaves) <> 'object'
     or coalesce(p_chaves->>'publica', '') = ''
     or p_chaves->'privadaJwk' is null then
    raise exception 'Chaves incompletas.' using errcode = 'check_violation';
  end if;
  insert into public.push_config (chaves) values (p_chaves)
  on conflict (um) do nothing;
  return (select chaves from public.push_config);
end $$;

-- A chave pública não é segredo (todo visitante da página a recebe no
-- `subscribe`), mas só a equipe logada tem o que fazer com ela.
create or replace function public.push_chave_publica()
returns text language sql stable security definer set search_path = public as $$
  select chaves->>'publica' from public.push_config
$$;

-- ---------------------------------------------------------------------------
-- 2) OS APARELHOS
-- ---------------------------------------------------------------------------
create table if not exists public.push_aparelhos (
  id        uuid primary key default gen_random_uuid(),
  salao_id  uuid not null references public.saloes(id) on delete cascade,
  perfil_id uuid not null,         -- a pessoa; sem FK para auth por desenho
  endpoint  text not null check (endpoint like 'https://%' and length(endpoint) <= 1024),
  p256dh    text not null check (length(p256dh) between 32 and 256),
  auth      text not null check (length(auth) between 8 and 64),
  rotulo    text,                  -- "Celular · Chrome", escolhido pela tela
  falhas    int  not null default 0,
  criado_em timestamptz not null default now(),
  unique (salao_id, endpoint)
);
create index if not exists ix_push_aparelho_perfil on public.push_aparelhos(perfil_id, salao_id);
alter table public.push_aparelhos enable row level security;
revoke all on table public.push_aparelhos from public, anon, authenticated;

create or replace function public.push_registrar(
  p_salao uuid, p_endpoint text, p_p256dh text, p_auth text, p_rotulo text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null or not public.e_equipe(p_salao) then
    raise exception 'Só a equipe do salão liga os avisos.' using errcode = 'insufficient_privilege';
  end if;
  -- Teto por pessoa: aparelho trocado re-registra com outro endpoint, e sem
  -- teto a lista só cresce. Vinte dá para família inteira de aparelhos.
  select count(*) into n from public.push_aparelhos
   where salao_id = p_salao and perfil_id = auth.uid();
  if n >= 20 and not exists (select 1 from public.push_aparelhos
     where salao_id = p_salao and endpoint = p_endpoint) then
    delete from public.push_aparelhos where id in (
      select id from public.push_aparelhos
       where salao_id = p_salao and perfil_id = auth.uid()
       order by criado_em asc limit 1);
  end if;
  insert into public.push_aparelhos (salao_id, perfil_id, endpoint, p256dh, auth, rotulo)
  values (p_salao, auth.uid(), p_endpoint, p_p256dh, p_auth,
          nullif(left(btrim(coalesce(p_rotulo, '')), 80), ''))
  on conflict (salao_id, endpoint) do update
     set perfil_id = excluded.perfil_id, p256dh = excluded.p256dh,
         auth = excluded.auth, falhas = 0,
         rotulo = coalesce(excluded.rotulo, push_aparelhos.rotulo);
  return jsonb_build_object('ok', true);
end $$;

-- A pessoa remove um aparelho DELA (pelo endpoint, que só o aparelho sabe).
create or replace function public.push_remover(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then
    raise exception 'Sem login.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.push_aparelhos
   where endpoint = p_endpoint and perfil_id = auth.uid();
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removidos', n);
end $$;

-- E remove pela lista da tela (o id), também só o dela.
create or replace function public.push_remover_aparelho(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then
    raise exception 'Sem login.' using errcode = 'insufficient_privilege';
  end if;
  delete from public.push_aparelhos where id = p_id and perfil_id = auth.uid();
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'removidos', n);
end $$;

-- A lista da tela: SÓ os aparelhos de quem pergunta, e sem o endpoint — o
-- endereço é o segredo que permite mandar aviso, e a tela não precisa dele.
create or replace function public.push_meus_aparelhos(p_salao uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'rotulo', a.rotulo, 'criadoEm', a.criado_em,
           'falhas', a.falhas) order by a.criado_em), '[]'::jsonb)
    from public.push_aparelhos a
   where a.salao_id = p_salao and a.perfil_id = auth.uid()
$$;

-- Este aparelho (pelo endpoint, que só ele sabe) está ligado NESTE salão,
-- para QUEM pergunta? A inscrição do navegador é uma só para todos os
-- salões; ligar num não liga no outro.
create or replace function public.push_ligado(p_salao uuid, p_endpoint text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.push_aparelhos a
                  where a.salao_id = p_salao and a.endpoint = p_endpoint
                    and a.perfil_id = auth.uid())
$$;

-- ---------------------------------------------------------------------------
-- 3) A FILA
-- ---------------------------------------------------------------------------
create table if not exists public.push_fila (
  id          bigint generated always as identity primary key,
  salao_id    uuid not null references public.saloes(id) on delete cascade,
  aparelho_id uuid not null references public.push_aparelhos(id) on delete cascade,
  titulo      text not null check (length(titulo) <= 80),
  corpo       text not null check (length(corpo) <= 200),
  url         text not null default './app.html',
  chave       text unique,
  status      text not null default 'pendente'
              check (status in ('pendente','enviando','enviado','falhou','cancelado')),
  tentativas  int not null default 0,
  motivo      text,
  criado_em   timestamptz not null default now(),
  tentada_em  timestamptz,
  enviado_em  timestamptz
);
create index if not exists ix_push_fila_pend on public.push_fila(status, id) where status = 'pendente';
alter table public.push_fila enable row level security;
revoke all on table public.push_fila from public, anon, authenticated;

-- Enfileira para cada aparelho das pessoas certas. Quem não ligou o aviso
-- não tem aparelho e não ganha linha. `p_chave` segura o repetido: o mesmo
-- fato, re-disparado, não toca duas vezes no mesmo aparelho.
create or replace function public.push_avisar(
  p_salao uuid, p_perfis uuid[], p_titulo text, p_corpo text,
  p_url text default './app.html', p_chave text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into public.push_fila (salao_id, aparelho_id, titulo, corpo, url, chave)
  select a.salao_id, a.id, left(p_titulo, 80), left(coalesce(p_corpo, ''), 200),
         coalesce(p_url, './app.html'),
         case when p_chave is null then null else p_chave || ':' || a.id end
    from public.push_aparelhos a
   where a.salao_id = p_salao and a.perfil_id = any(p_perfis)
  on conflict (chave) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Quem cuida do balcão: dono, admin e recepção, com vínculo vivo.
create or replace function public.push_quem_cuida(p_salao uuid)
returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(v.perfil_id), '{}')
    from public.vinculos v
   where v.salao_id = p_salao and v.status = 'ativo'
     and v.papel in ('dono', 'admin', 'recepcao')
$$;

-- ── O worker pega e anota ──────────────────────────────────────────────────
create or replace function public.push_proxima(p_lote int default 5)
returns table (id bigint, titulo text, corpo text, url text,
               endpoint text, p256dh text, auth text)
language plpgsql security definer set search_path = public as $$
begin
  -- Aviso velho não toca: "horário novo" de duas horas atrás só confunde.
  update public.push_fila f
     set status = 'cancelado', motivo = 'venceu'
   where f.status = 'pendente' and f.criado_em < now() - interval '2 hours';
  -- O 'enviando' órfão de um worker que caiu volta para a fila.
  update public.push_fila f
     set status = 'pendente'
   where f.status = 'enviando'
     and coalesce(f.tentada_em, f.criado_em) < now() - interval '10 minutes';

  return query
  with pega as (
    select f.id from public.push_fila f
     where f.status = 'pendente'
     order by f.id
     for update skip locked
     limit greatest(1, least(p_lote, 20))
  )
  update public.push_fila f
     set status = 'enviando', tentativas = f.tentativas + 1, tentada_em = now()
    from pega, public.push_aparelhos a
   where f.id = pega.id and a.id = f.aparelho_id
  returning f.id, f.titulo, f.corpo, f.url, a.endpoint, a.p256dh, a.auth;
end $$;

create or replace function public.push_resultado(p_id bigint, p_ok boolean, p_codigo text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_ap uuid;
begin
  select aparelho_id into v_ap from public.push_fila where id = p_id;
  if v_ap is null then return; end if;

  if p_ok then
    update public.push_fila set status = 'enviado', enviado_em = now(), motivo = null
     where id = p_id;
    update public.push_aparelhos set falhas = 0 where id = v_ap;
    return;
  end if;

  /* 404/410 do serviço de push: a inscrição morreu (app desinstalado,
     permissão revogada). O aparelho sai — e leva junto, pelo cascade, o que
     ainda estava na fila para ele. Guardar aparelho morto é mandar para
     ninguém em toda volta do worker. */
  if p_codigo = 'sumiu' then
    delete from public.push_aparelhos where id = v_ap;
    return;
  end if;

  update public.push_fila
     set status = case when tentativas >= 3 then 'falhou' else 'pendente' end,
         motivo = left(coalesce(p_codigo, 'falhou'), 120)
   where id = p_id;
  update public.push_aparelhos set falhas = falhas + 1 where id = v_ap;
end $$;

-- O botão "Mandar um aviso de teste": só para os aparelhos de quem tocou,
-- e no máximo um por minuto (a chave repete dentro do mesmo minuto).
create or replace function public.push_testar(p_salao uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null or not public.e_equipe(p_salao) then
    raise exception 'Só a equipe do salão testa os avisos.' using errcode = 'insufficient_privilege';
  end if;
  n := public.push_avisar(p_salao, array[auth.uid()], 'Aviso de teste',
         'Se você está lendo isto, os avisos do PediHub chegam neste aparelho.',
         './app.html', 'teste:' || auth.uid() || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
  return jsonb_build_object('ok', true, 'aparelhos', n);
end $$;

-- ---------------------------------------------------------------------------
-- 4) OS GATILHOS — o que vira aviso
-- ---------------------------------------------------------------------------
create or replace function public.tg_push_agendamento()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_fuso text; v_quem text; v_prof uuid; v_nome text;
begin
  if new.origem <> 'online' or new.status not in ('pendente', 'confirmado')
     or new.arquivado_em is not null then
    return null;
  end if;
  select coalesce(nullif(s.fuso, ''), 'America/Sao_Paulo') into v_fuso
    from public.saloes s where s.id = new.salao_id;
  select p.perfil_id, coalesce(p.apelido, p.nome) into v_prof, v_nome
    from public.profissionais p where p.id = new.profissional_id;
  v_quem := coalesce(nullif(btrim(coalesce(new.atendido_nome, '')), ''),
                     (select c.nome from public.clientes c where c.id = new.cliente_id),
                     'Cliente');
  perform public.push_avisar(new.salao_id,
    public.push_quem_cuida(new.salao_id) || coalesce(v_prof, '00000000-0000-0000-0000-000000000000'),
    'Horário novo pelo link',
    v_quem || ' · ' || to_char(new.inicio at time zone v_fuso, 'DD/MM "às" HH24:MI')
           || coalesce(' · com ' || v_nome, ''),
    './app.html#agenda',
    'ag-novo:' || new.id);
  return null;
end $$;

drop trigger if exists tg_push_agendamento on public.agendamentos;
create trigger tg_push_agendamento
  after insert on public.agendamentos
  for each row execute function public.tg_push_agendamento();

create or replace function public.tg_push_cancelado()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_fuso text; v_quem text; v_prof uuid; v_motivo text;
begin
  if old.status not in ('pendente', 'confirmado') or new.status <> 'cancelado' then
    return null;
  end if;
  if new.inicio <= now() then return null; end if;   -- passado não toca
  /* Cancelou de dentro (recepção, dono, quem atende)? A casa já sabe. A
     cliente pelo link — logada ou não — e o robô do sinal vencido, não. */
  if public.e_equipe(new.salao_id) then return null; end if;

  select coalesce(nullif(s.fuso, ''), 'America/Sao_Paulo') into v_fuso
    from public.saloes s where s.id = new.salao_id;
  select p.perfil_id into v_prof
    from public.profissionais p where p.id = new.profissional_id;
  v_quem := coalesce(nullif(btrim(coalesce(new.atendido_nome, '')), ''),
                     (select c.nome from public.clientes c where c.id = new.cliente_id),
                     'Cliente');
  v_motivo := case when new.cancelado_motivo = 'sinal não pago no prazo'
                   then ' · sinal não pago' else '' end;
  perform public.push_avisar(new.salao_id,
    public.push_quem_cuida(new.salao_id) || coalesce(v_prof, '00000000-0000-0000-0000-000000000000'),
    'Horário cancelado',
    v_quem || ' · ' || to_char(new.inicio at time zone v_fuso, 'DD/MM "às" HH24:MI')
           || v_motivo || ' — a vaga voltou a ficar livre',
    './app.html#agenda',
    'ag-cancel:' || new.id);
  return null;
end $$;

drop trigger if exists tg_push_cancelado on public.agendamentos;
create trigger tg_push_cancelado
  after update of status on public.agendamentos
  for each row execute function public.tg_push_cancelado();

create or replace function public.tg_push_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_avisar(new.salao_id, public.push_quem_cuida(new.salao_id),
    'Pedido novo',
    coalesce(nullif(btrim(coalesce(new.nome, '')), ''), 'Cliente')
      || ' · R$ ' || replace(to_char(coalesce(new.total, 0), 'FM999990.00'), '.', ',')
      || case when new.tipo_entrega = 'entrega' then ' · entrega' else ' · retirada' end,
    './app.html#pedidos',
    'pedido:' || new.id);
  return null;
end $$;

drop trigger if exists tg_push_pedido on public.pedidos;
create trigger tg_push_pedido
  after insert on public.pedidos
  for each row execute function public.tg_push_pedido();

create or replace function public.tg_push_pedido_loja()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.push_avisar(new.salao_id, public.push_quem_cuida(new.salao_id),
    'Pedido da loja',
    coalesce((select c.nome from public.clientes c where c.id = new.cliente_id), 'Cliente')
      || ' · R$ ' || replace(to_char(coalesce(new.total_estimado, 0), 'FM999990.00'), '.', ','),
    './app.html#pedidos',
    'pedido-loja:' || new.id);
  return null;
end $$;

drop trigger if exists tg_push_pedido_loja on public.pedidos_loja;
create trigger tg_push_pedido_loja
  after insert on public.pedidos_loja
  for each row execute function public.tg_push_pedido_loja();

-- ---------------------------------------------------------------------------
-- 5) QUEM CHAMA O QUÊ
-- ---------------------------------------------------------------------------
revoke all on function public.push_config_ler()                       from public, anon, authenticated;
revoke all on function public.push_config_gravar(jsonb)               from public, anon, authenticated;
revoke all on function public.push_proxima(int)                       from public, anon, authenticated;
revoke all on function public.push_resultado(bigint, boolean, text)   from public, anon, authenticated;
revoke all on function public.push_avisar(uuid, uuid[], text, text, text, text) from public, anon, authenticated;
revoke all on function public.push_quem_cuida(uuid)                   from public, anon, authenticated;
revoke all on function public.tg_push_agendamento()                   from public, anon, authenticated;
revoke all on function public.tg_push_cancelado()                     from public, anon, authenticated;
revoke all on function public.tg_push_pedido()                        from public, anon, authenticated;
revoke all on function public.tg_push_pedido_loja()                   from public, anon, authenticated;
grant execute on function public.push_config_ler()                     to service_role;
grant execute on function public.push_config_gravar(jsonb)             to service_role;
grant execute on function public.push_proxima(int)                     to service_role;
grant execute on function public.push_resultado(bigint, boolean, text) to service_role;

revoke all on function public.push_chave_publica()        from public, anon;
revoke all on function public.push_registrar(uuid, text, text, text, text) from public, anon;
revoke all on function public.push_remover(text)          from public, anon;
revoke all on function public.push_remover_aparelho(uuid) from public, anon;
revoke all on function public.push_meus_aparelhos(uuid)   from public, anon;
revoke all on function public.push_ligado(uuid, text)     from public, anon;
revoke all on function public.push_testar(uuid)           from public, anon;
grant execute on function public.push_chave_publica()        to authenticated;
grant execute on function public.push_registrar(uuid, text, text, text, text) to authenticated;
grant execute on function public.push_remover(text)          to authenticated;
grant execute on function public.push_remover_aparelho(uuid) to authenticated;
grant execute on function public.push_meus_aparelhos(uuid)   to authenticated;
grant execute on function public.push_ligado(uuid, text)     to authenticated;
grant execute on function public.push_testar(uuid)           to authenticated;

-- ===========================================================================
-- PediHub — avaliação do pedido (80)
--
-- Depois de ENTREGUE, quem pediu dá de 1 a 5 estrelas e, se quiser, um
-- comentário. Só pelo link do próprio pedido (o token que só ela tem), uma
-- avaliação por pedido (pode trocar em até 15 dias), e nunca antes de
-- entregue: avaliar um pedido que ainda não chegou é avaliar a espera.
--
--   avaliar_pedido(token, nota, comentário)   a cliente avalia (anon)
--   avaliacao_do_pedido(token)                o que ela já deu, e se ainda pode
--   avaliacoes_da_casa(slug)                  o que o LINK mostra: a média e os
--                                             comentários bons (4 e 5 estrelas)
--   avaliacoes_do_restaurante(salão)          o painel: tudo, com as ruins
--   ocultar_avaliacao(id, sim/não)            a gestão tira um comentário do link
--
-- A tabela não tem porta direta: RLS ligado e nenhuma policy. Tudo passa
-- pelas funções, que conferem token, status e papel.
-- ===========================================================================

create table if not exists public.avaliacoes (
  id            uuid primary key default gen_random_uuid(),
  salao_id      uuid not null references public.saloes(id) on delete cascade,
  pedido_id     uuid not null unique references public.pedidos(id) on delete cascade,
  nota          smallint not null check (nota between 1 and 5),
  comentario    text check (comentario is null or char_length(comentario) <= 500),
  nome          text,
  oculta        boolean not null default false,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists avaliacoes_do_salao on public.avaliacoes (salao_id, criado_em desc);
alter table public.avaliacoes enable row level security;
revoke all on public.avaliacoes from public, anon, authenticated;

-- ── A cliente avalia ───────────────────────────────────────────────────────
create or replace function public.avaliar_pedido(p_token uuid, p_nota integer, p_comentario text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.pedidos; v_txt text;
begin
  select * into v from public.pedidos where token = p_token;
  if v.id is null then
    raise exception 'Não achei este pedido.' using errcode = 'no_data_found';
  end if;
  if v.status <> 'entregue' then
    raise exception 'Dá para avaliar depois que o pedido for entregue.' using errcode = 'check_violation';
  end if;
  if coalesce(v.entregue_em, v.criado_em) < now() - interval '15 days' then
    raise exception 'O prazo para avaliar este pedido já acabou.' using errcode = 'check_violation';
  end if;
  if p_nota is null or p_nota not between 1 and 5 then
    raise exception 'Escolha de 1 a 5 estrelas.' using errcode = 'check_violation';
  end if;
  v_txt := nullif(left(btrim(regexp_replace(coalesce(p_comentario, ''), '\s+', ' ', 'g')), 500), '');
  insert into public.avaliacoes (salao_id, pedido_id, nota, comentario, nome)
  values (v.salao_id, v.id, p_nota, v_txt,
          nullif(left(split_part(btrim(coalesce(v.nome, '')), ' ', 1), 40), ''))
  on conflict (pedido_id) do update
    set nota = excluded.nota, comentario = excluded.comentario, atualizado_em = now();
  return jsonb_build_object('ok', true, 'nota', p_nota, 'comentario', v_txt);
end $$;
revoke all on function public.avaliar_pedido(uuid, integer, text) from public;
grant execute on function public.avaliar_pedido(uuid, integer, text) to anon, authenticated;

-- ── O que ela já deu, e se ainda pode avaliar ──────────────────────────────
create or replace function public.avaliacao_do_pedido(p_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
           'pode', p.status = 'entregue'
                   and coalesce(p.entregue_em, p.criado_em) >= now() - interval '15 days',
           'nota', a.nota, 'comentario', a.comentario)
    from public.pedidos p
    left join public.avaliacoes a on a.pedido_id = p.id
   where p.token = p_token
$$;
revoke all on function public.avaliacao_do_pedido(uuid) from public;
grant execute on function public.avaliacao_do_pedido(uuid) to anon, authenticated;

-- ── O que o link mostra ────────────────────────────────────────────────────
-- A média e o total contam TODAS as notas (a tela decide se mostra); os
-- comentários que saem são só os bons (4 e 5), com texto, e que a gestão não
-- escondeu. Nunca sai telefone, número do pedido nem sobrenome.
create or replace function public.avaliacoes_da_casa(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'total', (select count(*) from public.avaliacoes a where a.salao_id = s.id),
    'media', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where a.salao_id = s.id),
    'recentes', coalesce((
      select jsonb_agg(jsonb_build_object('nome', coalesce(x.nome, 'Cliente'), 'nota', x.nota,
                                          'comentario', x.comentario, 'quando', x.criado_em::date)
                       order by x.criado_em desc)
        from (select a.* from public.avaliacoes a
               where a.salao_id = s.id and a.nota >= 4 and a.comentario is not null and not a.oculta
               order by a.criado_em desc limit 8) x), '[]'::jsonb))
    from public.saloes s
   where s.slug = p_slug and s.status = 'ativo'
$$;
revoke all on function public.avaliacoes_da_casa(text) from public;
grant execute on function public.avaliacoes_da_casa(text) to anon, authenticated;

-- ── O painel: tudo, com as ruins ───────────────────────────────────────────
create or replace function public.avaliacoes_do_restaurante(p_salao uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só a gestão do restaurante vê as avaliações.' using errcode = 'insufficient_privilege';
  end if;
  return jsonb_build_object(
    'total', (select count(*) from public.avaliacoes a where a.salao_id = p_salao),
    'media', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where a.salao_id = p_salao),
    'estrelas', (select jsonb_object_agg(n::text, (select count(*) from public.avaliacoes a
                                                    where a.salao_id = p_salao and a.nota = n))
                   from generate_series(1, 5) n),
    'lista', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'numero', p.numero, 'nome', coalesce(a.nome, p.nome), 'nota', a.nota,
               'comentario', a.comentario, 'quando', a.criado_em, 'oculta', a.oculta,
               'entrega', p.tipo_entrega, 'mesa', p.mesa,
               'itens', (select string_agg(i.quantidade || '× ' || i.nome, ', ' order by i.nome)
                           from public.pedido_itens i where i.pedido_id = p.id))
             order by a.criado_em desc)
        from (select * from public.avaliacoes where salao_id = p_salao
               order by criado_em desc limit 300) a
        join public.pedidos p on p.id = a.pedido_id), '[]'::jsonb));
end $$;
revoke all on function public.avaliacoes_do_restaurante(uuid) from public, anon;
grant execute on function public.avaliacoes_do_restaurante(uuid) to authenticated;

-- ── A gestão tira (ou devolve) um comentário do link ───────────────────────
create or replace function public.ocultar_avaliacao(p_avaliacao uuid, p_oculta boolean)
returns void language plpgsql security definer set search_path = public as $$
declare v_salao uuid;
begin
  select salao_id into v_salao from public.avaliacoes where id = p_avaliacao;
  if v_salao is null or not public.e_gestor(v_salao) then
    raise exception 'Só a gestão do restaurante mexe nas avaliações.' using errcode = 'insufficient_privilege';
  end if;
  update public.avaliacoes set oculta = coalesce(p_oculta, false) where id = p_avaliacao;
end $$;
revoke all on function public.ocultar_avaliacao(uuid, boolean) from public, anon;
grant execute on function public.ocultar_avaliacao(uuid, boolean) to authenticated;

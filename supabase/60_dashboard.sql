-- ===========================================================================
-- 60_dashboard.sql — o Ranking: quem mais marca, quem mais atende, quem é
--                    nova, quem volta, e quantos abrem o link
--
-- O pedido: "quem mais marcou, quem foi a pessoa que mais atendeu, quantas
-- pessoas novas entraram pelo link, os recorrentes, pessoas que visualizam
-- meu link — bem completo e com ranking".
--
-- ── DUAS PEÇAS ────────────────────────────────────────────────────────────
-- 1. O CONTADOR DE VISITAS DO LINK. Não existia: a página da cliente nunca
--    contou quem a abria. Passa a contar a partir de agora — não há como
--    saber o passado.
-- 2. A FUNÇÃO `dashboard(salao, de, ate)`, que devolve tudo de uma vez num
--    jsonb pequeno: a conta é feita onde o dado mora (ver o 12_relatorios).
--
-- ── AS VISITAS SÃO SÓ NÚMEROS ─────────────────────────────────────────────
-- Escolha do dono: contar sem saber quem é. A página guarda no aparelho um
-- código aleatório (não é nome, telefone nem conta), e o banco guarda só um
-- resumo embaralhado dele COM O DIA (md5 de restaurante + dia + código): a mesma
-- pessoa vira uma linha por dia, e duas linhas de dias diferentes não se
-- ligam. Dá para dizer "73 pessoas diferentes abriram o link hoje, 41 pelo
-- Instagram", e não dá para dizer "a Maria abriu". Sem dado pessoal, sem
-- aviso de cookies, sem risco com a LGPD.
--
-- Quem é da equipe abrindo o próprio link não conta: o dono confere a página
-- dez vezes por dia, e isso inflaria o número que ele quer ler.
--
-- ── QUEM VÊ O QUÊ ─────────────────────────────────────────────────────────
-- Do Básico para cima (como os Relatórios: a mesma chave `relatorios`).
-- A gestão (dono e admin) vê o restaurante inteiro. Quem atende vê SÓ os próprios
-- números: as clientes dela, os serviços dela, a posição dela — sem o
-- faturamento da casa, sem as outras profissionais, sem as visitas do link.
-- A recepção sem ficha de quem atende não vê (a regra dos Relatórios).
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1) AS VISITAS
-- ---------------------------------------------------------------------------
create table if not exists public.link_visitas (
  salao_id    uuid not null references public.saloes(id) on delete cascade,
  dia         date not null,
  visitante   text not null,           -- md5(restaurante + dia + código do aparelho)
  origem      text not null default 'direto'
              check (origem in ('instagram','whatsapp','facebook','google','tiktok','direto','outro')),
  vezes       int  not null default 1,
  primeira_em timestamptz not null default now(),
  primary key (salao_id, dia, visitante)
);
create index if not exists ix_link_visitas_dia on public.link_visitas(salao_id, dia);
alter table public.link_visitas enable row level security;
revoke all on table public.link_visitas from public, anon, authenticated;

/* A página da cliente chama ao abrir. Sem login, como a própria página.
   Nunca reclama: visita é estatística, e um erro aqui não pode atrapalhar
   quem veio marcar horário. */
create or replace function public.registrar_visita(p_slug text, p_visitante text, p_origem text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_salao uuid; v_fuso text; v_dia date; v_origem text; n int;
begin
  if p_visitante is null or p_visitante !~ '^[A-Za-z0-9_-]{16,64}$' then return; end if;
  select s.id, coalesce(nullif(s.fuso, ''), 'America/Sao_Paulo') into v_salao, v_fuso
    from public.saloes s where s.slug = p_slug and s.status = 'ativo';
  if v_salao is null then return; end if;
  -- A equipe olhando a própria página não é visita.
  if auth.uid() is not null and public.e_equipe(v_salao) then return; end if;

  v_dia := (now() at time zone v_fuso)::date;
  v_origem := lower(coalesce(p_origem, ''));
  if v_origem not in ('instagram','whatsapp','facebook','google','tiktok','direto') then
    v_origem := case when v_origem = '' then 'direto' else 'outro' end;
  end if;

  -- Teto por restaurante e por dia: códigos inventados em série não enchem o banco.
  select count(*) into n from public.link_visitas where salao_id = v_salao and dia = v_dia;
  if n >= 5000 then return; end if;

  insert into public.link_visitas (salao_id, dia, visitante, origem)
  values (v_salao, v_dia, md5(v_salao::text || v_dia::text || p_visitante), v_origem)
  on conflict (salao_id, dia, visitante)
  do update set vezes = least(public.link_visitas.vezes + 1, 100);
end $$;

-- ---------------------------------------------------------------------------
-- 2) O DASHBOARD
-- ---------------------------------------------------------------------------
create or replace function public.dashboard(p_salao uuid, p_de date, p_ate date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_gestor boolean;
  v_prof   uuid;          -- nulo = o restaurante inteiro
  v_fuso   text;
  v_ini    timestamptz;
  v_fim    timestamptz;
  v_ini_a  timestamptz;
  v_dias   int;
  r        jsonb;
begin
  if auth.uid() is null or p_salao is null or not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste restaurante.' using errcode = 'insufficient_privilege';
  end if;
  v_gestor := coalesce(public.e_gestor(p_salao), false);
  if not v_gestor then
    select p.id into v_prof from public.profissionais p
     where p.salao_id = p_salao and p.perfil_id = auth.uid() and p.ativo
     order by p.criado_em limit 1;
    if v_prof is null then
      raise exception 'O Ranking é da gestão do restaurante e de quem atende.'
        using errcode = 'insufficient_privilege';
    end if;
  end if;
  perform public.exigir_recurso(p_salao, 'relatorios', 'O Ranking');
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 400 then
    raise exception 'Confira as datas do período.' using errcode = 'check_violation';
  end if;

  select coalesce(nullif(fuso, ''), 'America/Sao_Paulo') into v_fuso
    from public.saloes where id = p_salao;
  v_ini   := (p_de::timestamp) at time zone v_fuso;
  v_fim   := ((p_ate + 1)::timestamp) at time zone v_fuso;
  v_dias  := (p_ate - p_de) + 1;
  v_ini_a := v_ini - make_interval(days => v_dias);

  with
  -- Toda a agenda do escopo (o restaurante, ou só a profissional), fora o arquivo.
  todos as (
    select a.* from public.agendamentos a
     where a.salao_id = p_salao and a.arquivado_em is null
       and (v_prof is null or a.profissional_id = v_prof)
  ),
  ag as (select * from todos where inicio >= v_ini and inicio < v_fim),
  ag_a as (select * from todos where inicio >= v_ini_a and inicio < v_ini),
  -- A primeira vez de cada cliente NO RESTAURANTE (horário que não foi cancelado).
  primeira as (
    select distinct on (a.cliente_id) a.cliente_id, a.inicio, a.origem, a.profissional_id
      from public.agendamentos a
     where a.salao_id = p_salao and a.cliente_id is not null
       and a.status <> 'cancelado' and a.arquivado_em is null
     order by a.cliente_id, a.inicio
  ),
  novas as (
    select * from primeira
     where inicio >= v_ini and inicio < v_fim
       and (v_prof is null or profissional_id = v_prof)
  ),
  novas_a as (
    select * from primeira
     where inicio >= v_ini_a and inicio < v_ini
       and (v_prof is null or profissional_id = v_prof)
  ),
  vieram as (       -- quem teve horário (não cancelado) no período
    select a.cliente_id, count(*) as n
      from ag a where a.cliente_id is not null and a.status <> 'cancelado'
     group by a.cliente_id
  ),
  por_cliente as (
    select a.cliente_id,
           count(*) filter (where a.status <> 'cancelado')                         as marcados,
           count(*) filter (where a.status = 'concluido')                          as atendidos,
           count(*) filter (where a.status = 'faltou')                             as faltas,
           coalesce(sum(a.valor_previsto) filter (where a.status = 'concluido'), 0) as valor,
           max(a.inicio) filter (where a.status <> 'cancelado')                    as ultima
      from ag a where a.cliente_id is not null
     group by a.cliente_id
  ),
  por_prof as (
    select a.profissional_id,
           count(*) filter (where a.status = 'concluido')                          as atendidos,
           count(*) filter (where a.status <> 'cancelado')                         as marcados,
           count(*) filter (where a.status = 'faltou')                             as faltas,
           count(*) filter (where a.status = 'cancelado')                          as cancelados,
           count(*) filter (where a.origem = 'online' and a.status <> 'cancelado') as pelo_link,
           count(distinct a.cliente_id) filter (where a.status = 'concluido')      as clientes,
           coalesce(sum(a.valor_previsto) filter (where a.status = 'concluido'), 0) as valor
      from ag a group by a.profissional_id
  ),
  visitas as (
    select * from public.link_visitas v
     where v.salao_id = p_salao and v.dia between p_de and p_ate and v_prof is null
  )
  select jsonb_build_object(
    'de', p_de, 'ate', p_ate, 'dias', v_dias,
    'escopo', case when v_prof is null then 'salao' else 'meu' end,

    -- ── O RESUMO, COM O PERÍODO ANTERIOR DO MESMO TAMANHO ──────────────────
    'resumo', jsonb_build_object(
      'marcados',   (select count(*) from ag where status <> 'cancelado'),
      'atendidos',  (select count(*) from ag where status = 'concluido'),
      'cancelados', (select count(*) from ag where status = 'cancelado'),
      'faltas',     (select count(*) from ag where status = 'faltou'),
      'peloLink',   (select count(*) from ag where origem = 'online' and status <> 'cancelado'),
      'valor',      (select coalesce(sum(valor_previsto), 0) from ag where status = 'concluido'),
      'clientes',   (select count(*) from vieram),
      'novas',      (select count(*) from novas),
      'novasPeloLink', (select count(*) from novas where origem = 'online'),
      'novasNoBalcao', (select count(*) from novas where origem <> 'online'),
      /* Voltaram: tiveram horário no período E já tinham vindo antes dele. */
      'recorrentes', (select count(*) from vieram v
                       where exists (select 1 from todos t
                                      where t.cliente_id = v.cliente_id
                                        and t.status <> 'cancelado' and t.inicio < v_ini)),
      'maisDeUmaVez', (select count(*) from vieram where n >= 2),
      'cadastrosPeloLink', case when v_prof is null then
          (select count(*) from public.clientes c
            where c.salao_id = p_salao and c.pelo_link
              and c.criado_em >= v_ini and c.criado_em < v_fim) end
    ),
    'antes', jsonb_build_object(
      'marcados',  (select count(*) from ag_a where status <> 'cancelado'),
      'atendidos', (select count(*) from ag_a where status = 'concluido'),
      'peloLink',  (select count(*) from ag_a where origem = 'online' and status <> 'cancelado'),
      'valor',     (select coalesce(sum(valor_previsto), 0) from ag_a where status = 'concluido'),
      'novas',     (select count(*) from novas_a),
      'visitantes', case when v_prof is null then
          (select count(*) from public.link_visitas v where v.salao_id = p_salao
             and v.dia between p_de - v_dias and p_de - 1) end
    ),

    -- ── OS RANKINGS ────────────────────────────────────────────────────────
    'clientesQueMaisMarcaram', coalesce((
      select jsonb_agg(t.x order by t.ord) from (
        select row_number() over (order by pc.marcados desc, pc.valor desc, c.nome) as ord,
               jsonb_build_object('nome', c.nome, 'marcados', pc.marcados, 'atendidos', pc.atendidos,
                                  'faltas', pc.faltas, 'valor', pc.valor,
                                  'ultima', pc.ultima) as x
          from por_cliente pc join public.clientes c on c.id = pc.cliente_id
         where pc.marcados > 0
         order by pc.marcados desc, pc.valor desc, c.nome limit 10) t), '[]'::jsonb),

    'clientesQueMaisGastaram', coalesce((
      select jsonb_agg(t.x order by t.ord) from (
        select row_number() over (order by pc.valor desc, pc.atendidos desc, c.nome) as ord,
               jsonb_build_object('nome', c.nome, 'valor', pc.valor, 'atendidos', pc.atendidos) as x
          from por_cliente pc join public.clientes c on c.id = pc.cliente_id
         where pc.valor > 0
         order by pc.valor desc, pc.atendidos desc, c.nome limit 10) t), '[]'::jsonb),

    'profissionais', coalesce((
      select jsonb_agg(t.x order by t.ord) from (
        select row_number() over (order by pp.atendidos desc, pp.valor desc, p.nome) as ord,
               jsonb_build_object('nome', coalesce(p.apelido, p.nome), 'atendidos', pp.atendidos,
                                  'marcados', pp.marcados, 'faltas', pp.faltas,
                                  'cancelados', pp.cancelados, 'peloLink', pp.pelo_link,
                                  'clientes', pp.clientes, 'valor', pp.valor) as x
          from por_prof pp join public.profissionais p on p.id = pp.profissional_id
         order by pp.atendidos desc, pp.valor desc, p.nome) t), '[]'::jsonb),

    'servicos', coalesce((
      select jsonb_agg(t.x order by t.ord) from (
        select row_number() over (order by count(*) desc, s.nome) as ord,
               jsonb_build_object('nome', s.nome, 'vezes', count(*),
                                  'valor', coalesce(sum(i.preco) filter (where a.status = 'concluido'), 0)) as x
          from ag a join public.agendamento_servicos i on i.agendamento_id = a.id
                    join public.servicos s on s.id = i.servico_id
         where a.status <> 'cancelado'
         group by s.id, s.nome
         order by count(*) desc, s.nome limit 10) t), '[]'::jsonb),

    -- Quem vinha com frequência e sumiu: 3 ou mais atendimentos na história e
    -- nenhum horário (nem futuro) depois de 45 dias antes do fim do período.
    -- É a lista para mandar um "estamos com saudade".
    'sumidas', coalesce((
      select jsonb_agg(t.x order by t.ord) from (
        select row_number() over (order by count(*) desc, max(t.inicio) desc) as ord,
               jsonb_build_object('nome', c.nome, 'atendimentos', count(*),
                                  'ultima', max(t.inicio)) as x
          from todos t join public.clientes c on c.id = t.cliente_id
         where t.status = 'concluido'
         group by c.id, c.nome
        having count(*) >= 3
           and max(t.inicio) < v_fim - interval '45 days'
           and not exists (select 1 from todos f where f.cliente_id = c.id
                             and f.status <> 'cancelado' and f.inicio >= v_fim - interval '45 days')
         order by count(*) desc, max(t.inicio) desc limit 10) t), '[]'::jsonb),

    -- ── QUANDO A AGENDA ENCHE ──────────────────────────────────────────────
    'porDiaDaSemana', (
      select jsonb_agg(coalesce(n, 0) order by d) from generate_series(0, 6) d
        left join (select extract(dow from inicio at time zone v_fuso)::int as dw, count(*) as n
                     from ag where status <> 'cancelado' group by 1) q on q.dw = d),
    'porHora', coalesce((
      select jsonb_agg(jsonb_build_object('hora', h, 'n', n) order by h)
        from (select extract(hour from inicio at time zone v_fuso)::int as h, count(*) as n
                from ag where status <> 'cancelado' group by 1) q), '[]'::jsonb),

    -- ── O LINK (só a gestão) ───────────────────────────────────────────────
    'link', case when v_prof is null then jsonb_build_object(
      'contandoDesde', (select min(dia) from public.link_visitas where salao_id = p_salao),
      'visitantes', (select count(*) from visitas),
      'visitas',    (select coalesce(sum(vezes), 0) from visitas),
      'marcaramPeloLink', (select count(*) from public.agendamentos a
                            where a.salao_id = p_salao and a.origem = 'online'
                              and a.status <> 'cancelado' and a.arquivado_em is null
                              and a.criado_em >= v_ini and a.criado_em < v_fim),
      'porOrigem', coalesce((select jsonb_agg(jsonb_build_object('origem', origem, 'n', n) order by n desc)
                               from (select origem, count(*) as n from visitas group by origem) q), '[]'::jsonb),
      'porDia', coalesce((select jsonb_agg(jsonb_build_object('dia', dia, 'n', n) order by dia)
                            from (select dia, count(*) as n from visitas group by dia) q), '[]'::jsonb)
    ) end
  ) into r;
  return r;
end $$;

revoke all on function public.registrar_visita(text, text, text) from public;
grant execute on function public.registrar_visita(text, text, text) to anon, authenticated;
revoke all on function public.dashboard(uuid, date, date) from public, anon;
grant execute on function public.dashboard(uuid, date, date) to authenticated;

-- ===========================================================================
-- 62_ficha_servico.sql — a ficha do serviço para a CLIENTE ver no link
--
-- O pedido: "preciso criar algo que cliente entre para saber como funciona...
-- unhas de gel, pq tem vários tipos" e "nos serviços cada serviço tem um lugar
-- de explicação, o que está incluso".
--
-- Quem chega pela primeira vez não sabe a diferença entre gel, fibra e
-- acrílico, nem o que vem junto no preço. Hoje ela pergunta no WhatsApp — ou
-- desiste. A ficha responde antes: o que é, o que está incluso, o que não
-- está, quanto dura, a manutenção, os cuidados e as dúvidas comuns.
--
-- ── POR QUE UMA COLUNA jsonb NO SERVIÇO ────────────────────────────────────
-- A ficha é do serviço e vive e morre com ele. Um campo só, com as partes
-- dentro, e TUDO opcional: serviço sem ficha continua igual ao de hoje.
--
-- ── ⚠ QUEM LIMPA É O BANCO ──────────────────────────────────────────────────
-- O texto é publicado num link sem login. O gatilho abaixo guarda só as
-- chaves conhecidas, com tamanho máximo em cada uma, e joga fora o resto.
-- A tela escapa o HTML na hora de mostrar; o banco garante o formato.
--
-- ── ⚠ E QUEM ENTREGA É UMA FUNÇÃO À PARTE, E NÃO A vitrine() ───────────────
-- A vitrine é a função mais sensível do projeto (preço de verdade, campos
-- nomeados um a um). Mexer nela para pendurar texto seria arriscar o resto.
-- `fichas_dos_servicos(slug)` devolve só as fichas dos serviços que JÁ
-- aparecem no link: ativos, que aceitam marcação online, de restaurante ativo.
-- O "como fazer" da equipe (`procedimento`, 41) não passa por aqui.
-- ===========================================================================

alter table public.servicos add column if not exists ficha jsonb;

do $$ begin
  alter table public.servicos add constraint servicos_ficha_formato
    check (ficha is null or (jsonb_typeof(ficha) = 'object'
                             and octet_length(ficha::text) <= 16000));
exception when duplicate_object then null; end $$;

/* Um texto da ficha: só string, aparado, com teto. Vazio vira nulo. */
create or replace function public.ficha_texto(p jsonb, p_max int)
returns text language sql immutable set search_path = public as $$
  select nullif(left(btrim(p #>> '{}'), p_max), '')
   where p is not null and jsonb_typeof(p) = 'string'
$$;

/* A ficha limpa. Devolve nulo quando não sobra nada — serviço sem ficha. */
create or replace function public.ficha_limpa(p jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  r jsonb := '{}'::jsonb;
  v text;
  lista jsonb;
  item jsonb;
  k text;
  maximo int;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return null; end if;

  foreach k in array array['explicacao','naoInclui','dura','manutencao',
                           'cuidadosAntes','cuidadosDepois'] loop
    maximo := case k when 'explicacao' then 1200
                     when 'dura' then 40 when 'manutencao' then 40
                     else 500 end;
    v := public.ficha_texto(p -> k, maximo);
    if v is not null then r := r || jsonb_build_object(k, v); end if;
  end loop;

  -- O que está incluso: uma lista de frases curtas, até 15.
  lista := '[]'::jsonb;
  if jsonb_typeof(p -> 'inclui') = 'array' then
    for item in select x from jsonb_array_elements(p -> 'inclui') x loop
      v := public.ficha_texto(item, 120);
      if v is not null and jsonb_array_length(lista) < 15 then
        lista := lista || to_jsonb(v);
      end if;
    end loop;
  end if;
  if jsonb_array_length(lista) > 0 then r := r || jsonb_build_object('inclui', lista); end if;

  -- As dúvidas comuns: pergunta e resposta, as duas preenchidas, até 8.
  lista := '[]'::jsonb;
  if jsonb_typeof(p -> 'duvidas') = 'array' then
    for item in select x from jsonb_array_elements(p -> 'duvidas') x loop
      if jsonb_typeof(item) = 'object'
         and public.ficha_texto(item -> 'p', 150) is not null
         and public.ficha_texto(item -> 'r', 600) is not null
         and jsonb_array_length(lista) < 8 then
        lista := lista || jsonb_build_object('p', public.ficha_texto(item -> 'p', 150),
                                             'r', public.ficha_texto(item -> 'r', 600));
      end if;
    end loop;
  end if;
  if jsonb_array_length(lista) > 0 then r := r || jsonb_build_object('duvidas', lista); end if;

  -- Comparar com outro serviço: só o id; quem confere o restaurante é o gatilho.
  v := public.ficha_texto(p -> 'compararCom', 40);
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    r := r || jsonb_build_object('compararCom', lower(v));
  end if;

  if r = '{}'::jsonb then return null; end if;
  return r;
end $$;

create or replace function public.tg_servico_ficha()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.ficha := public.ficha_limpa(new.ficha);
  /* Comparar só com serviço do MESMO restaurante, e nunca consigo mesmo. Um id de
     outro restaurante publicaria, no link deste, o nome e o preço do serviço de um
     concorrente. Apontou errado: a ligação cai, o resto da ficha fica. */
  if new.ficha ? 'compararCom' and (
       (new.ficha->>'compararCom')::uuid = new.id
       or not exists (select 1 from public.servicos s
                       where s.id = (new.ficha->>'compararCom')::uuid
                         and s.salao_id = new.salao_id)) then
    new.ficha := nullif(new.ficha - 'compararCom', '{}'::jsonb);
  end if;
  return new;
end $$;

drop trigger if exists tg_servico_ficha on public.servicos;
create trigger tg_servico_ficha before insert or update of ficha on public.servicos
  for each row execute function public.tg_servico_ficha();

/* A entrega para o link: { "<id do serviço>": ficha, ... }. Só dos serviços
   que o link já mostra; nada da equipe, nada de preço. */
create or replace function public.fichas_dos_servicos(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(v.id, v.ficha), '{}'::jsonb)
    from public.servicos v
    join public.saloes s on s.id = v.salao_id
   where s.slug = p_slug and s.status = 'ativo'
     and v.ativo and v.aceita_online and v.ficha is not null
$$;

revoke all on function public.ficha_texto(jsonb, int) from public, anon, authenticated;
revoke all on function public.ficha_limpa(jsonb) from public, anon, authenticated;
revoke all on function public.tg_servico_ficha() from public, anon, authenticated;
revoke all on function public.fichas_dos_servicos(text) from public;
grant execute on function public.fichas_dos_servicos(text) to anon, authenticated;

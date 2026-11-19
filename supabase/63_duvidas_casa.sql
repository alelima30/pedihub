-- ===========================================================================
-- 63_duvidas_casa.sql — as DÚVIDAS FREQUENTES da casa, no link da cliente
--
-- O pedido: "colocar Dúvidas ao lado do Horário e Informações... e um lugar
-- para o profissional colocar as dúvidas mais frequentes, exemplo: como
-- funciona a unha em gel? Aí o profissional vai escrever tudo... e diversas
-- molduras com título de dúvidas que o profissional queira colocar".
--
-- A ficha de cada serviço (62) responde "o que é ESTE serviço". Estas são as
-- perguntas da CASA, que o dono escreve livre: como funciona a unha em gel,
-- precisa chegar antes, atende criança, tem estacionamento...
--
-- ── ONDE MORA: saloes.cfg.duvidas ───────────────────────────────────────────
-- Uma lista [{p, r}] no cfg que já existe e que o "Salvar dados" de Meu salão
-- já grava. Nenhuma tabela nova, nenhuma coluna nova.
--
-- ── ⚠ QUEM ENTREGA É UMA FUNÇÃO À PARTE, E NÃO A vitrine() ───────────────
-- Pelo mesmo motivo da 62: a vitrine é a função mais sensível do projeto.
-- `duvidas_da_casa(slug)` lê só a chave `duvidas`, de salão ativo, e devolve
-- só pergunta e resposta, aparadas e com teto. Nada mais do cfg sai daqui.
-- A tela escapa o HTML na hora de mostrar.
-- ===========================================================================

/* A lista limpa: só objetos com pergunta E resposta em texto, até 20, na
   ordem em que o dono pôs. */
create or replace function public.duvidas_limpas(p jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('p', x.p, 'r', x.r) order by x.n), '[]'::jsonb)
    from (
      select n,
             nullif(left(btrim(e ->> 'p'), 150), '')  as p,
             nullif(left(btrim(e ->> 'r'), 2000), '') as r
        from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p
                                       else '[]'::jsonb end) with ordinality as t(e, n)
       where jsonb_typeof(e) = 'object'
         and jsonb_typeof(e -> 'p') = 'string'
         and jsonb_typeof(e -> 'r') = 'string'
         and nullif(btrim(e ->> 'p'), '') is not null
         and nullif(btrim(e ->> 'r'), '') is not null
       order by n
       limit 20
    ) x
$$;

/* A entrega para o link: { "duvidas": [{p, r}, ...] }. Salão fora do ar:
   lista vazia. Num objeto, e não a lista solta, porque o PostgREST devolve
   o jsonb como veio — e uma lista solta se confundiria com "uma linha por
   resultado" do lado de lá (a página pegaria só a primeira dúvida). */
create or replace function public.duvidas_da_casa(p_slug text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('duvidas',
    coalesce((select public.duvidas_limpas(s.cfg -> 'duvidas')
                from public.saloes s
               where s.slug = p_slug and s.status = 'ativo'), '[]'::jsonb))
$$;

revoke all on function public.duvidas_limpas(jsonb) from public, anon, authenticated;
revoke all on function public.duvidas_da_casa(text) from public;
grant execute on function public.duvidas_da_casa(text) to anon, authenticated;

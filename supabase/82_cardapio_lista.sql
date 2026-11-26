-- ===========================================================================
-- PediHub — o cardápio do link em LISTA, e o NÚMERO de cada item (82)
--
-- "Tem lanchonete que tem 50 lanches e não tem foto de tudo." O dono escolhe
-- como o cardápio aparece no link:
--
--   * com FOTOS — o de sempre: cada item com a foto (quem não tem, sem foto);
--   * só a LISTA — como o cardápio impresso: o nome em destaque, o que vem no
--     lanche embaixo e o preço do lado. Nenhum quadrado vazio.
--
-- E, nos dois, pode NUMERAR os itens (01, 02, 03…), como o cardápio de papel:
-- a cliente pede "o 14" no balcão e no telefone. O número é do item
-- (`produtos.numero`), escolhido pelo dono, e também dá a ORDEM da lista.
--
-- E a fileira das categorias (Todos, Lanches, Bebidas…) pode ficar PRESA no
-- alto: a cliente rola o cardápio inteiro e a categoria marcada acompanha o
-- que está na tela; tocar numa leva até ela. Ligada se o dono não disser nada.
--
-- Fica em `cfg.pedidos.cardapio` = { estilo: 'fotos' | 'lista', numerar, fixar }.
-- ===========================================================================

alter table public.produtos add column if not exists numero smallint;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'produtos_numero_faixa') then
    alter table public.produtos add constraint produtos_numero_faixa
      check (numero is null or numero between 1 and 9999);
  end if;
end $$;

-- ── A configuração dos pedidos ganha `cardapio` (a do 81, com a chave a mais)

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
    -- 81: oferecer "Pix online" no link (só vale com o Mercado Pago conectado).
    'pixOnline', coalesce(case when p->>'pixOnline' in ('true','false') then (p->>'pixOnline')::boolean end, false),
    /* 82: como o cardápio aparece no link — com as fotos (o de sempre) ou só
       a lista, como o cardápio impresso —, se cada item mostra o número, e se
       a fileira das categorias fica presa no alto enquanto se rola tudo. */
    'cardapio', jsonb_build_object(
       'estilo',  case when p->'cardapio'->>'estilo' = 'lista' then 'lista' else 'fotos' end,
       'numerar', coalesce(case when p->'cardapio'->>'numerar' in ('true','false')
                                then (p->'cardapio'->>'numerar')::boolean end, false),
       -- a fileira das categorias presa no alto, acompanhando a rolagem (ligada se não disser nada)
       'fixar',   coalesce(case when p->'cardapio'->>'fixar' in ('true','false')
                                then (p->'cardapio'->>'fixar')::boolean end, true)),
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
    'servicosTambem', coalesce(s.cfg->>'usaServicos', '') = 'true',
    -- (81) Pix online: a opção ligada E o Mercado Pago conectado.
    'pixOnline', coalesce((c->>'pixOnline')::boolean, false)
                 and exists (select 1 from public.mp_contas m where m.salao_id = s.id),
    /* (79) Os itens em promoção HOJE, com o preço cheio para riscar. Só os
       que a cliente vê no cardápio (ativo, no link, com preço à mostra). */
    'promocoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'preco', v.preco, 'cheio', p.preco, 'ate', p.promo_ate)
             order by p.nome)
        from public.produtos p,
             lateral (select public.preco_vigente(p.preco, p.preco_promo, p.promo_ate, s.fuso) as preco) v
       where p.salao_id = s.id and p.ativo and p.venda_online and p.preco_visivel
         and v.preco < p.preco), '[]'::jsonb),
    /* (82) O número de cada item, para a lista numerada ("quero o 14"). Vai
       à parte, como as promoções: a vitrine() não precisa mudar. */
    'numeros', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'numero', p.numero) order by p.numero)
        from public.produtos p
       where p.salao_id = s.id and p.ativo and p.venda_online and p.numero is not null), '[]'::jsonb));
end $$;
revoke all on function public.pedidos_da_casa(text) from public;
grant execute on function public.pedidos_da_casa(text) to anon, authenticated;

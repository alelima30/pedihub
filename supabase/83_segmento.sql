-- ===========================================================================
-- PediHub — o tipo do estabelecimento que a cliente vê (83)
--
-- "O Paivas não é restaurante, é lanchonete." O sistema continua um só
-- (saloes.tipo = 'restaurante'); isto é o NOME que aparece no link, embaixo do
-- nome da casa, e nas frases do pedido ("a lanchonete passa a chave Pix…").
--
-- Fica em `cfg.pedidos.segmento` e chega ao link pelo pedidos_da_casa() (que
-- devolve a configuração dos pedidos). Valor de fora da lista = restaurante.
-- Pode rodar mais de uma vez.
-- ===========================================================================

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
    /* 83: o tipo do estabelecimento que a cliente vê (Lanchonete, Pizzaria…).
       Só os da lista; o resto vira restaurante. Ver funcionamento.js. */
    'segmento', case when p->>'segmento' in ('restaurante','lanchonete','hamburgueria','pizzaria',
                        'acaiteria','pastelaria','padaria','cafeteria','doceria','sorveteria',
                        'marmitaria','espetaria','bar','adega','food_truck')
                     then p->>'segmento' else 'restaurante' end,
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

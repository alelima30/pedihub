-- ===========================================================================
-- PediHub — um cardápio de lanches para TESTAR
--
-- Cole no SQL Editor do Supabase e rode. Cadastra 12 itens (lanches,
-- porções, bebidas e sobremesa) com categoria, descrição, preço, tempo de
-- preparo e complementos (adicionais, ponto da carne, sabores, tamanho).
--
--   * Tem um restaurante só? Rode como está.
--   * Tem mais de um? Escreva na linha `v_link` o final do link do que quer
--     (o que vem depois de "cardapio.html?salao=") e rode.
--
-- Pode rodar de novo sem medo: item que já existe com o mesmo nome é pulado.
-- Para apagar depois, é pelo painel (Cardápio), item por item.
-- Fotos não vêm: ponha pelo painel, que é o que faz o cliente pedir.
-- ===========================================================================
do $$
declare
  v_link   text := '';   -- ← só se tiver mais de um restaurante
  v_salao  uuid;
  v_qtd    int;
  v_lista  text;
  it jsonb; g jsonb; o jsonb;
  v_prod uuid; v_grupo uuid; gi int; oi int;
  novos int := 0; pulados int := 0;
  cardapio jsonb := $j$[
    {"nome":"X-Burger","categoria":"Lanches","preco":22,"tempo":12,
     "descricao":"Pão de hambúrguer, hambúrguer de 150 g, queijo e maionese da casa.",
     "grupos":[
       {"nome":"Ponto da carne","min":1,"max":1,"opcoes":[["Mal passado",0],["Ao ponto",0],["Bem passado",0]]},
       {"nome":"Adicionais","min":0,"max":4,"opcoes":[["Bacon",4],["Ovo",2],["Cheddar",3],["Hambúrguer extra",7]]}]},
    {"nome":"X-Salada","categoria":"Lanches","preco":24,"tempo":12,
     "descricao":"Hambúrguer de 150 g, queijo, alface, tomate e maionese da casa.",
     "grupos":[
       {"nome":"Ponto da carne","min":1,"max":1,"opcoes":[["Mal passado",0],["Ao ponto",0],["Bem passado",0]]},
       {"nome":"Adicionais","min":0,"max":4,"opcoes":[["Bacon",4],["Ovo",2],["Cheddar",3],["Hambúrguer extra",7]]}]},
    {"nome":"X-Bacon","categoria":"Lanches","preco":28,"tempo":14,
     "descricao":"Hambúrguer de 150 g, queijo, bacon crocante e maionese da casa.",
     "grupos":[
       {"nome":"Adicionais","min":0,"max":3,"opcoes":[["Ovo",2],["Cheddar",3],["Hambúrguer extra",7]]}]},
    {"nome":"X-Tudo","categoria":"Lanches","preco":34,"tempo":15,
     "descricao":"Hambúrguer, queijo, presunto, ovo, bacon, alface, tomate, milho e batata palha."},
    {"nome":"Misto quente","categoria":"Lanches","preco":12,"tempo":6,
     "descricao":"Pão de forma na chapa com presunto e queijo derretido."},
    {"nome":"Cachorro-quente","categoria":"Lanches","preco":15,"tempo":8,
     "descricao":"Duas salsichas, molho de tomate, milho, ervilha e batata palha.",
     "grupos":[
       {"nome":"Adicionais","min":0,"max":2,"opcoes":[["Queijo ralado",2],["Purê de batata",3]]}]},
    {"nome":"Batata frita","categoria":"Porções","preco":18,"tempo":10,
     "descricao":"Batata frita crocante, sequinha, com sal.",
     "grupos":[
       {"nome":"Tamanho","min":1,"max":1,"opcoes":[["Média (300 g)",0],["Grande (500 g)",8]]},
       {"nome":"Cobertura","min":0,"max":2,"opcoes":[["Cheddar",5],["Bacon",5]]}]},
    {"nome":"Onion rings","categoria":"Porções","preco":20,"tempo":10,
     "descricao":"Anéis de cebola empanados, com molho barbecue."},
    {"nome":"Refrigerante lata","categoria":"Bebidas","preco":6,"tempo":null,
     "descricao":"Lata de 350 ml, gelada.",
     "grupos":[
       {"nome":"Sabor","min":1,"max":1,"opcoes":[["Coca-Cola",0],["Coca-Cola Zero",0],["Guaraná",0],["Fanta Laranja",0]]}]},
    {"nome":"Suco natural","categoria":"Bebidas","preco":10,"tempo":5,
     "descricao":"Copo de 500 ml, feito na hora.",
     "grupos":[
       {"nome":"Sabor","min":1,"max":1,"opcoes":[["Laranja",0],["Limão",0],["Maracujá",0],["Abacaxi com hortelã",1]]}]},
    {"nome":"Água mineral","categoria":"Bebidas","preco":4,"tempo":null,
     "descricao":"Garrafa de 500 ml.",
     "grupos":[
       {"nome":"Tipo","min":1,"max":1,"opcoes":[["Sem gás",0],["Com gás",0.5]]}]},
    {"nome":"Milk-shake","categoria":"Sobremesas","preco":16,"tempo":5,
     "descricao":"Copo de 400 ml, cremoso.",
     "grupos":[
       {"nome":"Sabor","min":1,"max":1,"opcoes":[["Chocolate",0],["Morango",0],["Baunilha",0],["Ovomaltine",2]]}]}
  ]$j$;
begin
  -- Qual restaurante.
  if btrim(v_link) <> '' then
    select id into v_salao from public.saloes where slug = btrim(v_link);
    if v_salao is null then
      raise exception 'Não achei o restaurante "%". Confira o final do link (depois de cardapio.html?salao=).', btrim(v_link);
    end if;
  else
    select count(*), string_agg(slug, ', ' order by slug) into v_qtd, v_lista from public.saloes;
    if v_qtd = 1 then
      select id into v_salao from public.saloes;
    else
      raise exception 'Você tem % restaurantes (%). Escreva o final do link do que quer na linha v_link, lá em cima, e rode de novo.',
        v_qtd, coalesce(v_lista, 'nenhum');
    end if;
  end if;

  -- Os itens, com os complementos.
  for it in select * from jsonb_array_elements(cardapio) loop
    if exists (select 1 from public.produtos
                where salao_id = v_salao and lower(btrim(nome)) = lower(it->>'nome')) then
      pulados := pulados + 1;
      continue;
    end if;
    insert into public.produtos (salao_id, nome, categoria, descricao, preco, custo, estoque,
                                 ativo, venda_online, preco_visivel, tempo_preparo)
    values (v_salao, it->>'nome', it->>'categoria', it->>'descricao', (it->>'preco')::numeric, 0, 0,
            true, true, true, nullif(it->>'tempo', '')::smallint)
    returning id into v_prod;
    gi := 0;
    for g in select * from jsonb_array_elements(coalesce(it->'grupos', '[]'::jsonb)) loop
      gi := gi + 1;
      insert into public.produto_grupos (salao_id, produto_id, nome, min, max, regra, ordem)
      values (v_salao, v_prod, g->>'nome', (g->>'min')::smallint, (g->>'max')::smallint, 'soma', gi)
      returning id into v_grupo;
      oi := 0;
      for o in select * from jsonb_array_elements(g->'opcoes') loop
        oi := oi + 1;
        insert into public.produto_opcoes (grupo_id, salao_id, nome, preco, ordem)
        values (v_grupo, v_salao, o->>0, (o->>1)::numeric, oi);
      end loop;
    end loop;
    novos := novos + 1;
  end loop;

  raise notice 'Cardápio de teste: % item(ns) novo(s), % já existia(m).', novos, pulados;
end $$;

select 'Pronto: abra o Cardápio no painel (e recarregue a página).' as resultado;

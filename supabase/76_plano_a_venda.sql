-- ===========================================================================
-- PediHub — plano desativado não se vende (76)
--
-- O PediHub desligou os planos que vieram do AgendaPro (Básico, Dupla,
-- Equipe, Restaurante). A tela só oferece Grátis, Essencial e Profissional,
-- mas o banco aceitava abrir a cobrança de QUALQUER plano que existisse: uma
-- chamada montada à mão comprava o Básico (R$ 49,90, com loja e caixa) por
-- menos que o Essencial (R$ 69,90).
--
-- Agora abrir a cobrança (Pix) e preparar o cartão recusam plano desativado
-- — a não ser para quem JÁ está nele (renovar não é comprar de novo).
--
-- E a recusa de módulo (`exigir_recurso`) deixa de mandar o dono para o
-- "plano Básico", que não existe mais: diz Essencial, e o plano mínimo de um
-- módulo adicional sai só dos planos à venda.
-- ===========================================================================

create or replace function public.exigir_plano_a_venda(p_salao uuid, p_plano text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if exists (select 1 from public.planos where codigo = p_plano and not ativo)
     and not exists (select 1 from public.assinaturas where salao_id = p_salao and plano = p_plano)
     and not public.is_super() then
    raise exception 'Este plano não está mais à venda. Escolha um dos planos da tela.'
      using errcode = 'check_violation';
  end if;
end $$;
revoke all on function public.exigir_plano_a_venda(uuid, text) from public, anon, authenticated;
grant execute on function public.exigir_plano_a_venda(uuid, text) to service_role;

-- O Pix (a do 13, com a conferência a mais).
create or replace function public.abrir_cobranca(
  p_salao uuid, p_plano text, p_metodo text, p_quem uuid)
returns public.cobrancas
language plpgsql security definer set search_path = public as $$
declare
  v_preco numeric(10,2);
  v_itens jsonb;
  v_dias  int;
  v_ja    public.cobrancas;
  v_nova  public.cobrancas;
begin
  if p_quem is null then
    raise exception 'Cobrança sem responsável.' using errcode = 'check_violation';
  end if;
  if not exists (
        select 1 from public.vinculos v
         where v.perfil_id = p_quem and v.salao_id = p_salao
           and v.status = 'ativo' and v.papel in ('dono','admin'))
     and not public.e_gestor(p_salao) then
    raise exception 'Sem permissão neste restaurante.'
      using errcode = 'insufficient_privilege';
  end if;
  /* ⚠ BOLETO SAIU DA VENDA — mas a coluna e o histórico ficam.

     A tarifa do boleto é FIXA por emissão. Num plano de entrada de R$ 57 ela
     pesava mais de 6% da mensalidade: cinco vezes o que pesa num plano de
     R$ 297. Somado à compensação de até três dias úteis, com o restaurante sem plano
     enquanto espera, ele não se pagava.

     A recusa mora AQUI, e não só no botão da tela: esconder botão não é
     validação, e quem chamar a função na mão tem que levar o mesmo não.

     `'boleto'` continua valendo no `check` da tabela e no histórico. Cobrança
     de boleto já emitida precisa continuar sendo lida, paga e conciliada — o
     que acabou foi emitir nova. Apagar o valor do domínio quebraria a
     renovação de quem está com um boleto em aberto agora. */
  if p_metodo = 'boleto' then
    raise exception 'O boleto foi descontinuado. Use o Pix.'
      using errcode = 'check_violation';
  end if;
  if p_metodo <> 'pix' then
    raise exception 'Forma de pagamento desconhecida.' using errcode = 'check_violation';
  end if;

  -- O preço do plano PARA ESTE RESTAURANTE (1b): o normal, ou o especial dele —
  -- mais os módulos adicionais que ele contratou (46_adicionais).
  if not exists (select 1 from public.planos where codigo = p_plano) then
    raise exception 'Plano não encontrado.' using errcode = 'check_violation';
  end if;
  -- 76: plano desativado não se vende mais (só renova quem já está nele).
  perform public.exigir_plano_a_venda(p_salao, p_plano);
  v_itens := public.itens_da_mensalidade(p_salao, p_plano);
  v_preco := public.soma_dos_itens(v_itens);
  if v_preco is null then
    raise exception 'Plano não encontrado.' using errcode = 'check_violation';
  end if;
  -- Plano sem preço não se compra: é o Grátis ou o teste, e cobrar R$ 0,00
  -- só serviria para o Mercado Pago recusar com uma mensagem ilegível.
  if v_preco <= 0 then
    raise exception 'Este plano não é pago.' using errcode = 'check_violation';
  end if;

  /* Já existe uma pendente? Devolve ELA, em vez de abrir outra.
     E só se for do mesmo plano e da mesma forma — quem estava no Pix e
     resolveu ir de boleto, ou subiu de plano, precisa de uma cobrança nova.
     A antiga é cancelada aqui mesmo, para o índice parcial não brigar.

     ⚠ E "pendente" aqui significa pendente QUE O DONO PODE PAGAR NA MÃO.
     A tentativa recusada do cartão também fica `pendente`, e sem o filtro ela
     entrava nesta consulta: o dono que saiu do cartão e clicava em Pix via a
     linha do cartão ser cancelada no lugar — apagando o registro da tentativa
     automática, que é o rastro de por que a renovação falhou.
     Sem contar que várias podem coexistir (o índice parcial passou a ignorá-
     las), e `select into` com muitas linhas pega uma qualquer.
     Mesma regra do `ux_cobranca_aberta`, do `minha_cobranca` e do
     `assinaturas_a_vencer` — são os quatro lugares que precisam dela. */
  select * into v_ja from public.cobrancas
   where salao_id = p_salao and status = 'pendente'
     and metodo <> 'cartao'
   for update;

  if found then
    -- E do mesmo VALOR: contratou um módulo depois de gerar o Pix, o Pix
    -- velho não serve mais (46_adicionais).
    if v_ja.plano = p_plano and v_ja.metodo = p_metodo and v_ja.vence_em > now()
       and v_ja.valor = v_preco then
      return v_ja;
    end if;
    update public.cobrancas set status = 'cancelada' where id = v_ja.id;
  end if;

  -- Pix vence em 24h: tempo de a pessoa pagar sem a cobrança envelhecer no
  -- painel. Boleto precisa de mais, porque compensa em dia útil.
  v_dias := case when p_metodo = 'boleto' then 3 else 1 end;

  insert into public.cobrancas (salao_id, plano, valor, metodo, vence_em, aberta_por, itens)
  values (p_salao, p_plano, v_preco, p_metodo,
          now() + make_interval(days => v_dias), p_quem, v_itens)
  returning * into v_nova;

  return v_nova;
end $$;
revoke all on function public.abrir_cobranca(uuid, text, text, uuid) from public, anon, authenticated;
grant execute on function public.abrir_cobranca(uuid, text, text, uuid) to service_role;

-- O cartão (a do 23, com a conferência a mais).
create or replace function public.preparar_cartao(
  p_salao uuid, p_plano text, p_quem uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_preco numeric(10,2);
  v_nome  text;
  v_pre   text;
  v_pag   jsonb;
begin
  if p_quem is null then
    raise exception 'Assinatura sem responsável.' using errcode = 'check_violation';
  end if;
  if not exists (
        select 1 from public.vinculos v
         where v.perfil_id = p_quem and v.salao_id = p_salao
           and v.status = 'ativo' and v.papel in ('dono','admin'))
     and not public.is_super() then
    raise exception 'Sem permissão neste restaurante.'
      using errcode = 'insufficient_privilege';
  end if;

  select preco_mes, nome into v_preco, v_nome
    from public.planos where codigo = p_plano;
  -- 76: plano desativado não se vende mais (só renova quem já está nele).
  if v_preco is not null then perform public.exigir_plano_a_venda(p_salao, p_plano); end if;
  -- Com o preço especial do restaurante, se houver (13_cobranca, 1b), e os módulos
  -- adicionais dele (46_adicionais): a mensalidade do cartão nasce aqui e se
  -- repete todo mês.
  if v_preco is not null then v_preco := public.valor_da_mensalidade(p_salao, p_plano); end if;
  if v_preco is null then
    raise exception 'Plano não encontrado.' using errcode = 'check_violation';
  end if;
  if v_preco <= 0 then
    raise exception 'Este plano não é pago.' using errcode = 'check_violation';
  end if;

  /* ⚠ E SEM LINHA EM `assinaturas` NÃO SE CRIA PRÉ-APROVAÇÃO NENHUMA.

     Esta é a metade que PREVINE; o `returning` do `ligar_cartao` é a metade
     que denuncia. Sem ela, um restaurante sem assinatura passava por aqui, a borda
     criava a pré-aprovação no Mercado Pago, e o cartão do dono começava a ser
     debitado todo mês — sem linha nenhuma para o `registrar_recorrencia`
     encontrar depois. Cobrança de verdade, renovação nenhuma.

     A conferência é pela LINHA, não pela coluna: `mp_preapproval` nulo é o
     estado legítimo de quem ainda não pôs cartão. */
  select mp_preapproval into v_pre
    from public.assinaturas where salao_id = p_salao;
  if not found then
    raise exception 'Este restaurante não tem assinatura para renovar.'
      using errcode = 'check_violation';
  end if;

  v_pag := public.dados_do_pagador(p_salao);

  /* `jaLigado` é o que faz a borda recusar em vez de criar uma segunda
     pré-aprovação. Duas ativas no mesmo restaurante é cobrança dobrada todo mês, e
     o dono só descobre na fatura. Trocar de plano no cartão é cancelar e
     assinar de novo — dois cliques, e nenhum deles cobra em duplicidade. */
  return jsonb_build_object(
    'plano',     p_plano,
    'nomePlano', v_nome,
    'valor',     v_preco,
    'email',     v_pag->>'email',
    'nome',      v_pag->>'nome',
    'jaLigado',  v_pre is not null);
end $$;
revoke all on function public.preparar_cartao(uuid, text, uuid) from public, anon, authenticated;
grant execute on function public.preparar_cartao(uuid, text, uuid) to service_role;

-- A recusa de módulo (a do 46, com os planos do PediHub).
create or replace function public.exigir_recurso(p_salao uuid, p_chave text, p_nome text)
returns void language plpgsql stable set search_path = public as $$
declare v_nome text; v_minimo text;
begin
  if coalesce(public.recurso_bool(p_salao, p_chave), false) then return; end if;
  begin
    select ad.nome,
           (select pl.nome from public.planos pl where pl.codigo = any(ad.planos) and pl.ativo
             order by pl.preco_mes, pl.ordem limit 1)
      into v_nome, v_minimo
      from public.adicionais ad where ad.recurso = p_chave order by ad.ordem limit 1;
  exception when insufficient_privilege then v_nome := null;
  end;
  if v_nome is not null then
    raise exception '% faz parte do módulo adicional %, a partir do plano %. Contrate em Meu plano.',
      p_nome, v_nome, coalesce(v_minimo, 'Essencial')
      using errcode = 'check_violation';
  end if;
  raise exception '% está disponível a partir do plano Essencial.', p_nome
    using errcode = 'check_violation';
end $$;

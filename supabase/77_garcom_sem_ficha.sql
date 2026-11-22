-- ===========================================================================
-- PediHub — o garçom entra sem "ficha de agenda"; o aviso no celular é do
-- pedido que chega de fora (77)
--
-- 1. O CONVITE DO GARÇOM. O convite de "Atendente / garçom" exigia escolher
--    a ficha da pessoa na Equipe ("de quem é a agenda") — a coluna dela na
--    agenda do salão. O restaurante não tem agenda, e a aba Equipe dele nem
--    mostra fichas: o dono não tinha como convidar o garçom. O garçom não
--    precisa de ficha: o nome em cada item que ele lança vem do cadastro dele
--    (73). No restaurante, o convite de garçom sem ficha agora vale.
--
-- 2. O AVISO NO CELULAR (59). Tocava o celular da equipe a cada pedido — até
--    o que o próprio garçom lança na mesa, ou o de telefone que o caixa
--    digita. Agora só o que chega de FORA (o link e o QR da mesa); e o de
--    mesa diz a mesa, não "retirada".
-- ===========================================================================

create or replace function public.criar_convite(
  p_salao uuid, p_papel text, p_para_quem text default null,
  p_profissional uuid default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_token uuid;
  pr public.profissionais%rowtype;
  v_restaurante boolean;
begin
  if not public.e_gestor(p_salao) then
    raise exception 'Só quem administra o restaurante pode convidar.'
      using errcode = 'insufficient_privilege';
  end if;
  if p_papel not in ('admin','recepcao','profissional') then
    raise exception 'Papel inválido para convite.' using errcode = 'check_violation';
  end if;
  select coalesce(tipo, 'restaurante') = 'restaurante' into v_restaurante from public.saloes where id = p_salao;

  if p_papel = 'profissional' and p_profissional is null and not coalesce(v_restaurante, false) then
    raise exception 'Escolha quem é a pessoa. Cadastre-a em Equipe antes de dar o login.'
      using errcode = 'check_violation';
  end if;
  if p_papel = 'profissional' and p_profissional is not null then
    select * into pr from public.profissionais where id = p_profissional;
    -- Ficha de OUTRO restaurante seria dar acesso ao que é alheio.
    if pr.id is null or pr.salao_id <> p_salao then
      raise exception 'Esta pessoa não é deste restaurante.' using errcode = 'check_violation';
    end if;
    -- E ficha que já tem dono não se entrega duas vezes.
    if pr.perfil_id is not null then
      raise exception '% já tem login.', pr.nome using errcode = 'check_violation';
    end if;
  elsif p_papel <> 'profissional' then
    p_profissional := null;   -- caixa/balcão e admin não têm ficha
  end if;

  insert into public.convites_equipe
         (salao_id, papel, para_quem, profissional_id, criado_por)
       values (p_salao, p_papel,
               nullif(btrim(coalesce(p_para_quem, '')), ''),
               p_profissional, auth.uid())
    returning token into v_token;

  return jsonb_build_object('token', v_token);
end $$;
revoke all on function public.criar_convite(uuid, text, text, uuid) from public;
grant execute on function public.criar_convite(uuid, text, text, uuid) to authenticated;

create or replace function public.tg_push_pedido()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Quem lançou foi a própria equipe (garçom na mesa, telefone, balcão):
  -- não há o que avisar a ela mesma.
  if coalesce(new.origem, 'link') <> 'link' then return null; end if;
  perform public.push_avisar(new.salao_id, public.push_quem_cuida(new.salao_id),
    'Pedido novo',
    coalesce(nullif(btrim(coalesce(new.nome, '')), ''), 'Cliente')
      || ' · R$ ' || replace(to_char(coalesce(new.total, 0), 'FM999990.00'), '.', ',')
      || case new.tipo_entrega when 'entrega' then ' · entrega'
                               when 'mesa' then ' · mesa ' || coalesce(new.mesa, '')
                               else ' · retirada' end,
    './app.html#pedidos',
    'pedido:' || new.id);
  return null;
end $$;
revoke all on function public.tg_push_pedido() from public, anon, authenticated;

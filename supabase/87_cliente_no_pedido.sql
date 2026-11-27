-- ===========================================================================
-- PediHub — o cliente já cadastrado, no Novo pedido do painel (87)
--
-- "No Novo pedido, não posso achar o cliente já cadastrado? E cadastrar na
-- hora?" A busca pelo nome usa as fichas que o painel já tem. Esta função
-- completa o que a ficha não guarda: pelo WhatsApp, quantos pedidos a pessoa
-- já fez, quando foi o último e o ÚLTIMO ENDEREÇO de entrega — para o caixa
-- não digitar de novo a rua de quem pede toda semana. Só para a equipe do
-- próprio estabelecimento. (Cadastrar na hora o banco já fazia: o pedido
-- lançado com nome e WhatsApp cria a ficha pelo WhatsApp — o 84.)
-- Pode rodar mais de uma vez.
-- ===========================================================================

create or replace function public.cliente_para_pedido(p_salao uuid, p_telefone text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_tel text;
  r     jsonb;
begin
  if not public.e_equipe(p_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  v_tel := public.telefone_nacional(p_telefone);
  if coalesce(v_tel, '') = '' or length(v_tel) < 10 then return null; end if;
  select jsonb_build_object(
           'pedidos', count(*) filter (where p.status <> 'cancelado'),
           'ultimo',  max(p.criado_em),
           'entrega', (select jsonb_build_object('endereco', q.endereco, 'bairro', q.bairro)
                         from public.pedidos q
                        where q.salao_id = p_salao and q.telefone = v_tel
                          and q.tipo_entrega = 'entrega' and q.endereco is not null
                        order by q.criado_em desc limit 1))
    into r
    from public.pedidos p
   where p.salao_id = p_salao and p.telefone = v_tel;
  return r;
end $$;
revoke all on function public.cliente_para_pedido(uuid, text) from public, anon;
grant execute on function public.cliente_para_pedido(uuid, text) to authenticated;

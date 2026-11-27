-- ===========================================================================
-- PediHub — o link do pedido, para a lanchonete mandar no WhatsApp (86)
--
-- "Depois que a lanchonete confirma, aparecer no pedido uma moldura para
-- enviar no WhatsApp todos os dados do pedido e o link Acompanhar pedido."
--
-- O link de acompanhar é o do cardápio com o código secreto do pedido
-- (cardapio.html?salao=...&pedido=<token>) — o mesmo que só a cliente tinha,
-- guardado no celular dela. Quem não tem conta passa a abrir o pedido em
-- qualquer aparelho. A tela de Pedidos não recebia esse código (e não deve
-- recebê-lo para todos de uma vez): esta função entrega o de UM pedido, só
-- para a equipe do próprio estabelecimento, na hora de mandar a mensagem.
-- Pode rodar mais de uma vez.
-- ===========================================================================

create or replace function public.token_do_pedido(p_pedido uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
declare v public.pedidos;
begin
  select * into v from public.pedidos where id = p_pedido;
  if v.id is null or not public.e_equipe(v.salao_id) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  return v.token;
end $$;
revoke all on function public.token_do_pedido(uuid) from public, anon;
grant execute on function public.token_do_pedido(uuid) to authenticated;

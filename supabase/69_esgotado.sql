-- ===========================================================================
-- 69_esgotado.sql — marcar "esgotado" com um toque, por qualquer um da equipe
--
-- Editar o cardápio é da gestão (02_rls, prod_gerir). Mas quem vê a massa
-- acabar é a cozinha e o balcão, no meio do movimento — e não dá para
-- esperar o dono. Esta função muda UMA coisa, a disponibilidade do item
-- (`produtos.ativo`), e deixa toda a equipe fazê-lo. Preço, nome e o resto
-- continuam só da gestão.
--
-- Pode rodar mais de uma vez.
-- ===========================================================================
create or replace function public.marcar_esgotado(p_produto uuid, p_esgotado boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_salao uuid;
begin
  select salao_id into v_salao from public.produtos where id = p_produto;
  if v_salao is null or not public.e_equipe(v_salao) then
    raise exception 'Sem permissão neste estabelecimento.' using errcode = 'insufficient_privilege';
  end if;
  update public.produtos set ativo = not coalesce(p_esgotado, false) where id = p_produto;
  return jsonb_build_object('ok', true, 'ativo', not coalesce(p_esgotado, false));
end $$;
revoke all on function public.marcar_esgotado(uuid, boolean) from public, anon;
grant execute on function public.marcar_esgotado(uuid, boolean) to authenticated;

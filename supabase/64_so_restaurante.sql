-- ===========================================================================
-- 64_so_restaurante.sql — no PediHub, toda casa é restaurante
--
-- O PediHub nasceu do AgendaPro, que atende salão, barbearia, estética... e,
-- como um tipo entre outros, o restaurante (37_pedidos). Aqui é o contrário:
-- o sistema é SÓ de pedidos — restaurante, lanchonete, pizzaria, delivery.
--
-- Todo o modo Pedidos já pergunta `tipo = 'restaurante'` (o cardápio, a
-- entrega, o andamento, `fazer_pedido`). Em vez de mexer em cada uma dessas
-- perguntas, a casa simplesmente não consegue ser outra coisa:
--
--   · a coluna nasce 'restaurante';
--   · o gatilho abaixo grava 'restaurante' em qualquer cadastro ou troca,
--     venha de onde vier (a tela de cadastro, uma página antiga em cache, o
--     `criar_salao()` com o padrão antigo 'salao');
--   · e quem já existia vira restaurante agora.
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

alter table public.saloes alter column tipo set default 'restaurante';

create or replace function public.saloes_so_restaurante()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.tipo := 'restaurante';
  return new;
end $$;

drop trigger if exists saloes_so_restaurante on public.saloes;
create trigger saloes_so_restaurante
  before insert or update of tipo on public.saloes
  for each row execute function public.saloes_so_restaurante();

update public.saloes set tipo = 'restaurante' where tipo is distinct from 'restaurante';

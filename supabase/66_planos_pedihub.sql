-- ===========================================================================
-- 66_planos_pedihub.sql — os planos do PediHub
--
-- Sem comissão por pedido e sem limite de pedidos nos planos pagos: cobrar
-- por pedido pune quem vende mais, e "sem comissão" é o motivo de o
-- restaurante sair do aplicativo grande. O que cresce com o uso e custa de
-- verdade são as mensagens automáticas do WhatsApp (a Meta cobra por
-- mensagem) — por isso a diferença entre os planos está nelas.
--
--   Grátis        R$ 0       cardápio no link e até 50 pedidos por mês;
--                            sem caixa, relatórios nem mensagens automáticas
--   Essencial     R$ 69,90   pedidos ilimitados, entrega, caixa, relatórios,
--                            cupons e a aparência do link
--   Profissional  R$ 119,90  tudo do Essencial + avisos automáticos no
--                            WhatsApp (1.000 por mês) e crediário (fiado)
--
-- O Teste grátis (30 dias, tudo liberado) continua como era. Os planos do
-- salão (Básico, Dupla, Equipe, Restaurante grande) saem da vitrine: ficam
-- na tabela, desligados, para não quebrar assinatura antiga.
--
-- Os códigos ficam os que o sistema já usa (`individual` é o Essencial,
-- `time` é o Profissional): a cobrança, o cartão e o painel da plataforma
-- já sabem lidar com eles. Preço muda com um UPDATE (PRECOS.sql).
--
-- Pode rodar mais de uma vez.
-- ===========================================================================

update public.planos set
  nome = 'Grátis', preco_mes = 0, ordem = 0, ativo = true,
  recursos = recursos || jsonb_build_object(
    'loja', true, 'max_produtos', 40, 'pedidos_mes', 50, 'max_clientes', 300,
    'caixa', false, 'relatorios', false, 'cupons', false, 'pacotes', false,
    'aparencia', false, 'crediario', false,
    'mensagens_mes', 0, 'lembrete_whatsapp', false)
 where codigo = 'gratuito';

update public.planos set
  nome = 'Essencial', preco_mes = 69.90, ordem = 2, ativo = true,
  recursos = (recursos - 'pedidos_mes') || jsonb_build_object(
    'loja', true, 'max_produtos', 300, 'max_clientes', 5000,
    'caixa', true, 'relatorios', true, 'cupons', true, 'pacotes', false,
    'aparencia', true, 'crediario', false,
    'mensagens_mes', 0, 'lembrete_whatsapp', false)
 where codigo = 'individual';

update public.planos set
  nome = 'Profissional', preco_mes = 119.90, ordem = 3, ativo = true,
  recursos = (recursos - 'pedidos_mes') || jsonb_build_object(
    'loja', true, 'max_produtos', 1000, 'max_clientes', 20000,
    'caixa', true, 'relatorios', true, 'cupons', true, 'pacotes', false,
    'aparencia', true, 'crediario', true,
    'mensagens_mes', 1000, 'lembrete_whatsapp', true)
 where codigo = 'time';

update public.planos set ativo = false
 where codigo in ('basico', 'duo', 'equipe', 'salao');

/* ── O LIMITE DO GRÁTIS: 50 PEDIDOS POR MÊS PELO LINK ─────────────────────
   Conferido no banco, na hora de gravar — a página não decide nada. Conta os
   pedidos do mês no horário do restaurante; cancelado também conta (senão o
   limite viraria um botão de "cancelar e pedir de novo"). Plano sem a chave
   `pedidos_mes` não tem limite. */
create or replace function public.pedidos_limite_do_plano()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_teto int; v_feitos int; v_inicio timestamptz; v_fuso text;
begin
  v_teto := public.recurso_num(new.salao_id, 'pedidos_mes');
  if v_teto is null then return new; end if;
  select coalesce(fuso, 'America/Sao_Paulo') into v_fuso from public.saloes where id = new.salao_id;
  v_inicio := date_trunc('month', now() at time zone v_fuso) at time zone v_fuso;
  select count(*) into v_feitos from public.pedidos
   where salao_id = new.salao_id and criado_em >= v_inicio;
  if v_feitos >= v_teto then
    raise exception 'Este restaurante chegou ao limite de pedidos pelo link neste mês. Faça o pedido pelo WhatsApp do restaurante.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists pedidos_limite_do_plano on public.pedidos;
create trigger pedidos_limite_do_plano
  before insert on public.pedidos
  for each row execute function public.pedidos_limite_do_plano();

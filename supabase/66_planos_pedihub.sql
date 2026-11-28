-- ===========================================================================
-- 66_planos_pedihub.sql — os planos do PediHub
--
-- Sem comissão por pedido e sem limite de pedidos nos planos pagos: cobrar
-- por pedido pune quem vende mais, e "sem comissão" é o motivo de o
-- restaurante sair do aplicativo grande. O que cresce com o uso e custa de
-- verdade são as mensagens automáticas do WhatsApp (a Meta cobra por
-- mensagem) — por isso a diferença entre os planos está SÓ nelas.
--
--   Grátis        R$ 0       cardápio no link e até 50 pedidos por mês;
--                            sem caixa, relatórios nem mensagens automáticas
--   Essencial     R$ 97      tudo para vender, sem o WhatsApp automático:
--                            pedidos ilimitados, entrega, mesas, caixa,
--                            relatórios, cupons, a aparência do link, 1.000
--                            itens e 20.000 clientes — e o crediário pronto
--                            (ele só vale quando o Crediário for posto à venda
--                            na plataforma: ver o recurso_bool do 46)
--   Profissional  R$ 147     o Essencial, igualzinho, + os avisos automáticos
--                            no WhatsApp (1.000 por mês)
--
-- "De pedidos não precisa de diversos planos: só o Grátis, o plano que usa
-- sem WhatsApp e o plano que usa com WhatsApp — que ainda não está pronto, mas
-- pode deixar os planos prontos" (28/11/2026). Por isso o Essencial ganhou o
-- crediário e os limites do Profissional. O Profissional fica PRONTO aqui; o
-- painel e a página de venda o mostram como "em breve", sem venda, até a conta
-- da Meta estar ligada (`WHATSAPP_AUTOMATICO_PRONTO`, no app.html).
--
-- Este arquivo pode ser colado de novo, sozinho, num banco já instalado: a
-- única função dele (o teto do Grátis) não é refeita por nenhum outro, e os
-- recursos são somados (||), não trocados — o que os módulos seguintes
-- puseram nos planos continua lá.
--
-- O Teste grátis (30 dias, tudo liberado) continua como era. Os planos do
-- salão (Básico, Dupla, Equipe, Restaurante grande) saem da vitrine: ficam
-- na tabela, desligados, para não quebrar assinatura antiga.
--
-- Os códigos ficam os que o sistema já usa (`individual` é o Essencial,
-- `time` é o Profissional): a cobrança, o cartão e o painel da plataforma
-- já sabem lidar com eles. Preço muda com um UPDATE (PRECOS.sql).
--
-- ⚠ ESTE PREÇO E O DO PRECOS.sql SÃO O MESMO, SEMPRE. Este arquivo entra no
-- 00_tudo e no 98_modulos, que são colados de novo a cada atualização, e grava
-- o preço toda vez. Um preço mudado só no PRECOS.sql voltaria sozinho na
-- colagem seguinte. Por isso preço muda nos DOIS arquivos juntos, e o
-- planos_pedihub.test.sql confere que eles dizem o mesmo. (Os preços eram
-- R$ 69,90 e R$ 119,90; desde 28/11/2026, R$ 97 e R$ 147.)
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
  nome = 'Essencial', preco_mes = 97.00, ordem = 2, ativo = true,
  recursos = (recursos - 'pedidos_mes') || jsonb_build_object(
    'loja', true, 'max_produtos', 1000, 'max_clientes', 20000,
    'caixa', true, 'relatorios', true, 'cupons', true, 'pacotes', false,
    'aparencia', true, 'crediario', true,
    'mensagens_mes', 0, 'lembrete_whatsapp', false)
 where codigo = 'individual';

update public.planos set
  nome = 'Profissional', preco_mes = 147.00, ordem = 3, ativo = true,
  recursos = (recursos - 'pedidos_mes') || jsonb_build_object(
    'loja', true, 'max_produtos', 1000, 'max_clientes', 20000,
    'caixa', true, 'relatorios', true, 'cupons', true, 'pacotes', false,
    'aparencia', true, 'crediario', true,
    'mensagens_mes', 1000, 'lembrete_whatsapp', true)
 where codigo = 'time';

-- O Essencial é o Profissional sem o WhatsApp automático — em TUDO. Copiar
-- daqui garante isso também para as chaves que vieram do AgendaPro (o
-- `max_servicos`, que era 50 num e 200 no outro) e para as que um módulo
-- futuro puser no Profissional.
update public.planos e
   set recursos = e.recursos || (t.recursos - 'mensagens_mes' - 'lembrete_whatsapp')
  from public.planos t
 where e.codigo = 'individual' and t.codigo = 'time';

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

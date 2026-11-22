-- ===========================================================================
-- PediHub — plano desativado não se vende (76)
--
--   1. a Lia, no teste grátis, tenta comprar o Básico (desativado, R$ 49,90)
--      por Pix e por cartão: recusado; o Essencial passa;
--   2. o Nino JÁ está no Básico (veio de antes): renovar continua valendo.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values ('a7600000-0000-0000-0000-00000000000a'), ('b7600000-0000-0000-0000-00000000000b');
insert into public.perfis (id, nome, telefone) values
  ('a7600000-0000-0000-0000-00000000000a', 'Lia', '+5511976000001'),
  ('b7600000-0000-0000-0000-00000000000b', 'Nino', '+5511976000002')
on conflict (id) do nothing;
insert into public.saloes (id, slug, nome, status, fuso) values
  ('57600000-0000-0000-0000-00000000000a', 'lanche-lia', 'Lanche da Lia', 'ativo', 'America/Sao_Paulo'),
  ('57600000-0000-0000-0000-00000000000b', 'pizza-nino', 'Pizza do Nino', 'ativo', 'America/Sao_Paulo');
insert into public.vinculos (perfil_id, salao_id, papel, status) values
  ('a7600000-0000-0000-0000-00000000000a', '57600000-0000-0000-0000-00000000000a', 'dono', 'ativo'),
  ('b7600000-0000-0000-0000-00000000000b', '57600000-0000-0000-0000-00000000000b', 'dono', 'ativo');
insert into public.assinaturas (salao_id, plano, status, vence_em, trial_ate) values
  ('57600000-0000-0000-0000-00000000000a', 'trial',  'trial', null, current_date + 10),
  ('57600000-0000-0000-0000-00000000000b', 'basico', 'ativa', current_date + 3, null)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status,
  vence_em = excluded.vence_em, trial_ate = excluded.trial_ate;
update public.planos set ativo = false where codigo = 'basico';

\echo ''
\echo '1. Quem não está no plano desativado não compra'
select t_texto('Pix do Básico: recusado',
  erro_de($$select public.abrir_cobranca('57600000-0000-0000-0000-00000000000a', 'basico', 'pix',
                                         'a7600000-0000-0000-0000-00000000000a')$$),
  'Este plano não está mais à venda. Escolha um dos planos da tela.');
select t_texto('cartão do Básico: recusado',
  erro_de($$select public.preparar_cartao('57600000-0000-0000-0000-00000000000a', 'basico',
                                          'a7600000-0000-0000-0000-00000000000a')$$),
  'Este plano não está mais à venda. Escolha um dos planos da tela.');
select t_verdade('o Essencial (à venda) abre o Pix',
  (public.abrir_cobranca('57600000-0000-0000-0000-00000000000a', 'individual', 'pix',
                         'a7600000-0000-0000-0000-00000000000a')).id is not null);

\echo ''
\echo '2. Quem já está nele renova'
select t_verdade('o Nino, no Básico, renova pelo Pix',
  (public.abrir_cobranca('57600000-0000-0000-0000-00000000000b', 'basico', 'pix',
                         'b7600000-0000-0000-0000-00000000000b')).id is not null);
select t_texto('e o preço é o do plano dele', (select valor::text from public.cobrancas
   where salao_id = '57600000-0000-0000-0000-00000000000b' and status = 'pendente'),
  (select preco_mes::text from public.planos where codigo = 'basico'));

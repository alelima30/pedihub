-- ===========================================================================
-- PRECOS.sql — o preço de tabela de cada plano
--
-- Cole no SQL Editor do Supabase e rode. Hoje: Essencial R$ 97 e
-- Profissional R$ 147 (28/11/2026). Quem paga no Pix vê o preço novo na
-- próxima renovação. A renovação no CARTÃO foi autorizada no Mercado Pago com
-- o valor da época: para quem já assina no cartão, o valor novo só vale
-- quando ele desligar e ligar de novo a renovação (e os Termos pedem 30 dias
-- de aviso antes de mudar o preço de quem já paga).
--
-- Por que existe à parte: o 00_tudo e o 98_modulos também gravam o preço do
-- Essencial e do Profissional (no 66_planos_pedihub.sql), mas só quando são
-- colados inteiros. Este arquivo aplica o preço AGORA, sem colar mais nada.
--
-- ⚠ Para mudar um preço no futuro, troque o número AQUI e no
-- 66_planos_pedihub.sql, os dois juntos — senão a próxima colagem do
-- 98_modulos volta o preço antigo. O planos_pedihub.test.sql confere que os
-- dois dizem o mesmo.
-- ===========================================================================

update public.planos p
   set preco_mes = v.preco
  from (values
          ('gratuito',     0.00),
          ('trial',        0.00),
          ('basico',      49.90),
          ('individual',  97.00),
          ('duo',        157.00),
          ('time',       147.00),
          ('equipe',     297.00),
          ('salao',      497.00)
       ) as v(codigo, preco)
 where p.codigo = v.codigo;

-- Os preços especiais por restaurante (13_cobranca, 1b) NÃO mudam aqui: um
-- desconto dado a um restaurante (o preço de fundador, por exemplo) continua
-- valendo. Para tirar TODOS os preços especiais de uma vez e todo mundo pagar a
-- tabela, tire os dois traços do começo das três linhas abaixo e rode de novo.
-- update public.assinaturas
--    set precos_especiais = '{}'::jsonb
--  where precos_especiais is distinct from '{}'::jsonb;

-- O resultado, para conferir na tela do Supabase.
select codigo, nome, preco_mes
  from public.planos
 order by ordem, codigo;

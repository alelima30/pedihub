-- ===========================================================================
-- 61_teste_30_dias.sql — o teste grátis passa a ser de 30 dias, com 2
--                        profissionais
--
-- Pedido do dono: "a partir de agora todos os negócios que cadastrar têm 30
-- dias para usar no plano de 2 profissionais". E, perguntado, as mensagens
-- do teste continuam 100 no mês: o salão ainda não paga, e a Meta cobra.
--
-- ── O QUE MUDA ────────────────────────────────────────────────────────────
--   · cadastro NOVO nasce com 30 dias de teste (eram 7);
--   · o plano "Teste grátis" passa a caber 2 profissionais, com os limites
--     de clientes, serviços e produtos da Dupla (1000 / 100 / 100);
--   · as 100 mensagens do teste não mudam.
--
-- ── O QUE NÃO MUDA ────────────────────────────────────────────────────────
--   · quem já está no teste continua com a data que tinha — "a partir de
--     agora" é para os cadastros novos. Ganha, sim, a vaga da 2ª pessoa
--     enquanto o teste durar: o limite é do plano, e não faria sentido o
--     mesmo plano valer 1 para um salão e 2 para o outro;
--   · o teste continua UM por pessoa (39_teste_unico): quem já usou nasce no
--     Grátis, com ou sem os 30 dias.
--
-- ── POR QUE A FUNÇÃO DO CADASTRO ESTÁ AQUI DE NOVO ────────────────────────
-- `criar_salao` mora no 03, que vai na PARTE 1 do SQL. Copiada aqui (só com
-- os 30 dias), quem atualiza colando a parte 2 já recebe a regra nova. Como
-- em todo este projeto, vale a definição do arquivo de número maior: uma
-- mudança futura no cadastro precisa ser feita AQUI (e no 03, para quem
-- instala do zero).
-- ===========================================================================

update public.planos
   set max_profissionais = 2,
       recursos = recursos || jsonb_build_object(
         'max_clientes', 1000, 'max_servicos', 100, 'max_produtos', 100,
         'mensagens_mes', 100)
 where codigo = 'trial';

create or replace function public.criar_salao(
  p_nome_salao   text,
  p_tipo         text default 'salao',
  p_slug         text default null,
  p_telefone     text default null,
  p_documento    text default null,      -- CPF ou CNPJ, para a cobrança
  p_origem       text default null,      -- por onde a pessoa nos achou
  p_indicado_por text default null
)
returns table (salao_id uuid, slug text)
language plpgsql security definer set search_path = public as $$
declare
  v_perfil uuid := auth.uid();
  v_slug   text;
  v_salao  uuid;
  v_dias   int := 30;                     -- duração do teste grátis (era 7)
begin
  if v_perfil is null then
    raise exception 'Faça login antes de criar o salão.'
      using errcode = 'insufficient_privilege';
  end if;

  if not exists (select 1 from public.perfis where id = v_perfil) then
    raise exception 'Complete seu cadastro antes de criar o salão.'
      using errcode = 'foreign_key_violation';
  end if;

  if length(btrim(coalesce(p_nome_salao,''))) < 2 then
    raise exception 'Dê um nome ao estabelecimento.'
      using errcode = 'check_violation';
  end if;

  -- Uma pessoa dona de muitos salões é possível (rede de barbearias), mas
  -- dezenas viram fábrica de teste grátis. O limite é folgado de propósito.
  if (select count(*) from public.vinculos
       where perfil_id = v_perfil and papel = 'dono') >= 10 then
    raise exception 'Você já tem 10 estabelecimentos. Fale com a gente para abrir mais.'
      using errcode = 'check_violation';
  end if;

  v_slug := coalesce(nullif(btrim(p_slug), ''), public.sugerir_slug(p_nome_salao));
  v_slug := public.virar_slug(v_slug);

  if not public.slug_disponivel(v_slug) then
    -- Não devolve erro seco: escolhe o próximo livre e avisa qual ficou.
    v_slug := public.sugerir_slug(v_slug);
  end if;

  insert into public.saloes (slug, nome, tipo, telefone, whatsapp, status)
  values (v_slug, btrim(p_nome_salao),
          coalesce(nullif(p_tipo,''), 'salao'),
          p_telefone, p_telefone, 'ativo')
  returning id into v_salao;

  insert into public.assinaturas
    (salao_id, plano, status, trial_ate, origem, indicado_por)
  /* O "hoje" do teste é o do SALÃO, e não o do servidor (UTC). Depois das
     21h em Brasília o servidor já está no dia seguinte, e o teste de 7 dias
     nascia com 8 — a tela dizia "faltam 8 dias" logo depois de prometer 7. */
  values (v_salao, 'trial', 'trial',
          (now() at time zone coalesce((select s.fuso from public.saloes s where s.id = v_salao),
                                       'America/Sao_Paulo'))::date + v_dias,
          p_origem, p_indicado_por);

  insert into public.vinculos (perfil_id, salao_id, papel, status)
  values (v_perfil, v_salao, 'dono', 'ativo');

  -- O dono também atende, na esmagadora maioria dos casos. Já entra como o
  -- primeiro profissional — e é justamente o 1 que o teste grátis permite.
  insert into public.profissionais (salao_id, perfil_id, nome, comissao_pct)
  select v_salao, v_perfil, p.nome, 100 from public.perfis p where p.id = v_perfil;

  -- O documento é da COBRANÇA, não do salão: guardar CPF junto do cadastro
  -- público seria expor documento em tabela que o cliente final lê.
  --
  -- ⚠ Repare no `documentos_cobranca.salao_id` escrito por extenso. Esta
  -- função declara `returns table (salao_id …)`, e isso cria uma variável de
  -- saída com o MESMO NOME da coluna. Um `where salao_id = …` solto aqui
  -- dentro para o Postgres com "column reference is ambiguous" — foi
  -- exatamente o que aconteceu na primeira versão. Dentro de plpgsql com
  -- OUT params, qualifique sempre.
  -- Insert simples, sem `on conflict`: o salão nasceu duas linhas acima,
  -- então não existe documento para conflitar. E o alvo do `on conflict` é
  -- um dos poucos lugares do SQL que NÃO aceita qualificação por tabela,
  -- então ali a ambiguidade não teria conserto.
  if p_documento is not null and btrim(p_documento) <> '' then
    insert into public.documentos_cobranca (salao_id, documento)
    values (v_salao, regexp_replace(p_documento, '\D', '', 'g'));
  end if;

  return query select v_salao, v_slug;
end $$;

revoke all on function public.criar_salao(text,text,text,text,text,text,text) from public;
grant execute on function public.criar_salao(text,text,text,text,text,text,text)
  to authenticated;

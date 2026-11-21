-- ===========================================================================
-- PediHub — a ficha do serviço para a cliente (62_ficha_servico.sql)
--
-- O que tem de valer:
--   · a dona grava a ficha pela tabela, como grava o resto do serviço;
--   · o banco guarda só o que é da ficha, com tamanho máximo, e joga fora
--     o lixo (chave desconhecida, número no lugar de texto, dúvida sem
--     resposta, lista enorme);
--   · ficha vazia vira nula — serviço sem ficha continua como sempre;
--   · "comparar com" só aponta para serviço do MESMO salão, nunca para si;
--   · o link (sem login) lê só as fichas dos serviços que ele já mostra;
--   · o "como fazer" da equipe nunca sai por ali;
--   · a profissional e a recepção não escrevem ficha; o vizinho também não.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('a6200000-0000-0000-0000-00000000000a'),  -- Ana  — dona
  ('d6200000-0000-0000-0000-00000000000d'),  -- Ju   — profissional
  ('e6200000-0000-0000-0000-00000000000e');  -- Eva  — dona do vizinho
insert into public.perfis (id, nome, telefone) values
  ('a6200000-0000-0000-0000-00000000000a', 'Ana', '+5511962000001'),
  ('d6200000-0000-0000-0000-00000000000d', 'Ju',  '+5511962000004'),
  ('e6200000-0000-0000-0000-00000000000e', 'Eva', '+5511962000005')
on conflict (id) do update set nome = excluded.nome;

insert into public.saloes (id, slug, nome, status, fuso) values
  ('62000000-0000-0000-0000-00000000000a', 'ficha-a', 'Studio Unhas', 'ativo', 'America/Sao_Paulo'),
  ('62000000-0000-0000-0000-00000000000b', 'ficha-b', 'Vizinho',      'ativo', 'America/Sao_Paulo'),
  ('62000000-0000-0000-0000-00000000000c', 'ficha-c', 'Fechado',      'suspenso', 'America/Sao_Paulo');
insert into public.assinaturas (salao_id, plano, status) values
  ('62000000-0000-0000-0000-00000000000a', 'time', 'ativa'),
  ('62000000-0000-0000-0000-00000000000b', 'time', 'ativa'),
  ('62000000-0000-0000-0000-00000000000c', 'time', 'ativa');
insert into public.vinculos (perfil_id, salao_id, papel) values
  ('a6200000-0000-0000-0000-00000000000a', '62000000-0000-0000-0000-00000000000a', 'dono'),
  ('d6200000-0000-0000-0000-00000000000d', '62000000-0000-0000-0000-00000000000a', 'profissional'),
  ('e6200000-0000-0000-0000-00000000000e', '62000000-0000-0000-0000-00000000000b', 'dono');
insert into public.profissionais (id, salao_id, perfil_id, nome, ativo) values
  ('96200000-0000-0000-0000-00000000000d', '62000000-0000-0000-0000-00000000000a', 'd6200000-0000-0000-0000-00000000000d', 'Ju', true);
insert into public.servicos (id, salao_id, nome, duracao_min, preco, procedimento) values
  ('62100000-0000-0000-0000-0000000000a1', '62000000-0000-0000-0000-00000000000a', 'Alongamento em gel', 90, 150, 'SEGREDO DA EQUIPE'),
  ('62100000-0000-0000-0000-0000000000a2', '62000000-0000-0000-0000-00000000000a', 'Fibra de vidro',    120, 180, null),
  ('62100000-0000-0000-0000-0000000000a3', '62000000-0000-0000-0000-00000000000a', 'Serviço escondido',  60,  50, null),
  ('62100000-0000-0000-0000-0000000000b1', '62000000-0000-0000-0000-00000000000b', 'Gel do vizinho',     60,  99, null),
  ('62100000-0000-0000-0000-0000000000c1', '62000000-0000-0000-0000-00000000000c', 'Gel do fechado',     60,  99, null);
grant usage on schema auth to anon, authenticated;

create or replace function t_como(p_quem uuid, p_sql text) returns text
language plpgsql as $$
declare r text;
begin
  perform set_config('request.jwt.claim.sub', coalesce(p_quem::text, ''), true);
  perform set_config('role', case when p_quem is null then 'anon' else 'authenticated' end, true);
  begin
    execute p_sql into r;
  exception when others then
    perform set_config('role', 'postgres', true);
    perform set_config('request.jwt.claim.sub', '', true);
    return 'ERRO: ' || sqlerrm;
  end;
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claim.sub', '', true);
  return coalesce(r, '');
end $$;

-- ── 1) A DONA GRAVA, E O BANCO LIMPA ──────────────────────────────────────
do $$
declare e text; f jsonb;
begin
  e := t_como('a6200000-0000-0000-0000-00000000000a', $q$
    update public.servicos set ficha = jsonb_build_object(
      'explicacao', '  Gel moldado sobre a unha e secado na cabine de LED.  ',
      'inclui', jsonb_build_array('Remoção do esmalte', '  ', 42, 'Cutilagem', 'Esmaltação em gel'),
      'naoInclui', 'Decoração',
      'dura', '3 a 4 semanas', 'manutencao', 'a cada 21 dias',
      'cuidadosAntes', 'Venha sem esmalte', 'cuidadosDepois', 'Use luvas',
      'duvidas', jsonb_build_array(
         jsonb_build_object('p', 'Estraga a unha?', 'r', 'Não, se retirado no salão.'),
         jsonb_build_object('p', 'Sem resposta', 'r', ''),
         'texto solto'),
      'compararCom', '62100000-0000-0000-0000-0000000000A2',
      'script', '<script>alert(1)</script>',
      'preco', 1)
    where id = '62100000-0000-0000-0000-0000000000a1' returning 'ok'$q$);
  perform t_texto('a dona grava a ficha', e, 'ok');
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a1';
  perform t_texto('o texto chega aparado', f->>'explicacao', 'Gel moldado sobre a unha e secado na cabine de LED.');
  perform t_igual('o incluso fica só com frases de verdade (sem vazio, sem número)', jsonb_array_length(f->'inclui'), 3);
  perform t_texto('na ordem em que a dona escreveu', f->'inclui'->>1, 'Cutilagem');
  perform t_igual('dúvida sem resposta e texto solto saem', jsonb_array_length(f->'duvidas'), 1);
  perform t_texto('a dúvida boa fica', f->'duvidas'->0->>'r', 'Não, se retirado no salão.');
  perform t_falso('chave desconhecida não é guardada', f ? 'script' or f ? 'preco');
  perform t_texto('comparar com: o id fica, em minúsculas', f->>'compararCom', '62100000-0000-0000-0000-0000000000a2');
  perform t_texto('dura', f->>'dura', '3 a 4 semanas');
  perform t_texto('manutenção', f->>'manutencao', 'a cada 21 dias');
end $$;

-- ── 2) OS TETOS ────────────────────────────────────────────────────────────
do $$
declare f jsonb;
begin
  update public.servicos set ficha = jsonb_build_object(
      'explicacao', repeat('a', 5000), 'dura', repeat('b', 300),
      'inclui', (select jsonb_agg(repeat('c', 500)) from generate_series(1, 40)),
      'duvidas', (select jsonb_agg(jsonb_build_object('p', 'P' || i, 'r', 'R' || i)) from generate_series(1, 20) i))
   where id = '62100000-0000-0000-0000-0000000000a2';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a2';
  perform t_igual('explicação com teto de 1200', length(f->>'explicacao'), 1200);
  perform t_igual('dura com teto de 40', length(f->>'dura'), 40);
  perform t_igual('até 15 itens no incluso', jsonb_array_length(f->'inclui'), 15);
  perform t_igual('cada item com teto de 120', length(f->'inclui'->>0), 120);
  perform t_igual('até 8 dúvidas', jsonb_array_length(f->'duvidas'), 8);
end $$;

-- ── 3) FICHA VAZIA É NULA, E O QUE NÃO É OBJETO É RECUSADO ─────────────────
do $$
declare f jsonb; e text;
begin
  update public.servicos set ficha = '{"explicacao":"   ","inclui":[],"x":1}'
   where id = '62100000-0000-0000-0000-0000000000a3';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a3';
  perform t_verdade('ficha sem nada aproveitável vira nula', f is null);
  update public.servicos set ficha = '"só um texto"' where id = '62100000-0000-0000-0000-0000000000a3';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a3';
  perform t_verdade('ficha que não é objeto também vira nula', f is null);
end $$;

-- ── 4) COMPARAR SÓ DENTRO DO SALÃO ─────────────────────────────────────────
do $$
declare f jsonb;
begin
  update public.servicos set ficha = '{"explicacao":"x","compararCom":"62100000-0000-0000-0000-0000000000b1"}'
   where id = '62100000-0000-0000-0000-0000000000a3';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a3';
  perform t_falso('apontar para o serviço do vizinho cai', f ? 'compararCom');
  perform t_texto('e o resto da ficha fica', f->>'explicacao', 'x');
  update public.servicos set ficha = '{"explicacao":"x","compararCom":"62100000-0000-0000-0000-0000000000a3"}'
   where id = '62100000-0000-0000-0000-0000000000a3';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a3';
  perform t_falso('apontar para si mesmo cai', f ? 'compararCom');
  update public.servicos set ficha = '{"compararCom":"62100000-0000-0000-0000-0000000000b1"}'
   where id = '62100000-0000-0000-0000-0000000000a3';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a3';
  perform t_verdade('só o comparar, e errado: a ficha some inteira', f is null);
  update public.servicos set ficha = '{"compararCom":"nao-e-um-id"}'
   where id = '62100000-0000-0000-0000-0000000000a3';
  select ficha into f from public.servicos where id = '62100000-0000-0000-0000-0000000000a3';
  perform t_verdade('id torto também cai', f is null);
end $$;

-- ── 5) QUEM ESCREVE ────────────────────────────────────────────────────────
do $$
declare e text;
begin
  e := t_como('d6200000-0000-0000-0000-00000000000d', $q$
    update public.servicos set ficha = '{"explicacao":"da Ju"}'
     where id = '62100000-0000-0000-0000-0000000000a1' returning 'mudou'$q$);
  perform t_verdade('a profissional não escreve a ficha — ' || coalesce(e, 'nulo'),
    e is distinct from 'mudou');
  e := t_como('e6200000-0000-0000-0000-00000000000e', $q$
    update public.servicos set ficha = '{"explicacao":"da Eva"}'
     where id = '62100000-0000-0000-0000-0000000000a1' returning 'mudou'$q$);
  perform t_verdade('a dona do vizinho não escreve a ficha', e is distinct from 'mudou');
  perform t_falso('e o texto continua o da Ana',
    exists (select 1 from public.servicos where ficha->>'explicacao' in ('da Ju', 'da Eva')));
end $$;

-- ── 6) O LINK ──────────────────────────────────────────────────────────────
update public.servicos set ficha = '{"explicacao":"do vizinho"}' where id = '62100000-0000-0000-0000-0000000000b1';
update public.servicos set ficha = '{"explicacao":"do fechado"}' where id = '62100000-0000-0000-0000-0000000000c1';
update public.servicos set ficha = '{"explicacao":"escondido"}', aceita_online = false
 where id = '62100000-0000-0000-0000-0000000000a3';
do $$
declare e text; m jsonb;
begin
  e := t_como(null, $q$select public.fichas_dos_servicos('ficha-a')::text$q$);
  m := e::jsonb;
  perform t_verdade('o visitante sem login lê as fichas — ' || left(e, 80), m ? '62100000-0000-0000-0000-0000000000a1');
  perform t_verdade('a do gel e a da fibra', m ? '62100000-0000-0000-0000-0000000000a2');
  perform t_falso('serviço que não aceita marcação online não aparece', m ? '62100000-0000-0000-0000-0000000000a3');
  perform t_falso('nada do vizinho', m ? '62100000-0000-0000-0000-0000000000b1');
  perform t_falso('o como fazer da equipe não viaja', e like '%SEGREDO DA EQUIPE%');
  perform t_falso('nem o preço', e like '%150%');
  perform t_texto('o texto é o que a dona escreveu',
    m->'62100000-0000-0000-0000-0000000000a1'->>'naoInclui', 'Decoração');

  e := t_como(null, $q$select public.fichas_dos_servicos('ficha-c')::text$q$);
  perform t_texto('salão que não está ativo: nada', e, '{}');
  e := t_como(null, $q$select public.fichas_dos_servicos('nao-existe')::text$q$);
  perform t_texto('apelido que não existe: nada', e, '{}');

  update public.servicos set ativo = false where id = '62100000-0000-0000-0000-0000000000a2';
  e := t_como(null, $q$select public.fichas_dos_servicos('ficha-a')::text$q$);
  perform t_falso('serviço desativado sai do link', e::jsonb ? '62100000-0000-0000-0000-0000000000a2');
  update public.servicos set ativo = true where id = '62100000-0000-0000-0000-0000000000a2';
end $$;

-- ── 7) AS PEÇAS DE DENTRO NÃO SÃO PORTAS ───────────────────────────────────
do $$
begin
  perform t_falso('ficha_limpa fechada para o anon',
    has_function_privilege('anon', 'public.ficha_limpa(jsonb)', 'EXECUTE'));
  perform t_falso('ficha_limpa fechada para quem tem login',
    has_function_privilege('authenticated', 'public.ficha_limpa(jsonb)', 'EXECUTE'));
  perform t_falso('ficha_texto fechada',
    has_function_privilege('anon', 'public.ficha_texto(jsonb, int)', 'EXECUTE'));
  perform t_verdade('fichas_dos_servicos aberta ao link',
    has_function_privilege('anon', 'public.fichas_dos_servicos(text)', 'EXECUTE'));
  perform t_verdade('a ficha tem teto de tamanho no banco',
    exists (select 1 from pg_constraint where conname = 'servicos_ficha_formato'));
end $$;

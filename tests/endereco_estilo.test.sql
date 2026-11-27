-- ===========================================================================
-- PediHub — o destaque do endereço na capa (85)
--
--   1. sem escolher, a vitrine não manda nada (o link usa o automático);
--   2. escolhido ("faixa"), a vitrine entrega ao link;
--   3. no plano Grátis sai junto com as outras chaves de aparência.
-- ===========================================================================
\set ON_ERROR_STOP on

insert into public.saloes (id, slug, nome, status, fuso, tipo, cfg) values
  ('58500000-0000-0000-0000-00000000000a', 'endereco-85', 'Lanche do Endereço', 'ativo', 'America/Sao_Paulo', 'restaurante', '{}');
insert into public.assinaturas (salao_id, plano, status, vence_em) values
  ('58500000-0000-0000-0000-00000000000a', 'individual', 'ativa', current_date + 20)
on conflict (salao_id) do update set plano = excluded.plano, status = excluded.status, vence_em = excluded.vence_em;
grant usage on schema auth to anon, authenticated;

create or replace function t_vitrine() returns jsonb language plpgsql as $$
declare r jsonb;
begin
  set local role anon;
  select to_jsonb(v) into r from public.vitrine('endereco-85') v limit 1;
  reset role;
  return r;
end $$;
create or replace function t_estilo() returns text language sql as $$
  select coalesce(t_vitrine()->'salao'->>'enderecoEstilo', t_vitrine()->>'enderecoEstilo', '(nada)')
$$;

\echo ''
\echo '1. Sem escolher'
select t_texto('a vitrine não manda nada', t_estilo(), '(nada)');

\echo ''
\echo '2. Escolhido'
update public.saloes set cfg = '{"enderecoEstilo": "faixa", "cor": "#C2410C"}' where id = '58500000-0000-0000-0000-00000000000a';
select t_texto('"faixa" chega ao link', t_estilo(), 'faixa');

\echo ''
\echo '3. No plano Grátis'
update public.assinaturas set plano = 'gratuito' where salao_id = '58500000-0000-0000-0000-00000000000a';
select t_texto('sai junto com a aparência', t_estilo(), '(nada)');

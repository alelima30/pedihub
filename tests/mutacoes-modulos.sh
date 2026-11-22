#!/usr/bin/env bash
# ===========================================================================
#  Quebrar a peneira da vitrine() de propósito, uma regra por vez.
#
#    bash tests/bancada/subir.sh        (noutro terminal)
#    bash tests/mutacoes-modulos.sh
#
#  Teste verde não prova nada sozinho: prova que o código passa, não que o
#  teste OLHA. Cada mutação aqui estraga uma regra e exige que o
#  `modulos.test.mjs` reprove.
#
#  ⚠ AS PRIMEIRAS TRÊS SÃO DO BANCO, e são as que valem mais. Defeito de tela
#  o dono vê no mesmo dia; defeito na `vitrine()` chega calado — a lista sai
#  na resposta de uma casa que desligou o módulo, ou a função inteira levanta
#  e a página da cliente some sem ninguém saber por quê.
# ===========================================================================
set -u
cd "$(dirname "$0")/.."
T=tests/modulos.test.mjs
export PLAYWRIGHT=${PLAYWRIGHT:-/opt/node22/lib/node_modules/playwright}
export PGHOST="${PGHOST:-/tmp}" PGPORT="${PGPORT:-5444}" PGUSER="${PGUSER:-postgres}"

ARQS="supabase/25_loja.sql"
for a in $ARQS; do cp "$a" "/tmp/mm-$(basename "$a")"; done
restaurar(){
  for a in $ARQS; do cp "/tmp/mm-$(basename "$a")" "$a"; done
  bash versao.sh >/dev/null 2>&1
}
trap restaurar EXIT

viva=0; morta=0; perdida=0
# ⚠ MUTAÇÃO DE SQL PRECISA REINSTALAR O MÓDULO. Dá para reinstalar o 25
# sozinho porque ele é o ÚLTIMO a definir a `vitrine()` — é o que o
# `sintaxe.test.js` confere e cobra. Para qualquer outro módulo vale a regra
# do `tests/bancada/subir.sh`: remonte do zero.
rodar(){ # $1 = nome, $2 = "sql" quando precisa reinstalar
  bash versao.sh >/dev/null 2>&1
  [ "${2:-}" = sql ] && psql -q -d app -v ON_ERROR_STOP=1 \
      -f supabase/25_loja.sql >/dev/null 2>&1
  if node "$T" >/tmp/mm-saida.txt 2>&1; then
    echo "  ✗ SOBREVIVEU — $1"; viva=$((viva+1))
  else
    echo "  ✓ morreu — $1  ($(grep -c '✗' /tmp/mm-saida.txt) reprovações)"
    morta=$((morta+1))
  fi
  restaurar
  [ "${2:-}" = sql ] && psql -q -d app -v ON_ERROR_STOP=1 \
      -f supabase/25_loja.sql >/dev/null 2>&1
  return 0
}

troca(){ python3 - "$1" "$2" "$3" <<'PY'
import sys
arq, de, para = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(arq, encoding='utf-8').read()
n = s.count(de)
if n != 1:
    print('!! o trecho aparece %d vezes em %s' % (n, arq)); sys.exit(9)
open(arq, 'w', encoding='utf-8').write(s.replace(de, para, 1))
PY
  local r=$?
  # ⚠ MUTAÇÃO QUE NÃO RODA NÃO É MUTAÇÃO MORTA. O trecho sumiu ou passou a
  # aparecer duas vezes, e o placar seguia dizendo "N mortas, 0 vivas" com
  # uma a menos. Aconteceu no mutacoes-modulos.sh: a nº 5 ficou sem rodar por
  # sessões inteiras, porque o "!!" passava no meio da saída sem contar.
  [ $r -eq 0 ] || { echo "  ✗ NÃO RODOU — conserte o trecho procurado"; perdida=$((perdida+1)); }
  return $r
}

echo "1. a peneira volta a ser ::boolean, e lixo no cfg derruba a vitrine"
troca supabase/25_loja.sql \
  "      'loja', lower(btrim(coalesce(c.cfg->>'loja', 'true')))
                not in ('false', 'f', '0', 'no', 'nao', 'não')," \
  "      'loja', coalesce((c.cfg->>'loja')::boolean, true)," \
  && rodar "cfg lido com ::boolean" sql

echo "2. o banco deixa o cardápio sair com a loja desligada"
troca supabase/25_loja.sql \
  "       where pr.salao_id = s.id and pr.ativo and pr.venda_online
         and lower(btrim(coalesce(c.cfg->>'loja', 'true')))
               not in ('false', 'f', '0', 'no', 'nao', 'não')), '[]'::jsonb)," \
  "       where pr.salao_id = s.id and pr.ativo and pr.venda_online
         ), '[]'::jsonb)," \
  && rodar "cardápio saindo com a loja desligada" sql

echo "3. chave ausente passa a valer DESLIGADO"
troca supabase/25_loja.sql \
  "      'usaServicos', lower(btrim(coalesce(c.cfg->>'usaServicos', 'true')))" \
  "      'usaServicos', lower(btrim(coalesce(c.cfg->>'usaServicos', 'false')))" \
  && rodar "ausente valendo desligado" sql

# (As mutações de tela da capa do salão — agendar, equipe, Meus horários —
# saíram com os testes do salão. Ficam as três do banco.)

echo ""
echo "$morta mortas, $viva vivas"
[ "$perdida" -eq 0 ] || echo "  ⚠ $perdida mutação(ões) não rodaram"
[ "$viva" -eq 0 ] && [ "$perdida" -eq 0 ]

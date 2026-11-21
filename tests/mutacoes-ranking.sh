#!/usr/bin/env bash
# ===========================================================================
#  Quebrar de propósito o Ranking (60_dashboard.sql e a tela). Uma regra por
#  vez. Cada mutação que sobreviver é um jeito de o ranking mentir — ordem
#  errada, número de outra pessoa, visita contada errado — sem teste acusar.
#
#    bash tests/bancada/subir.sh        (noutro terminal)
#    bash tests/mutacoes-ranking.sh
# ===========================================================================
set -u
cd "$(dirname "$0")/.."
export PLAYWRIGHT=${PLAYWRIGHT:-/opt/node22/lib/node_modules/playwright}
export PGHOST=${PGHOST:-/tmp} PGPORT=${PGPORT:-5444} PGUSER=${PGUSER:-postgres}
BANCO=${PGBANCO:-app}

ARQS="app.html agendar.html supabase/60_dashboard.sql"
for a in $ARQS; do cp "$a" "/tmp/mrk-$(basename "$a")"; done
restaurar(){
  for a in $ARQS; do cp "/tmp/mrk-$(basename "$a")" "$a"; done
  psql -q -d "$BANCO" -f supabase/60_dashboard.sql >/dev/null 2>&1
  bash versao.sh >/dev/null 2>&1
}
trap restaurar EXIT

viva=0; morta=0; perdida=0
rodar(){
  bash versao.sh >/dev/null 2>&1
  psql -q -d "$BANCO" -f supabase/60_dashboard.sql >/dev/null 2>&1
  if node tests/ranking-tela.test.mjs >/tmp/mrk-saida.txt 2>&1; then
    echo "  ✗ SOBREVIVEU — $1"; viva=$((viva+1))
  else
    echo "  ✓ morreu — $1  ($(grep -c '✗' /tmp/mrk-saida.txt) reprovações)"
    morta=$((morta+1))
  fi
  restaurar
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
  [ $r -eq 0 ] || { echo "  ✗ NÃO RODOU — conserte o trecho procurado"; perdida=$((perdida+1)); }
  return $r
}

echo "1. quem atende vê o restaurante inteiro"
troca supabase/60_dashboard.sql \
  "       and (v_prof is null or a.profissional_id = v_prof)" \
  "       and true" \
  && rodar "a profissional vê as clientes e os números das outras"

echo "2. o ranking de quem mais marcou sai ao contrário"
troca supabase/60_dashboard.sql \
  "         order by pc.marcados desc, pc.valor desc, c.nome limit 10) t), '[]'::jsonb)," \
  "         order by pc.marcados asc, pc.valor desc, c.nome limit 10) t), '[]'::jsonb)," \
  && rodar "a cliente que menos veio aparece em 1º"

echo "3. cancelado conta como marcado"
troca supabase/60_dashboard.sql \
  "      'marcados',   (select count(*) from ag where status <> 'cancelado')," \
  "      'marcados',   (select count(*) from ag)," \
  && rodar "o resumo infla com o que não aconteceu"

echo "4. nova pelo link vira nova do balcão"
troca supabase/60_dashboard.sql \
  "      'novasPeloLink', (select count(*) from novas where origem = 'online')," \
  "      'novasPeloLink', 0," \
  && rodar "o link não ganha o crédito das clientes que trouxe"

echo "5. a visita guarda o código do aparelho como veio"
troca supabase/60_dashboard.sql \
  "  values (v_salao, v_dia, md5(v_salao::text || v_dia::text || p_visitante), v_origem)" \
  "  values (v_salao, v_dia, p_visitante, v_origem)" \
  && rodar "dá para seguir a pessoa de um dia para o outro"

echo "6. o link não conta a visita"
troca agendar.html \
  "  contarVisita(slug);" \
  "  void slug;" \
  && rodar "o quadro de visitas fica sempre em zero"

echo "7. a origem do Instagram se perde"
troca agendar.html \
  "    if(tem('instagram') || /Instagram/i.test(ua)) return 'instagram';" \
  "    if(false) return 'instagram';" \
  && rodar "o dono não sabe que o Instagram é o que traz gente"

echo "8. a recepção ganha a aba"
troca app.html \
  "  ['ranking',  'Ranking',          'grafico',    'Dia a dia', ['dono','admin','profissional']]," \
  "  ['ranking',  'Ranking',          'grafico',    'Dia a dia', EQUIPE]," \
  && rodar "aba que abre e só mostra erro"

echo "9. o rendimento do link volta a ser porcentagem"
troca app.html \
  "        \${rkNumero('horários por pessoa que abriu', conv === null ? '—' : conv, 'quanto o link rende', '')}" \
  "        \${rkNumero('horários por pessoa que abriu', conv === null ? '—' : Math.round(L.marcaramPeloLink / L.visitantes * 100) + '%', 'quanto o link rende', '')}" \
  && rodar "150% de quem abriu, marcou"

echo
echo "morreram $morta · sobreviveram $viva · não rodaram $perdida"
[ "$viva" -eq 0 ] && [ "$perdida" -eq 0 ]

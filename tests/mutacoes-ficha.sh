#!/usr/bin/env bash
# ===========================================================================
#  Quebrar de propósito a ficha do serviço (62_ficha_servico.sql e as telas).
#  Uma regra por vez. Cada mutação que sobreviver é um jeito de a ficha
#  mostrar o que não devia — serviço escondido, texto do vizinho, HTML que
#  roda, preço que o dono escondeu — sem teste nenhum acusar.
#
#    bash tests/bancada/subir.sh        (noutro terminal)
#    bash tests/mutacoes-ficha.sh
# ===========================================================================
set -u
cd "$(dirname "$0")/.."
export PLAYWRIGHT=${PLAYWRIGHT:-/opt/node22/lib/node_modules/playwright}
export PGHOST=${PGHOST:-/tmp} PGPORT=${PGPORT:-5444} PGUSER=${PGUSER:-postgres}
BANCO=${PGBANCO:-app}

ARQS="app.html agendar.html supabase/62_ficha_servico.sql"
for a in $ARQS; do cp "$a" "/tmp/mfi-$(basename "$a")"; done
restaurar(){
  for a in $ARQS; do cp "/tmp/mfi-$(basename "$a")" "$a"; done
  psql -q -d "$BANCO" -f supabase/62_ficha_servico.sql >/dev/null 2>&1
  bash versao.sh >/dev/null 2>&1
}
trap restaurar EXIT

# O teste do banco roda numa transação desfeita no fim: não deixa rastro.
SQLT=/tmp/mfi-sql.sql
printf 'begin;\n\\i tests/00_ajuda.sql\n\\i tests/ficha_servico.test.sql\nrollback;\n' > "$SQLT"

viva=0; morta=0; perdida=0
rodar(){
  bash versao.sh >/dev/null 2>&1
  psql -q -d "$BANCO" -f supabase/62_ficha_servico.sql >/dev/null 2>&1
  local falhou=0
  psql -q -v ON_ERROR_STOP=1 -d "$BANCO" -f "$SQLT" >/tmp/mfi-saida.txt 2>&1 || falhou=1
  grep -q '✗' /tmp/mfi-saida.txt && falhou=1
  if [ $falhou -eq 0 ]; then
    node tests/ficha-tela.test.mjs >>/tmp/mfi-saida.txt 2>&1 || falhou=1
  fi
  if [ $falhou -eq 0 ]; then
    echo "  ✗ SOBREVIVEU — $1"; viva=$((viva+1))
  else
    echo "  ✓ morreu — $1  ($(grep -c '✗\|ERROR' /tmp/mfi-saida.txt) reprovações)"
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

echo "1. comparar com o serviço de outro salão"
troca supabase/62_ficha_servico.sql \
  "                         and s.salao_id = new.salao_id)) then" \
  "                         )) then" \
  && rodar "a ficha publica o serviço do concorrente"

echo "2. o link entrega a ficha de serviço que não aceita marcação online"
troca supabase/62_ficha_servico.sql \
  "     and v.ativo and v.aceita_online and v.ficha is not null" \
  "     and v.ativo and v.ficha is not null" \
  && rodar "serviço escondido aparece no link"

echo "3. o link entrega a ficha de salão suspenso"
troca supabase/62_ficha_servico.sql \
  "   where s.slug = p_slug and s.status = 'ativo'" \
  "   where s.slug = p_slug" \
  && rodar "salão fora do ar continua publicando"

echo "4. o incluso sem teto"
troca supabase/62_ficha_servico.sql \
  "      if v is not null and jsonb_array_length(lista) < 15 then" \
  "      if v is not null then" \
  && rodar "lista de qualquer tamanho"

echo "5. a limpeza aberta ao mundo"
troca supabase/62_ficha_servico.sql \
  "revoke all on function public.ficha_limpa(jsonb) from public, anon, authenticated;" \
  "grant execute on function public.ficha_limpa(jsonb) to anon;" \
  && rodar "peça de dentro vira porta"

echo "6. tocar no atalho escolhe o serviço"
troca agendar.html \
  "      onclick=\"event.stopPropagation(); abrirFolha('ficha:\${escapar(s.id)}', this)\"" \
  "      onclick=\"abrirFolha('ficha:\${escapar(s.id)}', this)\"" \
  && rodar "quem só queria ler já sai com o serviço marcado"

echo "7. o texto do dono sem escapar"
troca agendar.html \
  "        \${f.cuidadosDepois ? \`<p><b>Depois:</b> \${escapar(f.cuidadosDepois)}</p>\` : ''}" \
  "        \${f.cuidadosDepois ? \`<p><b>Depois:</b> \${f.cuidadosDepois}</p>\` : ''}" \
  && rodar "HTML do texto roda na página da cliente"

echo "8. a ficha mostra o preço que o dono escondeu na capa"
troca agendar.html \
  "  if(tela === 'capa' && salao.precoNaCapa !== true) return '';" \
  "" \
  && rodar "preço aparece pela porta dos fundos"

echo "9. o painel não grava a ficha"
troca app.html \
  "  if(ficha || (sid && (acharServico(sid) || {}).ficha)) dados.ficha = ficha;" \
  "" \
  && rodar "a dona escreve e nada vai para o link"

echo "10. o convite lista serviço sem ficha"
troca agendar.html \
  "  const svs = servicosComFicha();
  if(!svs.length) return '';
  const nomes = svs.slice(0, 4);" \
  "  const svs = servicosComFicha();
  if(!svs.length) return '';
  const nomes = servicosDoSalao().slice(0, 4);" \
  && rodar "a cliente toca e não abre nada"

echo "11. o modelo do passo a passo passa por cima do que a dona escreveu"
troca app.html \
  "  return servsAtivos().filter(s => !s.ficha)
    .map(s => [s, modeloQueCombina(s.nome)]).filter(([, m]) => m);" \
  "  return servsAtivos()
    .map(s => [s, modeloQueCombina(s.nome)]).filter(([, m]) => m);" \
  && rodar "o texto da dona some trocado pelo modelo"

echo
echo "$morta morreram, $viva sobreviveram, $perdida não rodaram"
[ $viva -eq 0 ] && [ $perdida -eq 0 ]

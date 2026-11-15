#!/usr/bin/env bash
# ===========================================================================
#  Quebrar de propósito os avisos no celular (59_push.sql, webpush.js, sw.js
#  e a janela do painel). Uma regra por vez.
#
#    bash tests/bancada/subir.sh        (noutro terminal)
#    bash tests/mutacoes-push.sh
#
#  Cada mutação que sobreviver é um jeito de o aviso tocar para quem não
#  devia, não tocar para quem devia, ou chegar ilegível no celular — sem
#  teste nenhum acusar. As do banco são aplicadas na bancada e desfeitas.
# ===========================================================================
set -u
cd "$(dirname "$0")/.."
export PLAYWRIGHT=${PLAYWRIGHT:-/opt/node22/lib/node_modules/playwright}
export PGHOST=${PGHOST:-/tmp} PGPORT=${PGPORT:-5444} PGUSER=${PGUSER:-postgres}
BANCO=${PGBANCO:-app}

ARQS="app.html sw.js supabase/59_push.sql supabase/functions/enviar-notificacoes/webpush.js"
for a in $ARQS; do cp "$a" "/tmp/mpu-$(basename "$a")"; done
restaurar(){
  for a in $ARQS; do cp "/tmp/mpu-$(basename "$a")" "$a"; done
  psql -q -d "$BANCO" -f supabase/59_push.sql >/dev/null 2>&1
  bash versao.sh >/dev/null 2>&1
}
trap restaurar EXIT

viva=0; morta=0; perdida=0
rodar(){
  bash versao.sh >/dev/null 2>&1
  psql -q -d "$BANCO" -f supabase/59_push.sql >/dev/null 2>&1
  if node tests/push-cripto.test.mjs >/tmp/mpu-saida.txt 2>&1 \
     && node tests/push-tela.test.mjs >>/tmp/mpu-saida.txt 2>&1; then
    echo "  ✗ SOBREVIVEU — $1"; viva=$((viva+1))
  else
    echo "  ✓ morreu — $1  ($(grep -c '✗' /tmp/mpu-saida.txt) reprovações)"
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

echo "1. horário pelo link não avisa ninguém"
troca supabase/59_push.sql \
  "  if new.origem <> 'online' or new.status not in ('pendente', 'confirmado')" \
  "  if true or new.status not in ('pendente', 'confirmado')" \
  && rodar "a cliente marca e o celular fica mudo"

echo "2. o aviso vai para o salão inteiro, e não para quem o ligou"
troca supabase/59_push.sql \
  "   where a.salao_id = p_salao and a.perfil_id = any(p_perfis)" \
  "   where a.salao_id = p_salao" \
  && rodar "a Bia recebe o horário da Ju"

echo "3. a cifra esquece o delimitador do registro"
troca supabase/functions/enviar-notificacoes/webpush.js \
  "  const claro = juntar(te.encode(texto), new Uint8Array([2]));" \
  "  const claro = juntar(te.encode(texto), new Uint8Array([0]));" \
  && rodar "o celular descarta o aviso calado"

echo "4. o crachá leva o endereço inteiro do aparelho"
troca supabase/functions/enviar-notificacoes/webpush.js \
  "    aud: new URL(endpoint).origin," \
  "    aud: endpoint," \
  && rodar "o segredo do aparelho vaza no token e o Google recusa"

echo "5. o service worker não mostra nada"
troca sw.js \
  "  ev.waitUntil(self.registration.showNotification(titulo, {" \
  "  ev.waitUntil(Promise.resolve(titulo, {" \
  && rodar "o aviso chega e o celular não toca"

echo "6. a tela se inscreve com uma chave qualquer"
troca app.html \
  "    const opcoes = { userVisibleOnly: true, applicationServerKey: this.chaveEmBytes(chave) };" \
  "    const opcoes = { userVisibleOnly: true, applicationServerKey: this.chaveEmBytes('BAAA') };" \
  && rodar "inscrição que o servidor não consegue usar"

echo "7. a tela pede permissão sozinha, ao abrir"
troca app.html \
  "  if(!soVisibilidade) pintarEstadoAvisosCelular();" \
  "  if(!soVisibilidade){ pintarEstadoAvisosCelular(); Notification.requestPermission(); }" \
  && rodar "o navegador bloqueia quem pede sem toque"

echo "8. o sino não oferece o aviso (a recepção fica sem caminho)"
troca app.html \
  "    \${AvisosCelular.suportado() || AvisosCelular.iphoneSemInstalar() ? \`<button type=\"button\" class=\"sino-item\" id=\"sinoAvisosCelular\"" \
  "    \${false ? \`<button type=\"button\" class=\"sino-item\" id=\"sinoAvisosCelular\"" \
  && rodar "quem não vê Meu negócio não liga nunca"

echo "9. desligar não apaga o aparelho do banco"
troca app.html \
  "    await Dados.chamar('push_remover', { p_endpoint: sub.endpoint });" \
  "    void sub;" \
  && rodar "desliga na tela e o celular continua tocando"

echo
echo "morreram $morta · sobreviveram $viva · não rodaram $perdida"
[ "$viva" -eq 0 ] && [ "$perdida" -eq 0 ]

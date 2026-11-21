/* ===========================================================================
   PediHub — Web Push sem biblioteca, em Web Crypto puro
   (RFC 8291, a cifra do recado; RFC 8292, o crachá VAPID)

   ── POR QUE NÃO UMA BIBLIOTECA ─────────────────────────────────────────────
   As conhecidas ou são do Node (`web-push`, que depende de módulo nativo de
   criptografia) ou são do Deno — e este arquivo precisa rodar NOS DOIS: no
   Deno porque a função de borda é Deno, e no Node porque é onde a suíte
   roda. Web Crypto (`crypto.subtle`) existe idêntico nos dois, e o protocolo
   cabe em ~150 linhas. O teste `push-cripto.test.mjs` faz o papel do
   celular: decifra o que daqui sai e confere o crachá, byte a byte.

   ── COMO O PUSH FUNCIONA, EM UMA RESPIRADA ─────────────────────────────────
   Quando a pessoa liga o aviso, o navegador dela entrega um ENDEREÇO
   (endpoint, no servidor do Google/Apple/Mozilla) e DUAS CHAVES (p256dh e
   auth). Para avisar, a gente:

     1. CIFRA o recado com as chaves do aparelho (aes128gcm) — nem o Google
        consegue ler o que passa por ele;
     2. ASSINA um crachá (JWT ES256) com a NOSSA chave VAPID, provando que é
        o PediHub — o mesmo PediHub de quando a pessoa ligou o aviso;
     3. faz um POST no endereço. 201 = entregue ao serviço; 404/410 = a
        inscrição morreu (app removido, permissão revogada).
   =========================================================================== */

const te = new TextEncoder();

const b64u = {
  dec(s) {
    const b = atob(String(s || '').replace(/-/g, '+').replace(/_/g, '/')
      .padEnd(Math.ceil(String(s || '').length / 4) * 4, '='));
    return Uint8Array.from(b, (c) => c.charCodeAt(0));
  },
  enc(bytes) {
    let s = '';
    for (const x of new Uint8Array(bytes)) s += String.fromCharCode(x);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  },
};

function juntar(...pedacos) {
  const total = pedacos.reduce((n, p) => n + p.length, 0);
  const fora = new Uint8Array(total);
  let i = 0;
  for (const p of pedacos) { fora.set(p, i); i += p.length; }
  return fora;
}

/* HKDF do Web Crypto já é Extract+Expand em um passo — exatamente as duplas
   que o RFC 8291 pede. */
async function hkdf(salt, ikm, info, bits) {
  const chave = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  const saida = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt, info }, chave, bits);
  return new Uint8Array(saida);
}

/* ── AS CHAVES DO CORREIO (VAPID) ─────────────────────────────────────────
   Geradas UMA vez e guardadas no banco (push_config). A pública é o que o
   navegador recebe ao ligar o aviso; trocá-la invalida toda inscrição. */
export async function gerarChaves(contato) {
  const par = await crypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const privadaJwk = await crypto.subtle.exportKey('jwk', par.privateKey);
  const publica = b64u.enc(await crypto.subtle.exportKey('raw', par.publicKey));
  return { publica, privadaJwk, contato: contato || 'mailto:contato@pedihub.app' };
}

/* O crachá: um JWT ES256 por ORIGEM de endpoint (RFC 8292). O `aud` é só o
   começo do endereço (https://fcm.googleapis.com), nunca o endereço inteiro
   — endpoint é segredo e não entra em token nenhum. */
export async function crachaVapid(chaves, endpoint, agoraMs) {
  const cabeca = b64u.enc(te.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const corpo = b64u.enc(te.encode(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor((agoraMs ?? Date.now()) / 1000) + 12 * 3600,
    sub: chaves.contato || 'mailto:contato@pedihub.app',
  })));
  const privada = await crypto.subtle.importKey('jwk', chaves.privadaJwk,
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const ass = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' },
    privada, te.encode(cabeca + '.' + corpo));
  return cabeca + '.' + corpo + '.' + b64u.enc(ass);
}

/* ── A CIFRA DO RECADO (RFC 8291, aes128gcm) ──────────────────────────────
   Um par de chaves NOVO por recado (o "as", application server efêmero),
   segredo combinado por ECDH com a chave do aparelho, e as duas derivações
   do RFC. O corpo já sai com o cabeçalho de registro na frente:
   salt(16) + tamanho(4) + idlen(1) + chave_as(65) + cifrado. */
export async function cifrar(texto, p256dh, auth) {
  const uaPub = await crypto.subtle.importKey('raw', b64u.dec(p256dh),
    { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const as = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const asPub = new Uint8Array(await crypto.subtle.exportKey('raw', as.publicKey));

  const segredo = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'ECDH', public: uaPub }, as.privateKey, 256));

  const ikm = await hkdf(b64u.dec(auth), segredo,
    juntar(te.encode('WebPush: info\0'), b64u.dec(p256dh), asPub), 256);

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 128);
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 96);

  // 0x02 fecha o único registro. Sem ele o navegador descarta calado.
  const claro = juntar(te.encode(texto), new Uint8Array([2]));
  const chaveAes = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const cifrado = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce }, chaveAes, claro));

  const cabeca = new Uint8Array(16 + 4 + 1 + 65);
  cabeca.set(salt, 0);
  new DataView(cabeca.buffer).setUint32(16, 4096);   // tamanho de registro
  cabeca[20] = 65;
  cabeca.set(asPub, 21);
  return juntar(cabeca, cifrado);
}

/* ── O ENVIO ──────────────────────────────────────────────────────────────
   Devolve { ok } ou { ok:false, codigo } — 'sumiu' é o único código que o
   banco trata diferente (apaga o aparelho). O corpo da resposta não entra
   no retorno: pode ter detalhe do serviço, e quem loga é o chamador. */
export async function enviar(chaves, aparelho, recado, ttlSegundos) {
  let corpo;
  try {
    corpo = await cifrar(JSON.stringify(recado), aparelho.p256dh, aparelho.auth);
  } catch (e) {
    // Chave de aparelho corrompida não melhora tentando de novo.
    return { ok: false, codigo: 'sumiu' };
  }
  const cracha = await crachaVapid(chaves, aparelho.endpoint);
  let r;
  try {
    r = await fetch(aparelho.endpoint, {
      method: 'POST',
      headers: {
        'Content-Encoding': 'aes128gcm',
        'Content-Type': 'application/octet-stream',
        TTL: String(ttlSegundos ?? 7200),
        Urgency: 'high',
        Authorization: 'vapid t=' + cracha + ', k=' + chaves.publica,
      },
      body: corpo,
    });
  } catch (e) {
    return { ok: false, codigo: 'rede' };
  }
  if (r.ok) return { ok: true };
  if (r.status === 404 || r.status === 410) return { ok: false, codigo: 'sumiu' };
  return { ok: false, codigo: String(r.status) };
}

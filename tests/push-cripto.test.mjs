/* ═══════════════════════════════════════════════════════════════════════════
   A CIFRA DO PUSH, CONFERIDA DO LADO DO CELULAR

   O webpush.js cifra o recado e assina o crachá. Este teste faz o papel do
   NAVEGADOR DO APARELHO: gera as chaves que um celular geraria, recebe o que
   o worker mandaria, DECIFRA com a parte privada (que só o teste tem, como
   só o celular teria) e confere o crachá com a chave pública — byte a byte,
   pelos RFCs 8291 e 8292. Se isto passa, o que sai daqui é o que Chrome,
   Safari e Firefox esperam receber.

   E o envio: um servidorzinho local recebe o POST e o teste confere os
   cabeçalhos, o tratamento de 201/410/500 e que NADA legível viaja no corpo.
   ═══════════════════════════════════════════════════════════════════════════ */
import http from 'node:http';
import { gerarChaves, crachaVapid, cifrar, enviar }
  from '../supabase/functions/enviar-notificacoes/webpush.js';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const igual = (m, a, b) => a === b ? ok(m) : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const secao = t => console.log('\n' + t);

const te = new TextEncoder(), td = new TextDecoder();
const b64uDec = s => Uint8Array.from(
  atob(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '=')),
  c => c.charCodeAt(0));
const b64uEnc = b => btoa(String.fromCharCode(...new Uint8Array(b)))
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const junta = (...ps) => { const f = new Uint8Array(ps.reduce((n, p) => n + p.length, 0));
  let i = 0; for (const p of ps) { f.set(p, i); i += p.length; } return f; };
async function hkdf(salt, ikm, info, bits){
  const k = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt, info }, k, bits));
}

/* ── O celular de mentira: um par ECDH + o segredo auth, como o navegador
      cria na hora de ligar o aviso. ─────────────────────────────────────── */
async function celular(){
  const par = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  return {
    par,
    p256dh: b64uEnc(await crypto.subtle.exportKey('raw', par.publicKey)),
    auth: b64uEnc(crypto.getRandomValues(new Uint8Array(16))),
  };
}

/* A decifragem do RFC 8291, inteira, do lado de quem recebe. */
async function decifrarComoOCelular(cel, corpo){
  const salt = corpo.slice(0, 16);
  const rs = new DataView(corpo.buffer, corpo.byteOffset).getUint32(16);
  const idlen = corpo[20];
  const asPub = corpo.slice(21, 21 + idlen);
  const cifrado = corpo.slice(21 + idlen);

  const asKey = await crypto.subtle.importKey('raw', asPub,
    { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const segredo = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'ECDH', public: asKey }, cel.par.privateKey, 256));
  const ikm = await hkdf(b64uDec(cel.auth), segredo,
    junta(te.encode('WebPush: info\0'), b64uDec(cel.p256dh), asPub), 256);
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 128);
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 96);
  const chave = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt']);
  const claro = new Uint8Array(await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: nonce }, chave, cifrado));
  return { rs, idlen, delimitador: claro[claro.length - 1],
           texto: td.decode(claro.slice(0, -1)) };
}

/* ═══════════════════════════════════ 1 ══ */
secao('1. As chaves do correio');
const chaves = await gerarChaves('mailto:oi@exemplo.com');
verdade('a pública tem 65 bytes e começa com 0x04 (ponto P-256 sem compressão)',
  b64uDec(chaves.publica).length === 65 && b64uDec(chaves.publica)[0] === 4);
verdade('a privada sai como JWK de P-256, com a parte secreta presente',
  chaves.privadaJwk && chaves.privadaJwk.crv === 'P-256' && !!chaves.privadaJwk.d);
igual('e o contato vai junto', chaves.contato, 'mailto:oi@exemplo.com');
const chaves2 = await gerarChaves();
verdade('cada geração é um par novo', chaves2.publica !== chaves.publica);

/* ═══════════════════════════════════ 2 ══ */
secao('2. O crachá VAPID, conferido com a chave pública');
const ENDPOINT = 'https://fcm.googleapis.com/fcm/send/abc123segredo';
const cracha = await crachaVapid(chaves, ENDPOINT, Date.now());
const [c1, c2, c3] = cracha.split('.');
igual('três partes, como todo JWT', cracha.split('.').length, 3);
igual('o cabeçalho diz ES256', JSON.parse(td.decode(b64uDec(c1))).alg, 'ES256');
const corpoJwt = JSON.parse(td.decode(b64uDec(c2)));
igual('o aud é SÓ a origem — o endpoint inteiro é segredo e não entra',
  corpoJwt.aud, 'https://fcm.googleapis.com');
verdade('vence em até 24 horas, como o RFC exige',
  corpoJwt.exp > Date.now() / 1000 && corpoJwt.exp <= Date.now() / 1000 + 24 * 3600);
igual('o sub é o contato', corpoJwt.sub, 'mailto:oi@exemplo.com');
{
  const pub = await crypto.subtle.importKey('raw', b64uDec(chaves.publica),
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
  verdade('a assinatura confere com a chave pública',
    await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub,
      b64uDec(c3), te.encode(c1 + '.' + c2)));
  verdade('e um byte trocado derruba a verificação', !(await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' }, pub, b64uDec(c3), te.encode(c1 + '.' + c2 + 'x'))));
}

/* ═══════════════════════════════════ 3 ══ */
secao('3. A cifra, decifrada do lado do celular');
const cel = await celular();
const RECADO = JSON.stringify({ titulo: 'Horário novo pelo link',
  corpo: 'Maria · 22/11 às 14:00 · com Ju', url: './app.html#agenda' });
const corpo = await cifrar(RECADO, cel.p256dh, cel.auth);
{
  const d = await decifrarComoOCelular(cel, corpo);
  igual('o celular decifra e lê exatamente o que foi mandado', d.texto, RECADO);
  igual('o registro fecha com 0x02, como o RFC 8291 pede', d.delimitador, 2);
  igual('tamanho de registro de 4096', d.rs, 4096);
  igual('a chave efêmera viaja com 65 bytes', d.idlen, 65);
}
verdade('nada do recado viaja legível no corpo cifrado',
  !td.decode(corpo).includes('Maria') && !td.decode(corpo).includes('Hor'));
{
  const corpo2 = await cifrar(RECADO, cel.p256dh, cel.auth);
  verdade('cifrar duas vezes nunca repete um byte sequer (salt e chave novos)',
    b64uEnc(corpo) !== b64uEnc(corpo2));
  const outro = await celular();
  let vazou = null;
  try{ vazou = await decifrarComoOCelular(outro, corpo); }catch(e){}
  verdade('outro aparelho, com outras chaves, não decifra', vazou === null,
    vazou && vazou.texto);
}

/* ═══════════════════════════════════ 4 ══ */
secao('4. O envio: cabeçalhos e respostas');
let visto = null; let responder = () => [201, ''];
const servidor = http.createServer((req, res) => {
  const pedacos = [];
  req.on('data', d => pedacos.push(d));
  req.on('end', () => {
    visto = { headers: req.headers, corpo: Buffer.concat(pedacos) };
    const [st, tx] = responder();
    res.writeHead(st); res.end(tx);
  });
});
await new Promise(r => servidor.listen(0, '127.0.0.1', r));
const base = 'http://127.0.0.1:' + servidor.address().port;
const aparelho = { endpoint: base + '/send/xyz', p256dh: cel.p256dh, auth: cel.auth };

let r = await enviar(chaves, aparelho, { titulo: 'Oi', corpo: 'corpo' }, 7200);
verdade('201 do serviço = entregue', r.ok === true, JSON.stringify(r));
igual('Content-Encoding: aes128gcm', visto.headers['content-encoding'], 'aes128gcm');
igual('TTL de 2 horas — igual ao prazo de validade da fila', visto.headers.ttl, '7200');
igual('urgência alta: é para tocar o celular', visto.headers.urgency, 'high');
verdade('Authorization no formato vapid t=…, k=<nossa pública>',
  /^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=/.test(visto.headers.authorization || '')
  && visto.headers.authorization.endsWith('k=' + chaves.publica));
{
  const d = await decifrarComoOCelular(cel, new Uint8Array(visto.corpo));
  igual('o corpo que viajou decifra no aparelho de destino',
    JSON.parse(d.texto).titulo, 'Oi');
}
responder = () => [410, 'gone'];
r = await enviar(chaves, aparelho, { titulo: 'Oi' });
igual('410 vira o código "sumiu" — o banco apaga o aparelho', r.codigo, 'sumiu');
responder = () => [404, '']; r = await enviar(chaves, aparelho, {});
igual('404 idem', r.codigo, 'sumiu');
responder = () => [500, 'quebrou']; r = await enviar(chaves, aparelho, {});
igual('500 vira "500", para tentar de novo', r.codigo, '500');
verdade('e nunca ok', r.ok === false);
r = await enviar(chaves, { endpoint: 'http://127.0.0.1:1/x',
  p256dh: cel.p256dh, auth: cel.auth }, {});
igual('rede fora do ar vira "rede", não explosão', r.codigo, 'rede');
r = await enviar(chaves, { endpoint: base + '/x', p256dh: 'lixo!!', auth: 'x' }, {});
igual('chave de aparelho corrompida vira "sumiu" — repetir não conserta', r.codigo, 'sumiu');
servidor.close();

console.log(`\n${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

/* ═══════════════════════════════════════════════════════════════════════════
   AVISOS NO CELULAR, DE PONTA A PONTA (59_push.sql)

   Um navegador de verdade abre o painel. O "celular" é de mentira só onde o
   sandbox não tem saída: o serviço de push do Google/Apple. No lugar dele,
   a inscrição devolve chaves que ESTE teste gerou — e por isso, no fim, o
   teste consegue decifrar o aviso exatamente como o celular decifraria.

     1. Meu negócio → Notificações mostra o cartão; o sino tem a entrada;
     2. Ligar: pede a permissão, inscreve, grava o aparelho DESTA pessoa;
     3. a cliente marca pelo link → o aviso entra na fila;
     4. o worker (o mesmo código da função de borda) cifra e entrega, e o
        "celular" decifra: "Horário novo pelo link · Maria · ... às 14:00";
     5. o service worker mostra o aviso, e o toque abre a agenda;
     6. Mandar um aviso de teste; Desligar;
     7. permissão negada explica como liberar; iPhone sem instalar ensina a
        instalar; a recepção (que não vê Meu negócio) liga pelo sino.
   ═══════════════════════════════════════════════════════════════════════════ */
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from './pg.mjs';
import { gerarChaves, enviar } from '../supabase/functions/enviar-notificacoes/webpush.js';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let ok = 0, ruim = 0;
const e = (m, c, d) => c ? (console.log('  ✓ ' + m), ok++)
                         : (console.log('  ✗ ' + m + (d ? '\n      ' + d : '')), ruim++);
const secao = t => console.log('\n' + t);

function aba(){
  const g = {};
  const j = { AGENDAPRO:{ url:BASE, chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(RAIZ + '/dados.js','utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
const um = async (sql, args = []) => (await banco.query(sql, args)).rows[0];
const todos = async (sql, args = []) => (await banco.query(sql, args)).rows;

/* ── O correio: as chaves que o worker criaria na primeira volta ───────── */
const CHAVES = (await um(`select public.push_config_ler() as c`)).c
  || (await um(`select public.push_config_gravar($1::jsonb) as c`, [JSON.stringify(await gerarChaves())])).c;

/* ── O "celular": as chaves que o navegador do aparelho geraria ────────── */
const b64u = b => Buffer.from(b).toString('base64url');
const parCel = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
const CEL = {
  p256dh: b64u(await crypto.subtle.exportKey('raw', parCel.publicKey)),
  auth: b64u(crypto.getRandomValues(new Uint8Array(16))),
  endpoint: 'https://push.teste.agendapro/ep-' + Date.now().toString(36),
};

/* ── O salão ─────────────────────────────────────────────────────────────── */
const m = Date.now().toString(36);
const dona = aba();
await dona.criarConta({ email:`push-${m}@t.com`, senha:'minhasenhaboa',
  nome:'Dona do Aviso', telefone:'+5511' + (900000000 + (Date.now() % 89999999)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao:'Salão do Aviso ' + m,
  p_tipo:'salao', p_telefone:'(11) 99887-6655', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;
await banco.query(`update public.assinaturas set plano = 'salao', status = 'ativa', trial_ate = null where salao_id = $1`, [SALAO]);
const prof = (await dona.lista('profissionais', { salaoId: SALAO }))[0];
await banco.query(`update public.profissionais set aceita_online = true, nome = 'Ju' where id = $1`, [prof.id]);
for(let i = 0; i <= 6; i++)
  await dona.inserir('jornadas', { profissionalId: prof.id, diaSemana:i, inicio:'08:00', fim:'20:00' });
const corte = await dona.inserir('servicos', { salaoId:SALAO, nome:'Corte',
  preco:50, duracaoMin:60, intervaloMin:0, ativo:true, aceitaOnline:true });
await banco.query(`insert into public.servicos_profissionais (servico_id, profissional_id)
  values ($1, $2) on conflict do nothing`, [corte.id, prof.id]);

// A recepção, que não vê Meu negócio.
const rec = aba();
await rec.criarConta({ email:`push-r-${m}@t.com`, senha:'minhasenhaboa',
  nome:'Rita Recepção', telefone:'+5511' + (800000000 + (Date.now() % 89999999)) });
const recId = (await um(`select id from auth.users where id = (select id from public.perfis where nome = 'Rita Recepção' order by criado_em desc limit 1)`)).id;
await banco.query(`insert into public.vinculos (perfil_id, salao_id, papel) values ($1, $2, 'recepcao')`, [recId, SALAO]);

/* ── O navegador, com o serviço de push trocado pelo "celular" ─────────── */
const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
async function abrir(sessao, op = {}){
  const ctx = await nav.newContext(Object.assign({ viewport:{ width:390, height:844 } }, op.ctx || {}));
  const p = await ctx.newPage();
  p.on('pageerror', x => erros.push('pageerror: ' + x.message));
  p.on('dialog', async d => { erros.push('ALERT: ' + d.message()); await d.dismiss(); });
  await p.addInitScript(([base, ses, cel, perm]) => {
    window.AGENDAPRO = { url: base, chave:'k', ambiente:'bancada' };
    localStorage.setItem('agendapro.sessao', JSON.stringify(ses));
    // A permissão do navegador: começa como o teste mandar, e "Permitir" ao pedir.
    let permissao = perm;
    window.__pedidosDePermissao = 0;
    Object.defineProperty(Notification, 'permission', { get: () => permissao, configurable: true });
    Notification.requestPermission = async () => {
      window.__pedidosDePermissao++;
      if(permissao === 'default') permissao = 'granted';
      return permissao;
    };
    // O serviço de push do aparelho: devolve as chaves do "celular" do teste.
    let inscrito = null;
    const pm = {
      async getSubscription(){ return inscrito; },
      async subscribe(op){
        window.__chaveUsada = btoa(String.fromCharCode(...new Uint8Array(op.applicationServerKey)));
        inscrito = { endpoint: cel.endpoint,
          toJSON(){ return { endpoint: cel.endpoint, keys: { p256dh: cel.p256dh, auth: cel.auth } }; },
          async unsubscribe(){ inscrito = null; window.__desinscreveu = true; return true; } };
        return inscrito;
      },
    };
    Object.defineProperty(ServiceWorkerRegistration.prototype, 'pushManager',
      { get: () => pm, configurable: true });
  }, [BASE, sessao, CEL, op.permissao || 'default']);
  await p.goto(BASE + '/app.html');
  await p.waitForTimeout(3500);
  return p;
}
const textoDoModal = p => p.evaluate(() =>
  document.getElementById('modalTitulo').textContent + ' · ' + document.getElementById('modalCorpo').innerText);
const botoesDoModal = p => p.evaluate(() =>
  [...document.querySelectorAll('#modalPe button')].map(b => b.textContent.trim()));

const p = await abrir(dona.sessao());

/* ═══════════════════════════════════ 1 ══ */
secao('1. Onde se liga');
await p.evaluate(() => irPara('salao'));   // no celular o menu fica recolhido
await p.waitForTimeout(800);
await p.evaluate(() => trocarAbaSalao('notificacoes'));
await p.waitForTimeout(800);
const cartao = await p.evaluate(() => (document.getElementById('cartaoAvisosCelular') || {}).innerText || '');
e('o cartão "Avisos no celular" está em Notificações', /Avisos no celular/.test(cartao), cartao.slice(0, 80));
e('e promete o que é verdade: não gasta mensagem do plano', /Não gasta nenhuma mensagem do seu plano/.test(cartao));
e('diz que está desligado neste aparelho', /Desligado neste aparelho/.test(cartao), cartao);
e('nada pediu permissão sozinho (o navegador recusa pedido sem toque)',
  await p.evaluate(() => window.__pedidosDePermissao) === 0);

/* ═══════════════════════════════════ 2 ══ */
secao('2. Ligar');
await p.click('#cartaoAvisosCelular button:has-text("Avisos neste celular")');
await p.waitForTimeout(1200);
e('a janela explica e oferece Ligar — ' + JSON.stringify(await botoesDoModal(p)),
  (await botoesDoModal(p)).includes('Ligar avisos neste aparelho'));
await p.click('#modalPe button:has-text("Ligar avisos neste aparelho")');
await p.waitForTimeout(2500);
e('pediu a permissão uma vez', await p.evaluate(() => window.__pedidosDePermissao) === 1);
e('e se inscreveu com a chave pública DO BANCO',
  await p.evaluate(() => window.__chaveUsada) === Buffer.from(CHAVES.publica, 'base64url').toString('base64'));
const ap = await um(`select a.*, v.papel from public.push_aparelhos a
  join public.vinculos v on v.perfil_id = a.perfil_id and v.salao_id = a.salao_id
  where a.salao_id = $1`, [SALAO]);
e('o aparelho ficou gravado para a DONA, neste salão',
  ap && ap.papel === 'dono' && ap.endpoint === CEL.endpoint && ap.p256dh === CEL.p256dh, JSON.stringify(ap));
e('com um nome que a pessoa reconhece — ' + JSON.stringify(ap && ap.rotulo),
  /·/.test((ap && ap.rotulo) || ''));
const depois = await textoDoModal(p);
e('a janela diz que está ligado e lista o aparelho', /Ligado neste aparelho/.test(depois) && depois.includes(ap.rotulo), depois);
e('e oferece o teste e o desligar — ' + JSON.stringify(await botoesDoModal(p)),
  JSON.stringify(await botoesDoModal(p)) === '["Desligar neste aparelho","Mandar um aviso de teste"]');

/* ═══════════════════════════════════ 3 ══ */
secao('3. A cliente marca pelo link');
/* Uma segunda profissional, a Bia, com o aviso ligado no aparelho dela. O
   horário é da Ju: o celular da Bia tem de ficar quieto. */
const BIA = (await um(`select gen_random_uuid() as id`)).id;
await banco.query(`insert into auth.users (id) values ($1)`, [BIA]);
await banco.query(`insert into public.perfis (id, nome, telefone) values ($1, 'Bia', '+5511955554444')
  on conflict (id) do update set nome = 'Bia'`, [BIA]);
await banco.query(`insert into public.vinculos (perfil_id, salao_id, papel) values ($1, $2, 'profissional')`, [BIA, SALAO]);
await banco.query(`insert into public.push_aparelhos (salao_id, perfil_id, endpoint, p256dh, auth, rotulo)
  values ($1, $2, 'https://push.teste.agendapro/bia-${m}', $3, $4, 'Celular da Bia')`,
  [SALAO, BIA, CEL.p256dh, CEL.auth]);
const dia = (await um(`select to_char((now() at time zone 'America/Sao_Paulo')::date + 2, 'YYYY-MM-DD') d`)).d;
const cliente = aba();
await cliente.chamar('agendar', { p_profissional: prof.id, p_inicio: dia + ' 14:00:00 America/Sao_Paulo',
  p_servicos: [corte.id], p_nome: 'Maria Souza', p_telefone: '11977776666' });
const fila = await todos(`select f.* from public.push_fila f join public.push_aparelhos a on a.id = f.aparelho_id
  where a.salao_id = $1 and f.status = 'pendente' and a.perfil_id <> $2`, [SALAO, BIA]);
e('o celular da Bia, que não atende este horário, fica quieto',
  Number((await um(`select count(*) n from public.push_fila f join public.push_aparelhos a on a.id = f.aparelho_id
    where a.perfil_id = $1`, [BIA])).n) === 0);
await banco.query(`delete from public.push_aparelhos where perfil_id = $1`, [BIA]);
e('o aviso entrou na fila do aparelho da dona', fila.length === 1, JSON.stringify(fila));
e('dizendo quem e quando — ' + JSON.stringify(fila[0] && fila[0].corpo),
  fila[0] && fila[0].titulo === 'Horário novo pelo link'
  && fila[0].corpo === 'Maria Souza · ' + dia.slice(8) + '/' + dia.slice(5, 7) + ' às 14:00 · com Ju');
e('e nenhuma mensagem de WhatsApp foi gasta por isso',
  Number((await um(`select count(*) n from public.notificacoes where salao_id = $1 and corpo like 'Horário novo pelo link%'`, [SALAO])).n) === 0);

/* ═══════════════════════════════════ 4 ══ */
secao('4. O worker entrega, e o "celular" decifra');
/* O MESMO código da função de borda (webpush.js); só o POST para o Google é
   desviado para cá, porque o sandbox não sai para a internet. */
const recebidos = [];
const fetchDeVerdade = globalThis.fetch;
globalThis.fetch = async (url, op) => {
  if(String(url).startsWith('https://push.teste.agendapro/')){
    recebidos.push({ url: String(url), headers: op.headers, corpo: new Uint8Array(op.body) });
    return new Response(null, { status: 201 });
  }
  return fetchDeVerdade(url, op);
};
const lote = await todos(`select * from public.push_proxima(10)`);
for(const a of lote){
  const r = await enviar(CHAVES, a, { titulo: a.titulo, corpo: a.corpo, url: a.url, tag: 'agendapro-' + a.id });
  await banco.query(`select public.push_resultado($1, $2, $3)`, [a.id, r.ok, r.ok ? null : r.codigo]);
}
globalThis.fetch = fetchDeVerdade;
e('um POST para o endereço do aparelho', recebidos.length === 1 && recebidos[0].url === CEL.endpoint);
// A decifragem do RFC 8291, com a chave privada que só o "celular" tem.
async function decifrar(corpo){
  const te = new TextEncoder();
  const hkdf = async (salt, ikm, info, bits) => new Uint8Array(await crypto.subtle.deriveBits(
    { name:'HKDF', hash:'SHA-256', salt, info }, await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']), bits));
  const salt = corpo.slice(0, 16), asPub = corpo.slice(21, 86), cif = corpo.slice(86);
  const seg = new Uint8Array(await crypto.subtle.deriveBits({ name:'ECDH',
    public: await crypto.subtle.importKey('raw', asPub, { name:'ECDH', namedCurve:'P-256' }, false, []) },
    parCel.privateKey, 256));
  const ikm = await hkdf(Buffer.from(CEL.auth, 'base64url'), seg,
    Buffer.concat([te.encode('WebPush: info\0'), Buffer.from(CEL.p256dh, 'base64url'), asPub]), 256);
  const cek = await hkdf(salt, ikm, te.encode('Content-Encoding: aes128gcm\0'), 128);
  const nonce = await hkdf(salt, ikm, te.encode('Content-Encoding: nonce\0'), 96);
  const claro = new Uint8Array(await crypto.subtle.decrypt({ name:'AES-GCM', iv: nonce },
    await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['decrypt']), cif));
  return JSON.parse(new TextDecoder().decode(claro.slice(0, -1)));
}
const recado = await decifrar(recebidos[0].corpo);
e('o "celular" decifra: ' + recado.titulo + ' — ' + recado.corpo,
  recado.titulo === 'Horário novo pelo link' && /Maria Souza · .* às 14:00 · com Ju/.test(recado.corpo));
e('e o aviso abre na agenda', recado.url === './app.html#agenda');
e('a fila anota como enviado',
  (await um(`select status from public.push_fila where id = $1`, [lote[0].id])).status === 'enviado');

/* ═══════════════════════════════════ 5 ══ */
secao('5. O service worker mostra o aviso, e o toque abre a agenda');
{
  const ouvintes = {}, mostrados = [], abertos = [];
  const self = {
    addEventListener: (n, f) => { ouvintes[n] = f; }, skipWaiting(){},
    registration: { scope: 'https://agendaprogestao.com.br/',
      showNotification: async (t, o) => { mostrados.push({ t, o }); } },
    clients: { matchAll: async () => [], openWindow: async u => { abertos.push(u); } },
  };
  new Function('self', 'caches', 'fetch', fs.readFileSync(RAIZ + '/sw.js', 'utf8'))(self, {}, fetch);
  let espera;
  ouvintes.push({ data: { json: () => recado }, waitUntil: x => { espera = x; } });
  await espera;
  e('o aviso aparece com o título e a linha do recado',
    mostrados.length === 1 && mostrados[0].t === recado.titulo && mostrados[0].o.body === recado.corpo);
  e('com o ícone do AgendaPro', mostrados[0].o.icon === './icones/icone-192.png');
  ouvintes.push({ data: { json: () => { throw new Error('ilegível'); } }, waitUntil: x => { espera = x; } });
  await espera;
  e('recado ilegível ainda mostra um aviso (push mudo faz o Chrome reclamar)',
    mostrados.length === 2 && mostrados[1].t === 'AgendaPro');
  ouvintes.push({ data: { json: () => ({ titulo: 'X', url: 'https://golpe.exemplo/' }) }, waitUntil: x => { espera = x; } });
  await espera;
  e('endereço de fora do site é trocado pelo painel', mostrados[2].o.data.url === './app.html');
  let fechou = false;
  ouvintes.notificationclick({ notification: { data: { url: './app.html#agenda' }, close(){ fechou = true; } },
    waitUntil: x => { espera = x; } });
  await espera;
  e('tocar no aviso fecha e abre a agenda', fechou && abertos[0] === 'https://agendaprogestao.com.br/app.html#agenda',
    JSON.stringify(abertos));
}

/* ═══════════════════════════════════ 6 ══ */
secao('6. Teste e desligar');
await p.click('#modalPe button:has-text("Mandar um aviso de teste")');
await p.waitForTimeout(1500);
e('o teste entrou na fila do aparelho dela',
  Number((await um(`select count(*) n from public.push_fila f join public.push_aparelhos a on a.id = f.aparelho_id
    where a.salao_id = $1 and f.titulo = 'Aviso de teste'`, [SALAO])).n) === 1);
e('e a janela diz em quanto tempo chega', /30 segundos/.test(await textoDoModal(p)));
await p.click('#modalPe button:has-text("Desligar neste aparelho")');
await p.waitForTimeout(1500);
e('desligar tira o aparelho do banco',
  Number((await um(`select count(*) n from public.push_aparelhos where salao_id = $1`, [SALAO])).n) === 0);
e('e cancela a inscrição do navegador', await p.evaluate(() => window.__desinscreveu === true));
e('a janela volta a oferecer Ligar', (await botoesDoModal(p)).includes('Ligar avisos neste aparelho'));

/* ═══════════════════════════════════ 7 ══ */
secao('7. Os caminhos tortos');
{
  const negado = await abrir(dona.sessao(), { permissao: 'denied' });
  await negado.evaluate(() => abrirAvisosCelular());
  await negado.waitForTimeout(1200);
  const t = await textoDoModal(negado);
  e('permissão bloqueada: explica como liberar', /bloqueados/.test(t) && /Permitir/.test(t), t.slice(0, 120));
  e('e não oferece um Ligar que não vai funcionar', !(await botoesDoModal(negado)).includes('Ligar avisos neste aparelho'));
}
{
  const iphone = await abrir(dona.sessao(), { ctx: { userAgent:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1' } });
  await iphone.evaluate(() => abrirAvisosCelular());
  await iphone.waitForTimeout(600);
  const t = await textoDoModal(iphone);
  e('iPhone sem o app instalado: ensina a instalar', /Adicionar à Tela de Início/.test(t), t.slice(0, 120));
}
{
  const r = await abrir(rec.sessao());
  const ve = await r.evaluate(() => document.querySelectorAll('#abas .aba[data-chave="salao"]').length);
  e('a recepção não vê Meu negócio', ve === 0);
  await r.evaluate(() => { sinoDados = sinoDados || { itens: [], avisos: [], salao: salaoAtual }; });
  await r.click('#btSino').catch(() => {});
  await r.waitForTimeout(800);
  e('mas o sino dela tem "Avisos no celular"',
    await r.evaluate(() => !!document.getElementById('sinoAvisosCelular')));
  await r.click('#sinoAvisosCelular').catch(() => {});
  await r.waitForTimeout(1000);
  await r.click('#modalPe button:has-text("Ligar avisos neste aparelho")').catch(() => {});
  await r.waitForTimeout(2000);
  const dela = await um(`select a.perfil_id from public.push_aparelhos a where a.salao_id = $1`, [SALAO]);
  e('e liga no aparelho DELA', dela && dela.perfil_id === recId, JSON.stringify(dela));
}

e('nenhum erro de JavaScript', erros.length === 0, erros.slice(0, 3).join(' | '));

// O salão de teste sai, com a agenda (o item do serviço antes do serviço).
await banco.query(`delete from public.agendamento_servicos where agendamento_id in
  (select id from public.agendamentos where salao_id = $1)`, [SALAO]).catch(() => {});
await banco.query(`delete from public.saloes where id = $1`, [SALAO]).catch(() => {});
await banco.query(`delete from public.perfis where id = $1`, [BIA]).catch(() => {});
await banco.end();
await nav.close();
console.log(`\n${ok} passaram, ${ruim} falharam`);
process.exit(ruim ? 1 : 0);

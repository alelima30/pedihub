/* ===========================================================================
   PediHub — o Pix online, do "Conectar" ao pedido PAGO (81_pix_online)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/pix-online-tela.test.mjs

   A bancada tem um Mercado Pago de mentira (tests/bancada/postgrest.mjs), e a
   lógica que roda aqui é o MESMO supabase/functions/_mp/pix.js que vai para o
   ar. Na Hamburgueria do Leo:
     1. o dono toca em "Conectar Mercado Pago", passa pela tela "Autorizar" e
        volta ao painel com "conectado"; o banco guarda a conta, e o Pix
        online já fica ligado;
     2. no link, "Pix online · pague agora" é a primeira opção; o pedido
        abre o QR e o copia-e-cola, com o tempo que falta;
     3. enquanto não paga, o pedido NÃO aparece na tela de Pedidos;
     4. o Pix cai (o aviso do Mercado Pago chega): a tela da cliente vira
        "Recebido · ✓ Pago pelo Pix" sozinha, e o painel mostra "PAGO";
     5. 30 minutos sem pagar: cancelado, dizendo o porquê;
     6. desconectar tira o Pix online do link.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import pg from './pg.mjs';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const igual = (m, a, b) => JSON.stringify(a) === JSON.stringify(b) ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (m, c, d) => c ? ok(m) : nao(m, d || 'esperava verdadeiro');
const secao = t => console.log('\n' + t);
const limpo = t => String(t || '').replace(/\s+/g, ' ').trim();
const foto = async (pg, nome) => { if(process.env.FOTOS){ await pg.waitForTimeout(600); await pg.screenshot({ path: path.join(process.env.FOTOS, nome + '.png') }); } };

function aba(){
  const g = {};
  const j = { PEDIHUB:{ url:BASE, chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: Number(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
const um = async (sql, args) => (await banco.query(sql, args)).rows[0];

const m = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dono = aba();
await dono.criarConta({ email:`leo-${m}@teste.com`, senha:'minhasenhaboa', nome:'Leo',
  telefone:'+5511' + (970000000 + (Date.now() % 20000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Hamburgueria do Leo ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3256', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Tudo', preco:35, custo:0, estoque:0, ativo:true, vendaOnline:true });
await dono.inserir('produtos', { salaoId, nome:'Refri lata', preco:6, custo:0, estoque:0, ativo:true, vendaOnline:true });
const prod = (await um(`select id from public.produtos where salao_id = $1 and nome = 'X-Tudo'`, [salaoId])).id;

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctxP = await nav.newContext({ viewport:{ width:1280, height:1000 } });
const pd = await ctxP.newPage();
pd.on('pageerror', e => erros.push('painel: ' + e.message));
const alertas = [];
pd.on('dialog', d => { alertas.push(d.message()); d.accept(); });
await pd.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html') && !localStorage.getItem('pedihub.sessao'))
    localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
const abrirPainel = async () => {
  await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 2,
    null, { timeout: 20000 });
  await pd.waitForTimeout(800);
  await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); });
};
await pd.goto(BASE + '/app.html');
await abrirPainel();

/* ══════════════════════════════════════════════════════════════════════════ */
secao('1. O dono conecta o Mercado Pago');
await pd.evaluate(() => { irPara('pedidos'); abrirConfigPedidos(); });
await pd.waitForSelector('#btConectarMp', { timeout: 10000 });
verdade('sem conectar, a janela explica e oferece "Conectar Mercado Pago"',
  /Conecte a conta do Mercado Pago/.test(limpo(await pd.textContent('#pcMpEstado'))));
await foto(pd, 'pix-0-conectar');
await Promise.all([pd.waitForURL(/app\.html/, { timeout: 15000 }), pd.click('#btConectarMp')]);
await abrirPainel();
await pd.waitForTimeout(1500);
verdade('volta ao painel com "✓ Mercado Pago conectado!"', alertas.some(a => /Mercado Pago conectado/.test(a)), JSON.stringify(alertas));
verdade('e o endereço fica limpo (sem ?mp=)', !/mp=/.test(pd.url()), pd.url());
const conta = await um(`select mp_user_id, access_token, (select cfg->'pedidos'->>'pixOnline' from public.saloes where id = $1) as pix
  from public.mp_contas where salao_id = $1`, [salaoId]);
verdade('o banco guardou a conta do Mercado Pago e ligou o Pix online',
  conta && conta.mp_user_id === '123456789' && /^APP_USR-falso-/.test(conta.access_token) && conta.pix === 'true', JSON.stringify(conta));
await pd.evaluate(() => { location.reload(); });
await abrirPainel();
await pd.evaluate(() => { irPara('pedidos'); abrirConfigPedidos(); });
await pd.waitForSelector('#pcPixOnline', { timeout: 10000 });
const st = limpo(await pd.textContent('#pcMpEstado'));
verdade('a janela mostra "✓ Mercado Pago conectado (conta final 6789)" e a opção ligada',
  /Mercado Pago conectado \(conta final 6789\)/.test(st) && await pd.$eval('#pcPixOnline', x => x.checked), st);
verdade('e nenhuma credencial aparece na tela', !/APP_USR|TG-/.test(await pd.content()));
await pd.evaluate(() => fecharModal());

/* ══════════════════════════════════════════════════════════════════════════ */
secao('2. No link: o Pix online e o QR');
const ctxC = await nav.newContext({ viewport:{ width:412, height:915 }, isMobile:true, hasTouch:true });
const c = await ctxC.newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForTimeout(2500);
await c.click('#btPrincipal');
await c.waitForTimeout(400);
await c.evaluate(id => mudarNoCarrinho(id, 1), prod);
await c.click('#btPrincipal');
await c.waitForTimeout(500);
const opcoes = await c.$$eval('.pd-op', e => e.map(x => x.textContent.replace(/\s+/g, ' ').trim()));
verdade('"Pix online · pague agora" aparece entre as formas de pagamento', opcoes.includes('Pix online · pague agora'), JSON.stringify(opcoes));
await c.click('.pd-op:has-text("Retirar no local")');
await c.fill('#pdNome', 'Paula Dias');
await c.fill('#pdTel', '11972220011');
await c.click('.pd-op:has-text("Pix online")');
verdade('escolhido, ele explica: "aparece o Pix para pagar"', /aparece o Pix para pagar/.test(await c.textContent('#pedidoCorpo')));
await c.click('#btPrincipal');
await c.waitForSelector('#pixCaixa .pix-codigo', { timeout: 15000 });
const caixa = await c.evaluate(() => {
  const x = document.getElementById('pixCaixa');
  return { texto: x.innerText.replace(/\s+/g, ' '), img: !!x.querySelector('.pix-qr img'),
           codigo: x.querySelector('.pix-codigo').textContent };
});
verdade('aparece "Pague o Pix", com o valor e a imagem do QR', /Pague o Pix/.test(caixa.texto) && /R\$ 35,00/.test(caixa.texto) && caixa.img, caixa.texto);
verdade('o copia-e-cola do Mercado Pago', /^00020126/.test(caixa.codigo), caixa.codigo);
verdade('e o tempo que falta (29 minutos e pouco)', /vence em 29:\d\d|vence em 30:00/.test(caixa.texto), caixa.texto);
const token = await c.evaluate(() => pedidoAcomp.token);
await foto(c, 'pix-1-qr');

secao('3. Enquanto não paga, a cozinha não vê');
const lista0 = await dono.chamar('pedidos_da_loja', { p_salao: salaoId });
igual('a tela de Pedidos continua vazia', lista0.length, 0);
igual('e o banco guarda o pedido esperando o Pix', (await um(`select status from public.pedidos where token = $1`, [token])).status, 'aguardando_pagamento');

secao('4. O Pix cai');
const pagou = await fetch(BASE + '/mp-falso/pagar', { method:'POST', headers:{ 'Content-Type':'application/json' },
  body: JSON.stringify({ token }) }).then(r => r.json());
verdade('o Mercado Pago (de mentira) aprova e manda o aviso', pagou.ok === true, JSON.stringify(pagou));
await c.waitForFunction(() => document.querySelector('.pd-etapas') && /Pago pelo Pix/.test(document.getElementById('acompanharCorpo').innerText),
  null, { timeout: 15000 });
const depois = limpo(await c.textContent('#acompanharCorpo'));
verdade('a tela da cliente vira sozinha "Recebido · ✓ Pago pelo Pix"', /Recebido/.test(depois) && /Pago pelo Pix/.test(depois), depois);
await foto(c, 'pix-2-pago');
const lista1 = await dono.chamar('pedidos_da_loja', { p_salao: salaoId });
igual('o pedido chega na tela de Pedidos, pago online', lista1.map(x => [x.status, x.pagoOnline]), [['recebido', true]]);
await pd.evaluate(() => { irPara('pedidos'); carregarPedidos(); });
await pd.waitForFunction(() => /PAGO · Pix online/.test(document.body.innerText), null, { timeout: 10000 }).catch(() => {});
verdade('e o painel mostra "✓ PAGO · Pix online" no cartão', /PAGO · Pix online/.test(await pd.evaluate(() => document.body.innerText)));
await foto(pd, 'pix-3-painel');

secao('5. Trinta minutos sem pagar');
const cliente = aba();
const r2 = await cliente.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome:'Rafa', telefone:'11972220022',
  entrega:'retirada', pagamento:'pix_online', itens:[{ produto: prod, quantidade: 1 }] } });
igual('o pedido nasce esperando o Pix', r2.status, 'aguardando_pagamento');
await banco.query(`update public.pedidos set pix_expira_em = now() - interval '1 minute' where token = $1`, [r2.token]);
await c.evaluate(t => abrirAcompanhar(t), r2.token);
await c.waitForFunction(() => /cancelado/i.test(document.getElementById('acompanharCorpo').innerText), null, { timeout: 15000 });
verdade('a tela diz que foi cancelado porque o Pix não foi pago',
  /o Pix não foi pago em 30 minutos/.test(limpo(await c.textContent('#acompanharCorpo'))), limpo(await c.textContent('#acompanharCorpo')));

secao('6. Desconectar');
await pd.evaluate(() => { irPara('pedidos'); abrirConfigPedidos(); });
await pd.waitForSelector('#pcPixOnline', { timeout: 10000 });
await pd.click('#pcMpEstado button:has-text("Desconectar")');
await pd.waitForSelector('#btConectarMp', { timeout: 10000 });
igual('o banco esqueceu a conta', (await um(`select count(*)::int n from public.mp_contas where salao_id = $1`, [salaoId])).n, 0);
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForTimeout(2500);
await c.evaluate(id => { mudarNoCarrinho(id, 1); irPara('pedido'); }, prod);
await c.waitForTimeout(600);
verdade('e o link para de oferecer o Pix online',
  !(await c.$$eval('.pd-op', e => e.map(x => x.textContent))).some(t => /Pix online/.test(t)));
igual('a 412px nada vaza para o lado', await c.evaluate(() => document.documentElement.scrollWidth - innerWidth), 0);

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

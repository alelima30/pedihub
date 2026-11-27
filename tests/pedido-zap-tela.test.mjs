/* ===========================================================================
   PediHub — avisar o cliente pelo WhatsApp da lanchonete, com o link do pedido

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/pedido-zap-tela.test.mjs

   "Depois que a lanchonete confirma, aparecer no pedido uma moldura para
   enviar no WhatsApp todos os dados do pedido e o link Acompanhar pedido. E
   se o cliente não tiver cadastro, ele consegue ver o pedido?"
     1. pedido novo: ainda sem a moldura (só depois de aceitar);
     2. aceito: aparece "Avise o cliente no WhatsApp", com o botão que abre o
        WhatsApp do cliente;
     3. a mensagem leva tudo: itens, total, pagamento com a chave Pix,
        entrega, previsão e o link "Acompanhe seu pedido";
     4. o link abre o pedido num celular que nunca pediu nada, sem conta, e o
        guarda em "Meus pedidos";
     5. tocado o botão, a moldura vira "✓ Enviado no WhatsApp".
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

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

const m = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dono = aba();
await dono.criarConta({ email:`zap-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono do Zap',
  telefone:'+5511' + (980000000 + (Date.now() % 10000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Zap ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3310', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Tudo', preco:35, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria:'Lanches' });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3310',
  cfg:{ pagamentos:{ formas:['pix', 'dinheiro'], pix:'pix@lanchonete.com' },
        pedidos:{ tempo:'40 min', pagamentos:['pix', 'dinheiro'] } } });
const xId = (await dono.lista('produtos', { salaoId }))[0].id;
const cli = aba();
const ped = await cli.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome:'Joana Lima', telefone:'11977002002',
  entrega:'entrega', pagamento:'pix', observacao:'sem cebola',
  endereco:{ rua:'Rua das Flores', numero:'45', bairro:'Centro' }, itens:[{ produto: xId, quantidade: 2 }] } });

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const p = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
p.on('pageerror', e => erros.push('painel: ' + e.message));
p.on('dialog', x => x.accept());
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await p.goto(BASE + '/app.html');
await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 1, null, { timeout: 20000 });
await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); window.tocarSomDePedido = () => {}; irPara('pedidos'); });
await p.waitForTimeout(500);
await p.evaluate(() => carregarPedidos());
await p.waitForSelector('.pedido-cartao');

secao('1. Pedido novo: ainda sem a moldura');
igual('sem "Avise o cliente" antes de aceitar', await p.$$eval('.pedido-cartao .pd-zap', e => e.length), 0);

secao('2. Aceito: aparece "Avise o cliente no WhatsApp"');
const id = await p.evaluate(() => pedidosLista[0].id);
await p.evaluate(i => mudarPedido(i, 'em_preparo'), id);
await p.waitForSelector('.pd-zap a.pd-zap-b', { timeout: 8000 });
verdade('a moldura com o botão', /Avise o cliente no WhatsApp/.test(limpo(await p.textContent('.pd-zap'))));
await p.waitForTimeout(1200);   // o código do pedido chega do banco
if(process.env.SAIDA){
  await p.evaluate(() => document.querySelector('.pedido-cartao').scrollIntoView({ block: 'start' }));
  await p.waitForTimeout(300);
  await (await p.$('.pedido-cartao')).screenshot({ path: process.env.SAIDA + '/pedido-zap.png' });
}
const href = await p.getAttribute('.pd-zap a.pd-zap-b', 'href');
verdade('o botão abre o WhatsApp do cliente (com o 55)', href.startsWith('https://wa.me/5511977002002?text='), href.slice(0, 60));

secao('3. A mensagem leva tudo');
const msg = decodeURIComponent(href.split('?text=')[1]);
verdade('o primeiro nome e a confirmação', /Olá, Joana!/.test(msg) && /confirmou o seu pedido \*#\d+\*/.test(msg), msg.slice(0, 120));
verdade('os itens, com a observação do item ou do pedido', /2x X-Tudo — R\$\s*70,00/.test(msg) && /Obs\.: sem cebola/.test(msg), msg);
verdade('o total', /\*Total: R\$\s*70,00\*/.test(msg), msg);
verdade('o pagamento, com a chave Pix', /Pagamento: Pix/.test(msg) && /Chave Pix: pix@lanchonete\.com/.test(msg), msg);
verdade('a entrega', /Entrega: Rua das Flores, 45/.test(msg), msg);
verdade('a previsão, com a hora', /Previsão: 40 min \(por volta das \d\d:\d\d\)/.test(msg), msg);
const link = (msg.match(/https?:\/\/\S+&pedido=[0-9a-f-]{36}/) || [])[0];
verdade('e o link "Acompanhe seu pedido"', /Acompanhe seu pedido/.test(msg) && !!link, msg.slice(-200));

secao('4. O link abre o pedido em outro celular, sem conta');
const c = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(link.replace(/^https?:\/\/[^/]+/, BASE));
await c.waitForFunction(() => typeof tela !== 'undefined' && tela === 'acompanhar', null, { timeout: 15000 }).catch(() => {});
igual('abre direto no acompanhamento', await c.evaluate(() => tela), 'acompanhar');
await c.waitForTimeout(1500);
verdade('com o pedido dela', /Em preparo|em preparo|Preparando/i.test(limpo(await c.textContent('#p-acompanhar'))),
  limpo(await c.textContent('#p-acompanhar')).slice(0, 160));
igual('e guarda em "Meus pedidos" deste celular', await c.evaluate(() => meusPedidosGuardados().length), 1);
igual('com o número do pedido', await c.evaluate(() => meusPedidosGuardados()[0].numero), ped.numero);

secao('5. Tocado o botão, vira "Enviado"');
await p.evaluate(() => { const a = document.querySelector('.pd-zap a.pd-zap-b'); a.removeAttribute('target');
  a.addEventListener('click', e => e.preventDefault()); a.click(); });
await p.waitForTimeout(1200);
verdade('"✓ Enviado no WhatsApp", com "Enviar de novo"',
  /Enviado no WhatsApp/.test(limpo(await p.textContent('.pd-zap'))) && !!(await p.$('.pd-zap a.pd-zap-de-novo')));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

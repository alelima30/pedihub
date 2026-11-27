/* ===========================================================================
   PediHub — o alarme do pedido novo para quando alguém aceita

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/alarme-pedido-tela.test.mjs

   "Eu já vi o pedido e confirmei e continua fazendo barulho." Enquanto houver
   pedido em "Novos", o painel toca a cada 6 segundos. Com o painel aberto em
   DOIS aparelhos (o celular do dono e o computador do balcão):
     1. o pedido chega e os dois tocam;
     2. aceito no aparelho A, o A para NA HORA;
     3. o aparelho B para sozinho em poucos segundos (não espera a volta de
        20 s da lista, nem toca para sempre);
     4. aceito com a internet falhando na volta da lista, o A para do mesmo
        jeito (o aceite deu certo; a lista é que não voltou);
     5. pedido esperando e a internet cai: o alarme continua (não fica mudo);
        cancelado, para.
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
const espera = ms => new Promise(r => setTimeout(r, ms));

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
await dono.criarConta({ email:`alarme-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono do Alarme',
  telefone:'+5511' + (950000000 + (Date.now() % 30000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Alarme ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3290', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Egg', preco:24, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria:'Lanches' });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3290' });
const xId = (await dono.lista('produtos', { salaoId }))[0].id;
const cli = aba();
const pedir = (nome, tel) => cli.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome, telefone: tel,
  entrega:'retirada', pagamento:'dinheiro', itens:[{ produto: xId, quantidade: 1 }] } });

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
async function painel(nomeAparelho){
  const p = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
  p.on('pageerror', e => erros.push(nomeAparelho + ': ' + e.message));
  p.on('dialog', x => x.accept());
  await p.addInitScript(([b, s]) => {
    window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
    if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
  }, [BASE, dono.sessao()]);
  await p.goto(BASE + '/app.html');
  await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 1, null, { timeout: 20000 });
  await p.evaluate(() => {
    if(typeof pdFechar === 'function') pdFechar(true);
    // Conta cada toque do som, em vez de tocar de verdade.
    window.toques = 0;
    window.tocarSomDePedido = () => { window.toques++; };
    irPara('pedidos');
  });
  await p.waitForTimeout(800);
  await p.evaluate(() => carregarPedidos());
  return p;
}
const toques = p => p.evaluate(() => window.toques);
const tocando = p => p.evaluate(() => alarmeRelogio !== null);

const A = await painel('aparelho A');
const B = await painel('aparelho B');

secao('1. Chega o pedido: os dois aparelhos tocam');
const p1 = await pedir('Rita', '11977001001');
await A.evaluate(() => carregarPedidos());
await B.evaluate(() => carregarPedidos());
await espera(500);
verdade('A tocou', (await toques(A)) >= 1);
verdade('B tocou', (await toques(B)) >= 1);
igual('e os dois ficam no alarme', [await tocando(A), await tocando(B)], [true, true]);

secao('2. Aceito no aparelho A: o A para na hora');
const idP1 = await A.evaluate(() => (pedidosLista || []).find(p => p.status === 'recebido').id);
await A.evaluate(id => mudarPedido(id, 'em_preparo'), idP1);
await espera(1500);
igual('o alarme do A desligou', await tocando(A), false);
const a0 = await toques(A);
await espera(7000);
igual('e o A não toca mais', await toques(A), a0);

secao('3. O aparelho B para sozinho, em poucos segundos');
await espera(2000);
const b0 = await toques(B);
await espera(7000);
igual('o B não toca mais (sem esperar a volta de 20 s da lista)', await toques(B), b0);
igual('e o alarme do B desligou', await tocando(B), false);

secao('4. Aceito com a lista falhando na volta: o A para do mesmo jeito');
const p2 = await pedir('Beto', '11977001002');
await A.evaluate(() => carregarPedidos());
await espera(500);
igual('o pedido novo liga o alarme', await tocando(A), true);
const idP2 = await A.evaluate(() => (pedidosLista || []).find(p => p.status === 'recebido').id);
// A internet cai DEPOIS do aceite: a lista não volta.
await A.route(/rpc\/pedidos_da_loja/, r => r.fulfill({ status: 503, contentType: 'application/json',
  body: JSON.stringify({ message: 'sem internet' }) }));
await A.evaluate(id => mudarPedido(id, 'em_preparo'), idP2);
await espera(1500);
igual('o alarme desligou mesmo sem a lista voltar', await tocando(A), false);
const a1 = await toques(A);
await espera(7000);
igual('e não toca mais', await toques(A), a1);
await A.unroute(/rpc\/pedidos_da_loja/);

secao('5. Pedido esperando e a internet cai: o alarme NÃO fica mudo');
await pedir('Caio', '11977001003');
await A.evaluate(() => carregarPedidos());
await espera(500);
igual('o pedido novo liga o alarme', await tocando(A), true);
await A.route(/rpc\/pedidos_da_loja/, r => r.fulfill({ status: 503, contentType: 'application/json',
  body: JSON.stringify({ message: 'sem internet' }) }));
const a2 = await toques(A);
await espera(13000);
verdade('sem conseguir conferir, continua tocando', (await toques(A)) >= a2 + 2, `${a2} → ${await toques(A)}`);
await A.unroute(/rpc\/pedidos_da_loja/);
const idP3 = await A.evaluate(() => (pedidosLista || []).find(p => p.status === 'recebido').id);
await A.evaluate(id => mudarPedido(id, 'cancelado'), idP3);
await espera(1500);
igual('cancelado (com o motivo), o alarme também para', await tocando(A), false);

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

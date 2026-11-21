/* ===========================================================================
   PediHub — o pedido pela mesa, de ponta a ponta (71)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/mesa-tela.test.mjs

   Uma pizzaria com 8 mesas e fidelidade ligada. O cliente lê o QR da mesa 3:
     1. o pedido abre já na "Mesa 3", sem endereço e sem taxa, com
        "Pagar na mesa, no fim" escolhido e o WhatsApp opcional;
     2. o aviso da fidelidade aparece;
     3. pede só com o nome: no BANCO o pedido é de mesa 3, paga na mesa;
     4. o QR de uma mesa que não existe (99) não vira pedido de mesa.
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
const d = aba();
await d.criarConta({ email:`mesa-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dona Nina',
  telefone:'+5511' + (950000000 + (Date.now() % 40000000)) });
const cr = await d.chamar('criar_salao', { p_nome_salao: 'Cantina ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3251', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, slug = cr[0].slug;
const pizza = (await d.inserir('produtos', { salaoId, nome:'Lasanha', preco:42, custo:0, estoque:0,
  ativo:true, vendaOnline:true })).id;
await d.atualizar('saloes', salaoId, { cfg:{ pedidos:{ mesas: 8, taxaPadrao: 6, minimo: 100,
  fidelidade:{ ligado:true, pedidos:5, desconto:10 } } } });
ok('uma cantina com 8 mesas, entrega a R$ 6, mínimo de R$ 100 e fidelidade');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
async function abrir(q){
  const ctx = await nav.newContext({ viewport:{ width:412, height:880 }, isMobile:true, hasTouch:true });
  const c = await ctx.newPage();
  c.on('pageerror', e => erros.push(e.message));
  c.on('dialog', x => x.accept());
  await c.goto(BASE + '/cardapio.html?salao=' + slug + q);
  await c.waitForFunction(() => typeof salao !== 'undefined' && salao && typeof pedidosCasa !== 'undefined'
    && pedidosCasa && pedidosCasa.mesas, null, { timeout: 15000 });
  await c.waitForTimeout(600);
  return c;
}

secao('1. O QR da mesa 3');
const c = await abrir('&mesa=3');
await c.evaluate(id => mudarNoCarrinho(id, 1), pizza);
await c.evaluate(() => irPara('pedido'));
await c.waitForTimeout(500);
igual('o pedido nasce na mesa 3, pagando na mesa', await c.evaluate(() => [formDoPedido().entrega, formDoPedido().pagamento, mesaDoLink()]),
  ['mesa', 'na_mesa', '3']);
igual('a única forma de receber é "Mesa 3"', await c.evaluate(() => [...document.querySelectorAll('.pd-ops')[0].querySelectorAll('.pd-op')].map(x => x.textContent.trim())), ['Mesa 3']);
verdade('sem campo de endereço e sem taxa', await c.evaluate(() => !document.getElementById('pdRua') && taxaDoPedido() === 0));
verdade('o WhatsApp é opcional na mesa', /opcional na mesa/.test(await c.textContent('label[for="pdTel"]')));

secao('2. A fidelidade');
verdade('o aviso da fidelidade aparece', /a cada 5 pedidos/.test(await c.textContent('#pedidoCorpo')));

secao('3. Pedir só com o nome (o mínimo de R$ 100 não vale na mesa)');
await c.evaluate(() => anotarPedido('nome', 'Mesa do Rui'));
await c.evaluate(() => confirmarPedido());
await c.waitForTimeout(1500);
const ped = await um(`select tipo_entrega, mesa, pagamento, taxa_entrega::text taxa, total::text total, telefone
                        from public.pedidos where salao_id = $1`, [salaoId]);
verdade('o pedido foi gravado', !!ped, 'nada no banco');
if(ped) igual('mesa 3, paga na mesa, sem taxa, sem telefone, R$ 42',
  [ped.tipo_entrega, ped.mesa, ped.pagamento, ped.taxa, ped.total, ped.telefone], ['mesa', '3', 'na_mesa', '0.00', '42.00', '']);

secao('4. Mesa que não existe');
const c2 = await abrir('&mesa=99');
igual('a mesa 99 não vale: o link é o de sempre', await c2.evaluate(() => mesaDoLink()), null);

igual('nenhum erro de JavaScript', erros, []);
await nav.close(); await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

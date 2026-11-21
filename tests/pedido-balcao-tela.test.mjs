/* ===========================================================================
   PediHub — "+ Novo pedido" no painel, de ponta a ponta (70_pedido_balcao)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/pedido-balcao-tela.test.mjs

   A dona de uma lanchonete recebe um pedido por telefone:
     1. abre "+ Novo pedido", busca e escolhe o X-Burger — com o adicional
        Bacon — e um refrigerante;
     2. põe para entrega, escolhe o bairro e a taxa vem sozinha;
     3. lança: no BANCO o pedido é de telefone, em preparo, com o total
        certo; e ele aparece na lista com a etiqueta "telefone".
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
await d.criarConta({ email:`balcao-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dona Bia',
  telefone:'+5511' + (940000000 + (Date.now() % 50000000)) });
const cr = await d.chamar('criar_salao', { p_nome_salao: 'Lanchonete ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3251', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
const burger = (await d.inserir('produtos', { salaoId, nome:'X-Burger', preco:20, custo:0, estoque:0,
  ativo:true, vendaOnline:true })).id;
await d.inserir('produtos', { salaoId, nome:'Refrigerante lata', preco:6, custo:0, estoque:0,
  ativo:true, vendaOnline:true });
await d.chamar('salvar_opcoes_do_produto', { p_produto: burger, p_grupos: [
  { nome:'Adicionais', min:0, max:3, regra:'soma', opcoes:[{ nome:'Bacon', preco:'4' }, { nome:'Ovo', preco:'2' }] }] });
await d.atualizar('saloes', salaoId, { cfg:{ pedidos:{ taxas:[{ bairro:'Centro', taxa:5 }, { bairro:'Vila Nova', taxa:8 }] } } });
ok('uma lanchonete com X-Burger (adicionais), refrigerante e taxa por bairro');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctx = await nav.newContext({ viewport:{ width:1280, height:1000 } });
const p = await ctx.newPage();
p.on('pageerror', e => erros.push(e.message));
const alertas = [];
p.on('dialog', x => { alertas.push(x.message()); x.accept(); });
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await p.goto(BASE + '/app.html');
await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos)
  && bd.produtos.length >= 2, null, { timeout: 20000 });
await p.waitForTimeout(800);

secao('1. Escolher os itens');
await p.click('text=+ Novo pedido');
await p.waitForSelector('#npCardapio');
await p.fill('#npNome', 'Carlos');
await p.fill('#npTel', '(11) 97000-0030');
await p.fill('#npBusca', 'burg');
igual('a busca acha só o X-Burger', await p.$$eval('#npCardapio .np-prod', e =>
  e.filter(x => x.style.display !== 'none').map(x => x.querySelector('span').textContent)), ['X-Burger']);
await p.click('#npCardapio .np-prod:has-text("X-Burger")');
await p.waitForSelector('.np-escolha');
await p.click('.np-escolha button:has-text("Bacon")');
await p.click('.np-escolha button:has-text("Pôr no pedido")');
await p.fill('#npBusca', '');
await p.click('#npCardapio .np-prod:has-text("Refrigerante")');
await p.waitForTimeout(400);
igual('a lista: X-Burger com bacon (24) e o refri (6)', await p.$$eval('.np-linha', e => e.map(x => x.textContent.replace(/\s+/g, ' ').trim())),
  ['X-Burger — Adicionais: Bacon −1 + R$ 24,00', 'Refrigerante lata −1 + R$ 6,00']);

secao('2. Entrega com a taxa do bairro');
await p.check('input[name="npModo"][value="entrega"]');
await p.fill('#npRua', 'Rua B'); await p.fill('#npNum', '20');
await p.fill('#npBairro', 'Vila Nova');
await p.waitForTimeout(200);
igual('a taxa da Vila Nova (8) veio sozinha', await p.inputValue('#npTaxa'), '8');
igual('o total: 30 + 8 = R$ 38,00', limpo(await p.textContent('#npTotal span')), 'Total R$ 38,00');

secao('3. Lançar');
await p.click('.modal .btn-p:has-text("Lançar pedido")');
await p.waitForTimeout(2000);
const ped = await um(`select origem, status, total::text, taxa_entrega::text taxa, bairro,
  (select string_agg(i.nome, ' ; ' order by i.ordem) from public.pedido_itens i where i.pedido_id = p.id) itens
  from public.pedidos p where p.salao_id = $1`, [salaoId]);
verdade('o pedido foi gravado', !!ped, 'nada no banco; alertas: ' + alertas.join(' | '));
if(ped){
  igual('telefone, em preparo, total 38 com taxa 8 na Vila Nova',
    [ped.origem, ped.status, ped.total, ped.taxa, ped.bairro], ['telefone', 'em_preparo', '38.00', '8.00', 'Vila Nova']);
  igual('os itens com o adicional escrito', ped.itens, 'X-Burger — Adicionais: Bacon ; Refrigerante lata');
}
verdade('ele aparece na lista com a etiqueta "telefone"', await p.evaluate(() =>
  [...document.querySelectorAll('.pedido-cartao')].some(c => /telefone/.test(c.textContent) && /Carlos/.test(c.textContent))));

igual('nenhum erro de JavaScript', erros, []);
await nav.close(); await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

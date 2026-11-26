/* ===========================================================================
   PediHub — a promoção, do painel ao link (79_promocao)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/promocao-tela.test.mjs

   Na Lanchonete da Rua:
     1. o dono abre o X-Bacon (R$ 30) e põe R$ 35 na promoção: o painel recusa
        (promoção maior que o preço não é promoção); põe R$ 24,90 e grava;
     2. a lista do cardápio mostra o preço riscado e o selo; o "Lançar pedido"
        já usa o preço da promoção;
     3. no link (celular): a faixa 🔥 PROMOÇÃO logo na entrada, com o selo
        −17% e o preço cheio riscado; o + põe no carrinho a R$ 24,90;
     4. na tela do cardápio, a seção "🔥 Promoções" vem primeiro e tem só ela
        (a fileira das categorias fica presa no alto e tocar leva até a seção,
        82); a tela do item mostra o selo; nada vaza para o lado a 375px.
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
const foto = async (pg, nome) => { if(process.env.FOTOS) await pg.screenshot({ path: path.join(process.env.FOTOS, nome + '.png') }); };
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
const dono = aba();
await dono.criarConta({ email:`rua-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dona Rita',
  telefone:'+5511' + (940000000 + (Date.now() % 50000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete da Rua ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3253', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Bacon', preco:30, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Lanches', foto:'icones/icone-512.png' });
await dono.inserir('produtos', { salaoId, nome:'Suco de laranja', preco:10, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Bebidas' });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3253' });
const xId = (await um(`select id from public.produtos where salao_id = $1 and nome = 'X-Bacon'`, [salaoId])).id;

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

/* ══════════════════════════════════════════════════════════════════════════
   1 — O DONO PÕE A PROMOÇÃO
   ══════════════════════════════════════════════════════════════════════════ */
secao('1. O dono põe a promoção no X-Bacon');
const ctxP = await nav.newContext({ viewport:{ width:1280, height:1000 } });
const pd = await ctxP.newPage();
pd.on('pageerror', e => erros.push('painel: ' + e.message));
pd.alertas = [];
pd.on('dialog', x => { pd.alertas.push(x.message()); x.accept(); });
await pd.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await pd.goto(BASE + '/app.html');
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos)
  && bd.produtos.length >= 2, null, { timeout: 20000 });
await pd.waitForTimeout(800);
await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); });

await pd.evaluate(id => abrirProduto(id), xId);
await pd.waitForSelector('#pPromo');
verdade('o cadastro do item tem "Preço na promoção" e "Promoção até"',
  !!(await pd.$('#pPromo')) && !!(await pd.$('#pPromoAte')));
await pd.fill('#pPromo', '35');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(600);
verdade('promoção MAIOR que o preço: o painel recusa e explica',
  /MENOR que o preço normal/.test(pd.alertas.pop() || ''));
igual('e nada foi gravado', (await um(`select preco_promo from public.produtos where id = $1`, [xId])).preco_promo, null);

await pd.fill('#pPromo', '24.90');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(1500);
igual('R$ 24,90: gravado no banco, sem data de fim',
  Object.values(await um(`select preco_promo::text, promo_ate from public.produtos where id = $1`, [xId])), ['24.90', null]);

secao('2. No painel: a lista e o Lançar pedido');
await pd.evaluate(() => irPara('produtos'));
await pd.waitForTimeout(700);
const linha = limpo(await pd.textContent('tr:has-text("X-Bacon")'));
verdade('a lista mostra o preço cheio, o da promoção e o selo',
  /R\$\s*30,00/.test(linha) && /R\$\s*24,90/.test(linha) && /promoção/.test(linha), linha);
await pd.evaluate(() => abrirNovoPedido());
await pd.waitForSelector('#npCardapio .np-prod');
const np = limpo(await pd.textContent('#npCardapio .np-prod:has-text("X-Bacon")'));
verdade('o Lançar pedido já mostra o preço da promoção', /R\$\s*24,90/.test(np) && /promoção/.test(np), np);
await pd.click('#npCardapio .np-prod:has-text("X-Bacon")');
await pd.waitForTimeout(400);
verdade('e o item entra no pedido a R$ 24,90', /24,90/.test(limpo(await pd.textContent('#npTotal'))),
  limpo(await pd.textContent('#npTotal')));
await ctxP.close();

/* ══════════════════════════════════════════════════════════════════════════
   3 — NO LINK, NO CELULAR
   ══════════════════════════════════════════════════════════════════════════ */
secao('3. No link: a faixa de promoção na entrada');
const ctxC = await nav.newContext({ viewport:{ width:412, height:915 }, isMobile:true, hasTouch:true });
const c = await ctxC.newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForSelector('#capaPromo .promo-cartao', { timeout: 15000 });
await c.waitForTimeout(500);
const faixa = await c.evaluate(() => {
  const f = document.querySelector('#capaPromo');
  const boas = document.querySelector('#capaBoas'), loja = document.querySelector('#capaLoja');
  return {
    titulo: (f.querySelector('.promo-tit > span') || {}).textContent || '',
    cartoes: f.querySelectorAll('.promo-cartao').length,
    selo: (f.querySelector('.selo-promo') || {}).textContent || '',
    riscado: (f.querySelector('.preco-promo s') || {}).textContent || '',
    novo: (f.querySelector('.preco-promo b') || {}).textContent || '',
    // Na entrada: depois do convite e ANTES do resto do cardápio.
    ordem: !!(boas.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING)
        && !!(f.compareDocumentPosition(loja) & Node.DOCUMENT_POSITION_FOLLOWING),
  };
});
igual('a faixa "🔥 PROMOÇÃO", com o X-Bacon só', [limpo(faixa.titulo), faixa.cartoes], ['🔥 PROMOÇÃO', 1]);
igual('o selo diz PROMOÇÃO −17%', limpo(faixa.selo), 'PROMOÇÃO −17%');
verdade('o preço cheio riscado e o novo', /30,00/.test(faixa.riscado) && /24,90/.test(faixa.novo),
  faixa.riscado + ' / ' + faixa.novo);
verdade('logo na entrada: depois do convite e antes do resto do cardápio', faixa.ordem);
igual('o Suco, sem promoção, não tem selo no cardápio da capa',
  await c.evaluate(() => [...document.querySelectorAll('#capaLoja .pr-cartao')]
    .filter(x => /Suco/.test(x.textContent)).map(x => !!x.querySelector('.selo-promo'))), [false]);
await foto(c, 'promo-1-capa');
await c.click('#capaPromo .promo-cartao .pr-add');
await c.waitForTimeout(400);
igual('o + da faixa põe no carrinho a R$ 24,90', await c.evaluate(() => totalDoCarrinho()), 24.9);

secao('4. No cardápio e na tela do item');
await c.evaluate(() => irPara('loja'));
await c.waitForTimeout(600);
const chips = await c.$$eval('#lojaCats .loja-cat', e => e.map(x => x.textContent.replace(/\s+/g, ' ').trim()));
verdade('a categoria "🔥 Promoções" vem logo depois de "Todos"', chips[0] === 'Todos' && chips[1] === '🔥 Promoções',
  JSON.stringify(chips));
await c.click('#lojaCats .loja-cat:has-text("Promoções")');
await c.waitForTimeout(1200);
const so = await c.evaluate(() => (document.querySelector('#listaProdutos .loja-secao[data-k="__promo"]') || {}).innerText || '');
verdade('a seção 🔥 Promoções tem só o X-Bacon', /X-Bacon/.test(so) && !/Suco/.test(so), so.slice(0, 200));
igual('e tocar nela a deixa marcada na fileira', limpo(await c.textContent('#lojaCats .loja-cat.on')), '🔥 Promoções');
await c.evaluate(id => abrirProduto(id), xId);
await c.waitForTimeout(500);
verdade('a tela do item mostra o selo e o preço riscado',
  /PROMOÇÃO/.test(limpo(await c.textContent('#produtoAberto .prod-promo')))
  && /30,00/.test(limpo(await c.textContent('#produtoAberto .prod-preco s'))));
await ctxC.close();

const ctx375 = await nav.newContext({ viewport:{ width:375, height:812 }, isMobile:true, hasTouch:true });
const c3 = await ctx375.newPage();
c3.on('pageerror', e => erros.push('375: ' + e.message));
await c3.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c3.waitForSelector('#capaPromo .promo-cartao', { timeout: 15000 });
igual('a 375px nada vaza para o lado', await c3.evaluate(() => document.documentElement.scrollWidth - innerWidth), 0);
await ctx375.close();

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

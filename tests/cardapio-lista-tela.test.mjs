/* ===========================================================================
   PediHub — o cardápio em lista, o número do item e a fileira presa (82)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/cardapio-lista-tela.test.mjs

   A Lanchonete do Teste tem 16 itens e quase nenhuma foto:
     1. no painel (tela Cardápio), o dono escolhe "Só a lista", liga os números
        — o painel oferece numerar tudo de uma vez — e muda o número de um item;
     2. no link (celular): a capa e o cardápio em lista, como o impresso — o
        número na bolinha, o nome, o que vem e o preço; nenhuma foto vazia;
     3. a fileira das categorias fica presa no alto: rolando, a marcada
        acompanha; tocando, leva até a categoria;
     4. "Com fotos": os números continuam, e o item sem foto não ganha quadrado;
     5. fileira solta (desligada no painel): tocar filtra, como antes;
     6. o garçom também vê a lista; nada vaza para o lado a 375px.
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
await dono.criarConta({ email:`lista-${m}@teste.com`, senha:'minhasenhaboa', nome:'Seu Paiva',
  telefone:'+5511' + (950000000 + (Date.now() % 40000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Teste ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3254', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
const itens = [
  ['Hot-dog', 'Lanches individuais', 15], ['Misto', 'Lanches individuais', 30], ['Bauru', 'Lanches individuais', 30],
  ['Americano', 'Lanches individuais', 32], ['X-Burguer', 'Lanches individuais', 26],
  ['X-Calabresa', 'Lanches', 30], ['Frangão', 'Lanches', 30], ['Carnão', 'Lanches', 32], ['Calabacon', 'Lanches', 30],
  ['Batata-frita', 'Porções', 35], ['Batata com bacon', 'Porções', 60],
  ['Refrigerante', 'Bebidas', 7], ['Suco', 'Bebidas', 10], ['Água', 'Bebidas', 4], ['Cerveja', 'Bebidas', 12], ['Milkshake', 'Bebidas', 19],
];
for(const [nome, categoria, preco] of itens)
  await dono.inserir('produtos', { salaoId, nome, preco, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria,
    descricao: 'Pão, ' + nome.toLowerCase() + ', maionese, ketchup e batata-palha.',
    foto: nome === 'Milkshake' ? 'icones/icone-512.png' : undefined });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3254' });
const idDe = async nome => (await um(`select id from public.produtos where salao_id = $1 and nome = $2`, [salaoId, nome])).id;
const cfgCardapio = async () => (await um(`select cfg->'pedidos'->'cardapio' c from public.saloes where id = $1`, [salaoId])).c;
const mudarCfg = async c => banco.query(`update public.saloes set cfg = jsonb_set(coalesce(cfg, '{}'), '{pedidos}',
  coalesce(cfg->'pedidos', '{}') || jsonb_build_object('cardapio', $2::jsonb)) where id = $1`, [salaoId, JSON.stringify(c)]);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

/* ══════════════════════════════════════════════════════════════════════════
   1 — O DONO ESCOLHE NO PAINEL
   ══════════════════════════════════════════════════════════════════════════ */
secao('1. No painel: "Só a lista" e os números');
const ctxP = await nav.newContext({ viewport:{ width:1280, height:1000 } });
const pd = await ctxP.newPage();
pd.on('pageerror', e => erros.push('painel: ' + e.message));
pd.alertas = []; pd.responder = true;
pd.on('dialog', x => { pd.alertas.push(x.message()); pd.responder ? x.accept() : x.dismiss(); });
await pd.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await pd.goto(BASE + '/app.html');
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos)
  && bd.produtos.length >= 16, null, { timeout: 20000 });
await pd.waitForTimeout(800);
await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); irPara('produtos'); });
await pd.waitForSelector('#cardapioEstilo');
const cartao = await pd.evaluate(() => ({
  on: (document.querySelector('#cardapioEstilo .regua .on') || {}).textContent,
  numerar: document.getElementById('cdNumerar').checked, fixar: document.getElementById('cdFixar').checked }));
igual('de saída: com fotos, sem número, categorias presas', [limpo(cartao.on), cartao.numerar, cartao.fixar],
  ['📷 Com fotos', false, true]);
await pd.click('#cardapioEstilo button:has-text("Só a lista")');
await pd.waitForTimeout(1200);
igual('"Só a lista" vai para o banco', (await cfgCardapio() || {}).estilo, 'lista');

await pd.check('#cdNumerar');
await pd.waitForTimeout(1500);
verdade('ligar os números sem nenhum item numerado: o painel oferece numerar tudo',
  /Nenhum item tem número ainda/.test(pd.alertas.join(' | ')), pd.alertas.join(' | '));
const nums = (await banco.query(`select nome, numero from public.produtos where salao_id = $1 order by numero`, [salaoId])).rows;
igual('aceitou: 16 itens numerados de 1 a 16, sem repetir', nums.map(r => r.numero), [...Array(16)].map((_, i) => i + 1));
igual('na ordem das categorias e dos nomes (Bebidas primeiro, em ordem alfabética)',
  nums.slice(0, 3).map(r => r.nome), ['Água', 'Cerveja', 'Milkshake']);
igual('e "numerar" está ligado no banco', (await cfgCardapio() || {}).numerar, true);
const lista1 = limpo(await pd.textContent('#listaProdutos table'));
verdade('a lista do painel mostra o número antes do nome', /01\s*Água/.test(lista1), lista1.slice(0, 120));

// O dono põe o Hot-dog como 01 — e o painel avisa que o 01 já é da Água.
pd.alertas = []; pd.responder = false;
const hotdog = await idDe('Hot-dog');
await pd.evaluate(id => abrirProduto(id), hotdog);
await pd.waitForSelector('#pNumero');
await pd.fill('#pNumero', '1');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(600);
verdade('número repetido: o painel pergunta antes', /já é do item "Água"/.test(pd.alertas.join(' ')), pd.alertas.join(' | '));
igual('e, sem confirmar, nada muda (o Hot-dog continua o 12)', (await um(`select numero from public.produtos where id = $1`, [hotdog])).numero, 12);
await pd.fill('#pNumero', '99');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(1200);
igual('o Hot-dog vira o 99', (await um(`select numero from public.produtos where id = $1`, [hotdog])).numero, 99);
pd.responder = true;
await foto(pd, 'lista-1-painel');

/* ══════════════════════════════════════════════════════════════════════════
   2 E 3 — NO LINK: A LISTA E A FILEIRA PRESA
   ══════════════════════════════════════════════════════════════════════════ */
secao('2. No link: a capa e o cardápio em lista');
const ctxC = await nav.newContext({ viewport:{ width:412, height:780 }, isMobile:true, hasTouch:true });
const c = await ctxC.newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForSelector('#capaLoja .lista-item', { timeout: 15000 });
const capa = await c.evaluate(() => ({
  linhas: [...document.querySelectorAll('#capaLoja .lista-item')].map(x => x.querySelector('.lista-num').textContent + ' ' + x.querySelector('.lista-nome').textContent.trim()),
  fotos: document.querySelectorAll('#capaLoja .pr-foto').length }));
igual('a capa mostra os primeiros, em lista e na ordem dos números', capa.linhas.slice(0, 3), ['01 Água', '02 Cerveja', '03 Milkshake']);
igual('e nenhum quadro de foto', capa.fotos, 0);
await foto(c, 'lista-2-capa');

await c.evaluate(() => irPara('loja'));
await c.waitForSelector('#listaProdutos .loja-secao');
const loja = await c.evaluate(() => ({
  secoes: [...document.querySelectorAll('#listaProdutos .loja-secao-tit')].map(x => x.textContent.trim()),
  primeiro: (() => { const x = document.querySelector('#listaProdutos .lista-item');
    return [x.querySelector('.lista-num').textContent, x.querySelector('.lista-nome').textContent.trim(),
            x.querySelector('.lista-desc').textContent.trim(), x.querySelector('.lista-preco').textContent.trim()]; })(),
  fotos: document.querySelectorAll('#listaProdutos .pr-foto, #listaProdutos img').length,
  fixa: getComputedStyle(document.getElementById('lojaCats')).position,
  ultimo: [...document.querySelectorAll('#listaProdutos .loja-secao')].pop().innerText }));
igual('o cardápio inteiro, uma seção por categoria, na ordem dos números',
  loja.secoes, ['Bebidas', 'Lanches', 'Lanches individuais', 'Porções']);
igual('cada item: o número, o nome, o que vem e o preço', loja.primeiro.map(limpo),
  ['01', 'Água', 'Pão, água, maionese, ketchup e batata-palha.', 'R$ 4,00']);
igual('nenhuma foto no cardápio em lista (nem a do Milkshake)', loja.fotos, 0);
igual('a fileira das categorias fica presa no alto', loja.fixa, 'sticky');
verdade('o Hot-dog (99) é o último da seção dele', /Hot-dog/.test(loja.ultimo) === false
  && /99\s*Hot-dog/.test(limpo(await c.textContent('.loja-secao[data-k="lanches individuais"]'))),
  limpo(await c.textContent('.loja-secao[data-k="lanches individuais"]')).slice(-80));
await foto(c, 'lista-3-cardapio');

secao('3. A fileira presa: rolando e tocando');
const marcada = () => c.evaluate(() => limpo2((document.querySelector('#lojaCats .loja-cat.on') || {}).textContent));
await c.evaluate(() => { window.limpo2 = t => String(t || '').replace(/\s+/g, ' ').trim(); });
const caminho = [];
for(let i = 0; i < 40; i++){
  await c.mouse.wheel(0, 450); await c.waitForTimeout(80);
  const k = await marcada(); if(caminho[caminho.length - 1] !== k) caminho.push(k);
}
igual('rolando até o fim, a marcada acompanha todas as categorias, em ordem',
  caminho.filter(x => x !== 'Todos'), ['Bebidas', 'Lanches', 'Lanches individuais', 'Porções']);
const presa = await c.evaluate(() => Math.round(document.getElementById('lojaCats').getBoundingClientRect().top));
verdade('lá embaixo, a fileira continua no alto da tela', presa >= 0 && presa < 4, 'top = ' + presa);
await c.click('#lojaCats .loja-cat:has-text("Lanches individuais")');
await c.waitForTimeout(1300);
const pos = await c.evaluate(() => {
  const f = document.getElementById('lojaCats').getBoundingClientRect().bottom;
  const s = document.querySelector('.loja-secao[data-k="lanches individuais"]').getBoundingClientRect().top;
  return Math.round(s - f);
});
verdade('tocar em "Lanches individuais" leva até ela, logo abaixo da fileira', pos >= -4 && pos <= 40, 'distância = ' + pos);
igual('e ela fica marcada', await marcada(), 'Lanches individuais');
await foto(c, 'lista-4-presa');

/* ══════════════════════════════════════════════════════════════════════════
   4 E 5 — COM FOTOS, E A FILEIRA SOLTA
   ══════════════════════════════════════════════════════════════════════════ */
secao('4. "Com fotos": os números continuam');
await mudarCfg({ estilo:'fotos', numerar:true, fixar:true });
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForSelector('#capaLoja .pr-cartao', { timeout: 15000 });
await c.evaluate(() => irPara('loja'));
await c.waitForSelector('#listaProdutos .loja-secao');
const fotos = await c.evaluate(() => ({
  lista: document.querySelectorAll('#listaProdutos .lista-item').length,
  numeros: [...document.querySelectorAll('#listaProdutos .num-item')].slice(0, 3).map(x => x.textContent),
  semFoto: (() => { const b = [...document.querySelectorAll('#listaProdutos .bloco')].find(x => /Água/.test(x.textContent));
    return b ? b.querySelectorAll('[data-ico="presente"], img').length : -1; })(),
  comFoto: (() => { const b = [...document.querySelectorAll('#listaProdutos .bloco')].find(x => /Milkshake/.test(x.textContent));
    return b ? b.querySelectorAll('img').length : -1; })() }));
igual('sem a lista, com os cartões de sempre', fotos.lista, 0);
igual('o número aparece antes do nome', fotos.numeros, ['01', '02', '03']);
igual('o item sem foto fica só com o nome e o preço (sem o quadrado vazio)', fotos.semFoto, 0);
igual('e o que tem foto continua com ela', fotos.comFoto, 1);

secao('5. Fileira solta: tocar filtra, como antes');
await mudarCfg({ estilo:'lista', numerar:false, fixar:false });
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForSelector('#capaLoja .lista-item', { timeout: 15000 });
await c.evaluate(() => irPara('loja'));
await c.waitForSelector('#listaProdutos .lista-item');
igual('sem seções e sem os números', await c.evaluate(() => [document.querySelectorAll('.loja-secao').length,
  document.querySelectorAll('.lista-num').length, getComputedStyle(document.getElementById('lojaCats')).position]),
  [0, 0, 'static']);
await c.click('#lojaCats .loja-cat:has-text("Porções")');
await c.waitForTimeout(400);
igual('tocar em "Porções" mostra só as porções', await c.$$eval('#listaProdutos .lista-nome', e => e.map(x => x.textContent.trim())),
  ['Batata com bacon', 'Batata-frita']);
await ctxC.close();

/* ══════════════════════════════════════════════════════════════════════════
   6 — O GARÇOM, E O CELULAR PEQUENO
   ══════════════════════════════════════════════════════════════════════════ */
secao('6. O garçom também vê a lista; a 375px nada vaza');
await mudarCfg({ estilo:'lista', numerar:true, fixar:true });
await pd.reload();
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 16, null, { timeout: 20000 });
await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); abrirLancarNaMesa('3'); });
await pd.waitForSelector('#npCardapio .garcom-item');
const garcom = await pd.evaluate(() => ({
  lista: document.getElementById('npCardapio').classList.contains('garcom-lista'),
  fotos: document.querySelectorAll('#npCardapio .garcom-foto').length,
  primeiro: document.querySelector('#npCardapio .garcom-item .garcom-txt b').textContent.replace(/\s+/g, ' ').trim() }));
igual('o cardápio do garçom em lista, sem as fotos, com o número', [garcom.lista, garcom.fotos, garcom.primeiro], [true, 0, '01Água']);
await pd.fill('#npBusca', '99');
await pd.waitForTimeout(200);
igual('e o garçom acha o item pelo número', await pd.$$eval('#npCardapio .garcom-item', e => e.filter(x => x.style.display !== 'none')
  .map(x => x.querySelector('b').textContent.replace(/\s+/g, ' ').trim())), ['99Hot-dog']);
await ctxP.close();

const ctx375 = await nav.newContext({ viewport:{ width:375, height:812 }, isMobile:true, hasTouch:true });
const c3 = await ctx375.newPage();
c3.on('pageerror', e => erros.push('375: ' + e.message));
await c3.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c3.waitForSelector('#capaLoja .lista-item', { timeout: 15000 });
await c3.evaluate(() => irPara('loja'));
await c3.waitForSelector('#listaProdutos .lista-item');
igual('a 375px nada vaza para o lado', await c3.evaluate(() => document.documentElement.scrollWidth - innerWidth), 0);
await ctx375.close();

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

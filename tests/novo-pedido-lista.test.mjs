/* ===========================================================================
   PediHub — o Novo pedido do painel com os itens como na lista do link

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/novo-pedido-lista.test.mjs

   "Os itens pra lanchonete aparecerem como aparece a lista do link, não assim"
   (eram bolinhas soltas, em ordem alfabética). Numa lanchonete numerada:
     1. os itens vêm por categoria, na ordem do cardápio (pelo número);
     2. cada linha: o número, o nome, o que vem no lanche e o preço;
     3. a promoção mostra o preço cheio riscado e o de agora;
     4. a busca acha pelo número e pelo ingrediente; os botões das categorias
        mostram só a categoria; o título da categoria some quando fica vazia;
     5. tocar na linha põe no pedido, com aviso e "1 no pedido" na linha;
     6. item com adicionais: a escolha abre numa folha por cima (antes saía
        embaixo da lista, fora da tela, e o pedido ficava sem item);
     7. fechar a janela leva a folha junto.
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
await dono.criarConta({ email:`nplista-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono da Lista',
  telefone:'+5511' + (970000000 + (Date.now() % 20000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete da Lista ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3300', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
const item = (nome, numero, categoria, preco, descricao, extra) => dono.inserir('produtos', Object.assign({ salaoId, nome, numero,
  categoria, preco, descricao, custo:0, estoque:0, ativo:true, vendaOnline:true }, extra || {}));
await item('HOT-DOG', 1, 'Lanches individuais', 15, 'Salsicha, maionese, ketchup, mostarda, vinagrete e batata-palha.',
  { precoPromo: 5 });
await item('HOT-DOG DUPLO', 2, 'Lanches individuais', 17, '2 salsichas, maionese, ketchup, mostarda e batata-palha.');
await item('X-SALADA', 21, 'Lanches', 26, 'Hambúrguer, queijo, alface, tomate e maionese.');
await item('AMERICANO', 20, 'Lanches', 32, 'Hambúrguer, queijo, presunto, ovo, alface e tomate.');
await item('AÇAÍ 300 ML', 50, 'Açaí', 18, '');
const americano = (await dono.lista('produtos', { salaoId })).find(x => x.nome === 'AMERICANO').id;
await dono.chamar('salvar_opcoes_do_produto', { p_produto: americano, p_grupos: [
  { nome:'Adicionais', min:0, max:3, regra:'soma', opcoes:[{ nome:'Bacon', preco:'4' }, { nome:'Cheddar', preco:'3' }] }] });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3300',
  cfg:{ pedidos:{ cardapio:{ estilo:'lista', numerar:true, fixar:true } } } });

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const p = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true,
  deviceScaleFactor: process.env.SAIDA ? 2 : 1 })).newPage();
p.on('pageerror', e => erros.push(e.message));
p.on('dialog', x => x.accept());
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await p.goto(BASE + '/app.html');
await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 5, null, { timeout: 20000 });
await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); irPara('pedidos'); });
await p.waitForTimeout(600);
await p.evaluate(() => abrirNovoPedido());
await p.waitForSelector('#npCardapio .np-item');

secao('1. Por categoria, na ordem do cardápio');
const t = await p.evaluate(() => ({
  cats: [...document.querySelectorAll('#npCardapio .np-cat')].map(e => e.textContent.trim()),
  itens: [...document.querySelectorAll('#npCardapio .np-item')].map(e => e.querySelector('.np-nome').textContent.trim()),
  botoes: [...document.querySelectorAll('.np-cats button')].map(e => e.textContent.trim()),
}));
igual('as categorias, pela ordem dos números', t.cats, ['Lanches individuais', 'Lanches', 'Açaí']);
igual('os itens, pelo número', t.itens, ['HOT-DOG', 'HOT-DOG DUPLO', 'AMERICANO', 'X-SALADA', 'AÇAÍ 300 ML']);
igual('os botões das categorias em cima', t.botoes, ['Todos', 'Lanches individuais', 'Lanches', 'Açaí']);

secao('2. Cada linha: número, nome, o que vem e o preço');
const l = await p.evaluate(() => {
  const e = [...document.querySelectorAll('#npCardapio .np-item')].find(x => x.textContent.includes('AMERICANO'));
  return { num: e.querySelector('.np-num').textContent.trim(), desc: e.querySelector('.np-txt small').textContent.trim(),
           preco: e.querySelector('.np-preco b').textContent.trim() };
});
igual('o número com dois dígitos', l.num, '20');
igual('o que vem no lanche', l.desc, 'Hambúrguer, queijo, presunto, ovo, alface e tomate.');
verdade('e o preço', /32,00/.test(l.preco), l.preco);

secao('3. A promoção');
const pr = limpo(await p.textContent('#npCardapio .np-item:has-text("HOT-DOG DUPLO") >> xpath=preceding-sibling::button[1]'));
verdade('preço cheio riscado, o de agora e o selo', /15,00/.test(pr) && /5,00/.test(pr) && /promoção/.test(pr), pr);

secao('4. Busca e categorias');
const vistos = () => p.evaluate(() => [...document.querySelectorAll('#npCardapio .np-item')]
  .filter(e => e.style.display !== 'none').map(e => e.querySelector('.np-nome').textContent.trim()));
const titulos = () => p.evaluate(() => [...document.querySelectorAll('#npCardapio .np-cat')]
  .filter(e => e.style.display !== 'none').map(e => e.textContent.trim()));
await p.fill('#npBusca', '21');
igual('pelo número', await vistos(), ['X-SALADA']);
igual('e só o título da categoria dele', await titulos(), ['Lanches']);
await p.fill('#npBusca', 'ovo');
igual('pelo ingrediente', await vistos(), ['AMERICANO']);
await p.fill('#npBusca', '');
await p.click('.np-cats button:has-text("Açaí")');
igual('o botão "Açaí" mostra só o açaí', await vistos(), ['AÇAÍ 300 ML']);
await p.click('.np-cats button:has-text("Todos")');
igual('"Todos" volta tudo', (await vistos()).length, 5);

if(process.env.SAIDA){
  await p.evaluate(() => document.getElementById('npBusca').scrollIntoView({ block: 'start' }));
  await p.waitForTimeout(300);
  await p.screenshot({ path: process.env.SAIDA + '/novo-pedido-lista.png' });
}

secao('5. Tocar na linha põe no pedido');
await p.click('#npCardapio .np-item:has-text("X-SALADA")');
await p.waitForTimeout(400);
verdade('sem adicionais, entra na hora', /X-SALADA/.test(limpo(await p.textContent('#npLista'))), limpo(await p.textContent('#npLista')));
verdade('com o aviso "✓ X-SALADA no pedido"', /X-SALADA no pedido/.test(limpo(await p.textContent('#npEntrou').catch(() => ''))));
igual('e a linha mostra "1 no pedido"', limpo(await p.textContent('#npCardapio .np-item:has-text("X-SALADA") .np-tem')), '1 no pedido');

secao('6. Com adicionais: a escolha abre por cima, à vista');
await p.click('#npCardapio .np-item:has-text("AMERICANO")');
await p.waitForSelector('#npFolha .np-escolha', { timeout: 5000 });
const folha = await p.evaluate(() => {
  const f = document.getElementById('npFolha'), r = f.querySelector('.np-folha-pe .btn-p').getBoundingClientRect();
  return { dentroDaJanela: !!f.closest('.modal'), botaoNaTela: r.top >= 0 && r.bottom <= innerHeight,
           ops: [...f.querySelectorAll('.np-op')].map(b => b.querySelector('.np-op-nome').textContent.trim()
             + ' ' + b.querySelector('.np-op-preco').textContent.replace(/\s+/g, ' ').trim()) };
});
igual('fora da janela (nada a esconde)', folha.dentroDaJanela, false);
verdade('o "Pôr no pedido" está na tela do celular', folha.botaoNaTela);
igual('os adicionais, cada um numa linha com o preço', folha.ops, ['Bacon + R$ 4,00', 'Cheddar + R$ 3,00']);
await p.click('#npFolha .np-ops button:has-text("Bacon")');
if(process.env.SAIDA){ await p.waitForTimeout(300); await p.screenshot({ path: process.env.SAIDA + '/np-adicionais.png' }); }
await p.click('#npFolha button:has-text("Pôr no pedido")');
await p.waitForTimeout(400);
igual('a folha fecha', await p.$('#npFolha') ? 'aberta' : 'fechada', 'fechada');
verdade('o Americano entra com o bacon', /AMERICANO — Adicionais: Bacon/.test(limpo(await p.textContent('#npLista'))), limpo(await p.textContent('#npLista')));
verdade('e o total soma (26 + 32 + 4)', /62,00/.test(limpo(await p.textContent('#npTotal'))), limpo(await p.textContent('#npTotal')));
verdade('a lista diz quantos itens', /No pedido · 2 itens/.test(limpo(await p.textContent('#npLista'))));

secao('7. Fechar a janela com a escolha aberta não deixa a folha para trás');
await p.click('#npCardapio .np-item:has-text("AMERICANO")');
await p.waitForSelector('#npFolha');
await p.evaluate(() => fecharModal());
await p.waitForTimeout(200);
igual('a folha sai junto', await p.$('#npFolha') ? 'ficou' : 'saiu', 'saiu');

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

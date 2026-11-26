/* ===========================================================================
   PediHub — a Aparência de uma lanchonete, sem sobra de salão e sempre legível

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/aparencia-lanchonete.test.mjs

   "Essas configurações têm que funcionar para todas as lanchonetes… as cores
   têm que fazer contraste com o fundo… deixar tudo configurável." Numa
   lanchonete recém-criada:
     1. a tela de Aparência não tem cor de serviço nem de equipe, e os nomes
        falam de cardápio (Nome do item, Preço do item…);
     2. "Preços na capa" (dos serviços) e "Quem atende" somem;
     3. o slide tem "Fotos do cardápio": a prévia e o link mostram as fotos
        dos itens, com o nome;
     4. "Garantir leitura" ligado: salvar uma letra quase branca sobre o
        cartão branco ajusta sozinho e avisa; desligado, fica o que ele quis.
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
const verdade = (m, c, d) => c ? ok(m) : nao(m, d || 'esperava verdadeiro');
const igual = (m, a, b) => JSON.stringify(a) === JSON.stringify(b) ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const secao = t => console.log('\n' + t);
const limpo = t => String(t || '').replace(/\s+/g, ' ').trim();

function novaAba(){
  const g = {};
  const j = { PEDIHUB:{ url:BASE, chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

/* O contraste, com a mesma conta do WCAG que o painel usa. */
const lum = hex => {
  const n = parseInt(hex.replace('#', ''), 16);
  const c = [n >> 16 & 255, n >> 8 & 255, n & 255].map(v => { v /= 255;
    return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; });
  return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
};
const contraste = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

const marca = Date.now().toString(36) + Math.floor(Math.random() * 1000);
const dona = novaAba();
await dona.criarConta({ email:`al-${marca}@teste.com`, senha:'minhasenhaboa', nome:'Rita Paiva',
  telefone:'+5511' + (100000000 + Math.floor(Math.random() * 89999999)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao:'Lanchonete Contraste ' + marca, p_tipo:'restaurante',
  p_telefone:'(11) 98111-3252', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;
await dona.inserir('produtos', { salaoId: SALAO, nome:'X-Salada', preco:22, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Lanches', foto:'icones/icone-512.png' });
await dona.inserir('produtos', { salaoId: SALAO, nome:'X-Bacon', preco:27, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Lanches', foto:'icones/icone-192.png' });
await dona.inserir('produtos', { salaoId: SALAO, nome:'Coca lata', preco:6, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Bebidas' });
await dona.atualizar('saloes', SALAO, { whatsapp:'(11) 98111-3252',
  cfg:{ cor:'#C2410C', tema:'claro', pagamentos:{ formas:['pix'] } } });
const cfgDe = async () => (await dona.lista('saloes', { id: SALAO }))[0].cfg || {};

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [], alertas = [];
const ctx = await nav.newContext({ viewport:{ width:412, height:880 }, isMobile:true, hasTouch:true });
const p = await ctx.newPage();
p.on('pageerror', e => erros.push('painel: ' + e.message));
p.on('dialog', x => { alertas.push(x.message()); x.accept(); });
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dona.sessao()]);
const abrirAparencia = async () => {
  await p.goto(BASE + '/app.html');
  await p.waitForFunction(() => typeof irPara === 'function' && typeof bd !== 'undefined' && bd
    && Array.isArray(bd.saloes) && Array.isArray(bd.produtos) && bd.produtos.length >= 3, null, { timeout: 20000 });
  await p.waitForTimeout(800);
  await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); irPara('salao'); });
  await p.waitForTimeout(400);
  await p.evaluate(() => trocarAbaSalao('aparencia'));
  await p.waitForTimeout(800);
};
await abrirAparencia();

secao('1. As cores: só as que existem no link de uma lanchonete');
const t = await p.evaluate(() => {
  const chaves = [...document.querySelectorAll('.ap-controles .cor-linha[data-chave]')].map(e => e.dataset.chave);
  const rot = k => { const e = document.querySelector(`.cor-linha[data-chave="${k}"]`);
    return e ? e.textContent.replace(/\s+/g, ' ').trim() : null; };
  return { chaves, nomeProduto: rot('nomeProduto'), precoProduto: rot('precoProduto'),
    tituloProdutos: rot('tituloProdutos'), fundoProduto: rot('fundoProduto') };
});
const DE_SALAO = ['tituloServicos', 'nomeServico', 'descServico', 'precoServico', 'duracao',
  'verTodosServicos', 'tituloEquipe', 'nomeEquipe', 'fundoServico'];
igual('nenhuma cor de serviço ou de equipe', t.chaves.filter(k => DE_SALAO.includes(k)), []);
verdade('as do cardápio continuam lá', ['nomeProduto', 'precoProduto', 'tituloProdutos', 'texto', 'papel', 'card']
  .every(k => t.chaves.includes(k)), JSON.stringify(t.chaves));
verdade('"Nome do item", e não "nome do produto"', /Nome do item/.test(t.nomeProduto || ''), t.nomeProduto);
verdade('"Preço do item"', /Preço do item/.test(t.precoProduto || ''), t.precoProduto);
verdade('"Título do cardápio"', /Título do cardápio/.test(t.tituloProdutos || ''), t.tituloProdutos);

secao('2. O que é de salão some da tela');
const tela = await p.evaluate(() => {
  const visivel = e => !!e && !!(e.offsetWidth || e.offsetHeight || e.getClientRects().length);
  const txt = document.querySelector('.ap-controles') ? document.querySelector('.ap-controles').innerText : '';
  return {
    preco: visivel(document.getElementById('reguaPreco')),
    equipe: !!document.getElementById('coresFrasesEquipe'),
    quemAtende: /Quem atende/.test(txt),
    servicos: (txt.match(/servi[çc]o/gi) || []).length,
    slides: [...document.querySelectorAll('#reguaSlide button')].map(b => b.textContent.trim()),
    leitura: !!document.getElementById('apLeituraAuto') && document.getElementById('apLeituraAuto').checked,
  };
});
igual('"Preços na capa" (dos serviços) não aparece', tela.preco, false);
igual('nem o grupo "Quem atende"', [tela.equipe, tela.quemAtende], [false, false]);
igual('nenhuma frase fala em serviço', tela.servicos, 0);
igual('o slide: fotos do cardápio, minhas fotos ou sem slide', tela.slides,
  ['Fotos do cardápio', 'Minhas fotos e vídeos', 'Sem slide']);
igual('"Garantir leitura" nasce ligado', tela.leitura, true);

secao('3. O slide com as fotos do cardápio');
await p.evaluate(() => escolherAparencia('slideDe', 'cardapio'));
await p.waitForTimeout(300);
const pv = await p.evaluate(() => {
  const s = document.querySelector('#previaFone .fone-slide');
  return s ? { vazio: s.classList.contains('vazio'), leg: (s.querySelector('.fone-slide-leg') || {}).textContent || '',
    fotos: s.querySelectorAll('.fone-slide-fundo, img').length } : null;
});
verdade('a prévia mostra as fotos dos itens', pv && !pv.vazio && pv.fotos >= 1, JSON.stringify(pv));
igual('com o nome do primeiro item com foto', limpo(pv && pv.leg), 'X-Salada');
await p.evaluate(() => salvarAparencia());
await p.waitForTimeout(1800);
igual('no banco, slideDe = cardapio', (await cfgDe()).slideDe, 'cardapio');

const c = await (await nav.newContext({ viewport:{ width:412, height:880 }, isMobile:true, hasTouch:true })).newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForSelector('#capaSlides figure', { timeout: 15000 }).catch(() => {});
const sl = await c.evaluate(() => ({
  legendas: [...document.querySelectorAll('#capaSlides figcaption')].map(f => f.textContent.trim()),
  pontos: document.querySelectorAll('#slidePontos button').length,
  visivel: getComputedStyle(document.getElementById('capaSlides')).display !== 'none',
}));
igual('o link mostra o slide com os itens que têm foto', sl.legendas.slice().sort(), ['X-Bacon', 'X-Salada']);
igual('um ponto para cada foto', sl.pontos, 2);
verdade('e o slide está à vista', sl.visivel);

secao('4. Garantir leitura: ligado, a letra ruim é ajustada ao salvar');
await p.evaluate(() => escolherCorSolta('nomeProduto', '#F2F2F2'));
await p.waitForTimeout(300);
await p.evaluate(() => salvarAparencia());
await p.waitForTimeout(1800);
const aviso = limpo(await p.textContent('#salvouAparencia').catch(() => ''));
verdade('o aviso diz que arrumou', /arrumei a leitura de \d+ cor/.test(aviso), aviso);
let cfg = await cfgDe();
const nome = (cfg.cores || {}).nomeProduto;
const cartao = ((cfg.cores || {}).card) || '#FFFFFF';
verdade('o nome do item saiu do quase branco', nome && nome.toUpperCase() !== '#F2F2F2', nome);
verdade('e agora se lê sobre o cartão (3:1 ou mais)', nome && contraste(nome, cartao) >= 3,
  nome + ' sobre ' + cartao + ' = ' + (nome ? contraste(nome, cartao).toFixed(2) : '?'));
igual('guardou que a leitura é garantida', cfg.leituraAuto, true);

secao('5. Garantir leitura: desligado, fica a cor que ele escolheu');
await abrirAparencia();
await p.evaluate(() => { document.getElementById('apLeituraAuto').checked = false;
  escolherCorSolta('nomeProduto', '#F2F2F2'); });
await p.waitForTimeout(300);
await p.evaluate(() => salvarAparencia());
await p.waitForTimeout(1800);
cfg = await cfgDe();
igual('a cor fica como ele quis', String((cfg.cores || {}).nomeProduto || '').toUpperCase(), '#F2F2F2');
igual('e o desligado fica guardado', cfg.leituraAuto, false);
igual('o aviso é só "Salvo"', limpo(await p.textContent('#salvouAparencia').catch(() => '')), 'Salvo');
await abrirAparencia();
igual('reabrindo, a caixa continua desmarcada', await p.evaluate(() => document.getElementById('apLeituraAuto').checked), false);
verdade('e a tela avisa que está difícil de ler', /dif[íi]cil/i.test(limpo(await p.textContent('#avisoLegibilidade').catch(() => ''))),
  limpo(await p.textContent('#avisoLegibilidade').catch(() => '')));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

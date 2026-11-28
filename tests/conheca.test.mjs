/* ===========================================================================
   PediHub — a página dos anúncios (conheca.html)

     python3 -m http.server 8099 --directory .     (deixe rodando)
     PLAYWRIGHT=… node tests/conheca.test.mjs

   É para onde vai o anúncio pago. O que tem de valer:
     1. a promessa num título só, e o que se vê ao compartilhar no WhatsApp e
        no Instagram (título, descrição e a imagem, que existe no site);
     2. os planos do PediHub (R$ 97 e R$ 147), e nada do AgendaPro
        (agenda, salão, barbearia, plano Básico);
     3. todo "Criar conta" leva ao cadastro — e LEVA A ORIGEM DO ANÚNCIO
        (utm_*, fbclid): o anúncio do Instagram chega no cadastro como
        Instagram em "Como você nos conheceu?", e não como "Página do PediHub";
     4. o menu leva a seções que existem; as imagens carregam e têm texto
        alternativo; no celular nada vaza para o lado.
   =========================================================================== */
import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const BASE = process.env.BASE || 'http://127.0.0.1:8099/';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d || 'esperava verdadeiro');
const igual = (m, a, b) => JSON.stringify(a) === JSON.stringify(b) ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const secao = t => console.log('\n' + t);

const nav = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium' });
const erros = [];
async function abrir(sufixo = '', opc = { viewport:{ width:1280, height:900 } }){
  const ctx = await nav.newContext(opc);
  const p = await ctx.newPage();
  p.on('pageerror', e => erros.push(e.message));
  await p.goto(BASE + 'conheca.html' + sufixo);
  await p.waitForTimeout(600);
  return { p, ctx };
}

secao('1. A promessa, e o que aparece ao compartilhar');
{
  const { p, ctx } = await abrir();
  const h1 = await p.$$eval('h1', e => e.map(x => x.textContent.replace(/\s+/g, ' ').trim()));
  verdade('um título só (h1), com a promessa', h1.length === 1 && /cardápio digital/i.test(h1[0]) && /sem comissão/i.test(h1[0]), JSON.stringify(h1));
  const meta = await p.evaluate(() => {
    const m = s => (document.querySelector(s) || {}).content || (document.querySelector(s) || {}).href || '';
    return { titulo: document.title, canon: m('link[rel="canonical"]'), ogt: m('meta[property="og:title"]'),
             ogd: m('meta[property="og:description"]'), ogi: m('meta[property="og:image"]') };
  });
  verdade('título da aba, endereço oficial, e título e descrição para compartilhar',
    /PediHub/.test(meta.titulo) && /pedihub\/conheca\.html$/.test(meta.canon) && /PediHub/.test(meta.ogt) && meta.ogd.length > 40,
    JSON.stringify(meta));
  verdade('a imagem de compartilhar é a do site', /pedihub\/icones\/compartilhar\.png$/.test(meta.ogi), meta.ogi);
  const img = await p.evaluate(async u => { const r = await fetch(u); const b = await r.blob(); return [r.status, b.type, b.size]; },
    BASE + 'icones/compartilhar.png');
  verdade('e ela existe no site (PNG)', img[0] === 200 && img[1] === 'image/png' && img[2] > 5000, JSON.stringify(img));
  const dim = await p.evaluate(async u => new Promise(r => { const i = new Image(); i.onload = () => r([i.naturalWidth, i.naturalHeight]); i.src = u; }),
    BASE + 'icones/compartilhar.png');
  igual('no tamanho que o WhatsApp e o Instagram usam (1200×630)', dim, [1200, 630]);

  secao('2. Os planos do PediHub, e nada do AgendaPro');
  const texto = await p.evaluate(() => document.body.innerText);
  verdade('Essencial R$ 97 e Profissional R$ 147', /R\$ 97\b/.test(texto) && /R\$ 147\b/.test(texto) && /Essencial/.test(texto) && /Profissional/.test(texto));
  const ruins = (texto.match(/[^\n]{0,30}\b(agenda|agendamento|salão|barbearia|plano Básico)\b[^\n]{0,30}/gi) || []);
  igual('nenhuma palavra do salão', ruins, []);

  secao('4. Menu, imagens');
  const ancoras = await p.evaluate(() => [...document.querySelectorAll('a[href^="#"]')].map(a => a.getAttribute('href'))
    .filter(h => h.length > 1).filter(h => !document.getElementById(h.slice(1))));
  igual('todo link do menu (#…) leva a uma seção que existe', ancoras, []);
  const imgs = await p.evaluate(() => [...document.images].map(i => ({ src: i.getAttribute('src'), ok: i.complete && i.naturalWidth > 0, alt: i.hasAttribute('alt') })));
  verdade('todas as imagens carregam', imgs.length > 0 && imgs.every(i => i.ok), JSON.stringify(imgs.filter(i => !i.ok)));
  verdade('e toda imagem tem texto alternativo', imgs.every(i => i.alt), JSON.stringify(imgs.filter(i => !i.alt)));
  await ctx.close();
}

secao('3. Os botões de cadastro levam a origem do anúncio');
{
  const { p, ctx } = await abrir();
  const sem = await p.$$eval('a[href^="criar.html"]', e => [...new Set(e.map(a => a.getAttribute('href')))]);
  igual('sem anúncio: todo "Criar conta" vai ao cadastro com origem=pagina', sem, ['criar.html?origem=pagina']);
  await ctx.close();
}
{
  const { p, ctx } = await abrir('?utm_source=instagram&utm_campaign=lanche&fbclid=abc123&outra=coisa');
  const com = await p.$$eval('a[href^="criar.html"]', e => [...new Set(e.map(a => a.getAttribute('href')))]);
  verdade('com anúncio: todos levam utm_source, utm_campaign e fbclid — e só eles',
    com.length === 1 && /utm_source=instagram/.test(com[0]) && /utm_campaign=lanche/.test(com[0]) && /fbclid=abc123/.test(com[0])
      && /origem=pagina/.test(com[0]) && !/outra=/.test(com[0]), JSON.stringify(com));
  await p.click('a.btn-p[href^="criar.html"]');
  await p.waitForLoadState('load'); await p.waitForTimeout(600);
  igual('e o cadastro já marca "Como você nos conheceu?" = Instagram',
    await p.evaluate(() => { const s = document.getElementById('fOrigem'); return s ? s.options[s.selectedIndex].text : null; }), 'Instagram');
  await ctx.close();
}

secao('5. No celular');
{
  const { p, ctx } = await abrir('', { viewport:{ width:375, height:812 }, isMobile:true, hasTouch:true });
  igual('a 375px nada vaza para o lado', await p.evaluate(() => document.documentElement.scrollWidth - innerWidth), 0);
  await ctx.close();
}

igual('\nnenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

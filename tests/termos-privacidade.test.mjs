/* ===========================================================================
   PediHub — os Termos de uso e a Política de privacidade

     python3 -m http.server 8099 --directory .     (deixe rodando)
     node tests/termos-privacidade.test.mjs

   "Fazer termos de uso e política." A tela de login dizia "você concorda com os
   termos de uso", e os termos não existiam. Agora:
     1. as duas páginas abrem, com o título, a data, o resumo e o índice — e
        todo item do índice leva a uma seção que existe;
     2. os dados da empresa vêm do empresa.js: o WhatsApp aparece formatado e
        com o link; o CNPJ e o e-mail, vazios, NÃO aparecem (nada de "CNPJ: ");
     3. preenchido o CNPJ, ele aparece — e como texto, nunca como HTML;
     4. o cadastro, o login, a página de venda e o rodapé de todas as telas
        levam às duas páginas;
     5. no celular nada vaza para o lado, e no escuro o texto continua legível.
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
const limpo = t => String(t || '').replace(/\s+/g, ' ').trim();

const nav = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium' });
const erros = [];
async function abrir(pagina, opc = { viewport:{ width:1280, height:900 } }, antes){
  const ctx = await nav.newContext(opc);
  const p = await ctx.newPage();
  p.on('pageerror', e => erros.push(pagina + ': ' + e.message));
  if(antes) await p.route('**/empresa.js', antes);
  await p.goto(BASE + pagina);
  await p.waitForTimeout(400);
  return { p, ctx };
}

for(const [pagina, titulo] of [['termos.html', 'Termos de uso'], ['privacidade.html', 'Política de privacidade']]){
  secao('1. ' + titulo);
  const { p, ctx } = await abrir(pagina);
  igual('o título da página', limpo(await p.textContent('h1')), titulo);
  verdade('a data da última atualização', /Última atualização: \d+ de \w+ de \d{4}/.test(await p.textContent('.data')));
  verdade('o resumo "Em poucas palavras"', /Em poucas palavras/.test(await p.textContent('.resumo')));
  const quebrados = await p.evaluate(() => [...document.querySelectorAll('.indice a')]
    .map(a => a.getAttribute('href')).filter(h => !document.getElementById(h.slice(1))));
  igual('todo item do índice leva a uma seção que existe', quebrados, []);
  verdade('e o índice tem as seções', (await p.$$('.indice a')).length >= 10);

  secao('2. Os dados da empresa, do empresa.js');
  const zap = await p.$eval('.quem a[data-empresa="whatsapp"]', a => ({ t: a.textContent, h: a.href, vis: !a.closest('[hidden]') }));
  igual('o WhatsApp formatado, com o link', zap, { t: '(11) 96365-9620', h: 'https://wa.me/5511963659620', vis: true });
  const quem = limpo(await p.evaluate(() => document.querySelector('.quem').innerText));
  verdade('sem CNPJ, sem e-mail e sem razão social em branco', !/CNPJ|E-mail|Razão social|Sede/.test(quem), quem);
  verdade('a outra página no topo', (await p.$$(`.topo nav a[href="${pagina === 'termos.html' ? 'privacidade.html' : 'termos.html'}"]`)).length === 1);
  verdade('o aviso de direitos autorais no rodapé', /Todos os direitos reservados/.test(await p.textContent('.rodape-legal')));
  await ctx.close();
}

secao('3. Preenchido, o CNPJ aparece (como texto)');
{
  const { p, ctx } = await abrir('termos.html', undefined, async rota => {
    const r = await rota.fetch();
    const corpo = (await r.text()).replace("cnpj:     ''", "cnpj:     '12.345.678/0001-90<b>x</b>'")
                                  .replace("email:    ''", "email:    'contato@pedihub.com.br'");
    await rota.fulfill({ response: r, body: corpo });
  });
  const quem = limpo(await p.evaluate(() => document.querySelector('.quem').innerText));
  verdade('"CNPJ: 12.345.678/0001-90"', /CNPJ: 12\.345\.678\/0001-90<b>x<\/b>/.test(quem), quem);
  igual('e não vira HTML', await p.$$eval('.quem b', e => e.map(x => x.textContent)), ['PediHub']);
  igual('o e-mail com o link', await p.$eval('.quem a[data-empresa="email"]', a => a.getAttribute('href')), 'mailto:contato@pedihub.com.br');
  await ctx.close();
}

secao('4. Quem leva às duas páginas');
for(const pagina of ['criar.html', 'entrar.html', 'conheca.html', 'index.html', 'cardapio.html', 'app.html?demo=1', 'nova-senha.html']){
  const { p, ctx } = await abrir(pagina);
  const links = await p.$$eval('a', e => e.map(a => a.getAttribute('href')));
  verdade(pagina + ': Termos de uso e Política de privacidade',
    links.includes('termos.html') && links.includes('privacidade.html'), JSON.stringify(links.filter(h => /termos|privac/.test(h || ''))));
  if(pagina === 'criar.html')
    verdade('   e o cadastro diz que, ao continuar, a pessoa concorda',
      /Ao continuar, você concorda com os Termos de uso e a Política de privacidade/.test(limpo(await p.textContent('#aceiteTermos'))));
  if(pagina === 'entrar.html')
    verdade('   e o login também', /Ao entrar, você concorda com os Termos de uso e a Política de privacidade/.test(limpo(await p.textContent('body'))));
  await ctx.close();
}

secao('5. No celular e no escuro');
for(const pagina of ['termos.html', 'privacidade.html']){
  const { p, ctx } = await abrir(pagina, { viewport:{ width:375, height:740 }, isMobile:true, hasTouch:true, colorScheme:'dark' });
  const largura = await p.evaluate(() => [document.documentElement.scrollWidth, window.innerWidth]);
  verdade(pagina + ': nada vaza para o lado', largura[0] <= largura[1], JSON.stringify(largura));
  const cores = await p.evaluate(() => {
    const b = getComputedStyle(document.body), t = getComputedStyle(document.querySelector('main p'));
    return [b.backgroundColor, t.color];
  });
  verdade('   fundo escuro, texto claro', /rgb\(20, 18, 16\)/.test(cores[0]) && !/rgb\(87, 83, 78\)/.test(cores[1]), JSON.stringify(cores));
  if(process.env.SAIDA) await p.screenshot({ path: process.env.SAIDA + '/' + pagina.replace('.html', '') + '-celular.png' });
  await ctx.close();
}

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

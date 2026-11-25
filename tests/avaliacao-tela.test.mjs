/* ===========================================================================
   PediHub — a avaliação do pedido, do link ao painel (80_avaliacoes)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/avaliacao-tela.test.mjs

   No Sushi do Kenji:
     1. o pedido entregue abre o "Como foi o seu pedido?": tocar na 4ª
        estrela pinta quatro, escreve o comentário, envia — e o banco grava;
     2. o último pedido entregue, ainda sem nota, vira um convite na capa;
     3. com 3 avaliações e média de 4 para cima, a capa mostra "O que dizem
        os clientes", com os comentários bons;
     4. no painel, a aba Avaliações mostra a média, as estrelas por nota e
        a ruim em destaque; "Tirar do link" tira o comentário da capa.
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
const foto = async (pg, nome) => { if(process.env.FOTOS){ await pg.waitForTimeout(700); await pg.screenshot({ path: path.join(process.env.FOTOS, nome + '.png') }); } };

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
await dono.criarConta({ email:`kenji-${m}@teste.com`, senha:'minhasenhaboa', nome:'Kenji',
  telefone:'+5511' + (960000000 + (Date.now() % 30000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Sushi do Kenji ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3255', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'Combo 20 peças', preco:60, custo:0, estoque:0, ativo:true, vendaOnline:true });
await dono.inserir('produtos', { salaoId, nome:'Temaki', preco:30, custo:0, estoque:0, ativo:true, vendaOnline:true });
const prod = (await um(`select id from public.produtos where salao_id = $1 and nome = 'Combo 20 peças'`, [salaoId])).id;

const cliente = aba();
const pedir = async (nome, tel) => {
  const r = await cliente.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome, telefone: tel,
    entrega:'retirada', pagamento:'pix', itens:[{ produto: prod, quantidade: 1 }] } });
  await banco.query(`update public.pedidos set status = 'entregue', entregue_em = now() where token = $1`, [r.token]);
  return r;
};
const r1 = await pedir('Bruna Souza', '11961110001');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctx = await nav.newContext({ viewport:{ width:412, height:915 }, isMobile:true, hasTouch:true });
const c = await ctx.newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForTimeout(2500);

secao('1. O cliente avalia o pedido entregue');
await c.evaluate(t => abrirAcompanhar(t), r1.token);
await c.waitForSelector('#avCaixa .av-estrela', { timeout: 10000 });
verdade('aparece "Como foi o seu pedido?" com 5 estrelas',
  /Como foi o seu pedido/.test(limpo(await c.textContent('#avCaixa'))) && (await c.$$('#avCaixa .av-estrela')).length === 5);
verdade('o botão de enviar começa desligado (falta a nota)', await c.$eval('#avEnviar', b => b.disabled));
await c.click('#avCaixa .av-estrela[data-n="4"]');
igual('tocar na 4ª estrela pinta quatro', await c.$$eval('#avCaixa .av-estrela.on', e => e.length), 4);
await c.fill('#avTexto', 'Peixe fresquinho, chegou rápido');
await foto(c, 'avaliar-1-estrelas');
await c.click('#avEnviar');
await c.waitForSelector('.av-feita', { timeout: 8000 });
verdade('depois de enviar: "Obrigado pela avaliação!" com as 4 estrelas e o comentário',
  /Obrigado pela avaliação/.test(limpo(await c.textContent('.av-feita'))) && /★★★★☆/.test(await c.textContent('.av-feita'))
  && /Peixe fresquinho/.test(await c.textContent('.av-feita')), limpo(await c.textContent('.av-feita')));
igual('e o banco gravou a nota e o comentário',
  Object.values(await um(`select a.nota, a.comentario from public.avaliacoes a join public.pedidos p on p.id = a.pedido_id where p.token = $1`, [r1.token])),
  [4, 'Peixe fresquinho, chegou rápido']);
await foto(c, 'avaliar-2-obrigado');

secao('2. O convite na capa');
const r2 = await pedir('Carlos Lima', '11961110002');
await c.evaluate(([t, n]) => guardarPedido(t, n), [r2.token, r2.numero]);
await c.reload(); await c.waitForTimeout(3000);
const convite = limpo(await c.textContent('#capaPedido'));
verdade('a capa convida: "Como foi o pedido #N?"', new RegExp('Como foi o pedido #' + r2.numero).test(convite), convite);
await c.click('#capaPedido .pd-aviso');
await c.waitForSelector('#avCaixa', { timeout: 8000 });
await c.click('#avCaixa .av-estrela[data-n="5"]');
await c.fill('#avTexto', 'Melhor temaki da cidade');
await c.click('#avEnviar');
await c.waitForSelector('.av-feita', { timeout: 8000 });
ok('tocar no convite leva à avaliação, e ela é enviada');

secao('3. O que dizem os clientes, na capa');
const r3 = await pedir('Duda Alves', '11961110003');
await cliente.chamar('avaliar_pedido', { p_token: r3.token, p_nota: 2, p_comentario: 'Veio sem shoyu' });
await c.reload(); await c.waitForTimeout(3000);
const sec = await c.evaluate(() => {
  const s = document.getElementById('capaAvaliacoes');
  return { texto: s.innerText.replace(/\s+/g, ' ').trim(), cartoes: s.querySelectorAll('.av-capa-cartao').length };
});
verdade('com 3 avaliações (4, 5 e 2) a média é 3,7: abaixo de 4, a capa NÃO mostra', sec.cartoes === 0 && !sec.texto, JSON.stringify(sec));
const r4 = await pedir('Edu Reis', '11961110004');
await cliente.chamar('avaliar_pedido', { p_token: r4.token, p_nota: 5, p_comentario: 'Tudo perfeito' });
await c.reload(); await c.waitForTimeout(3000);
const sec2 = await c.evaluate(() => {
  const s = document.getElementById('capaAvaliacoes');
  return { texto: s.innerText.replace(/\s+/g, ' ').trim(), cartoes: s.querySelectorAll('.av-capa-cartao').length };
});
verdade('com média 4,0 aparece "O que dizem os clientes · ★ 4,0 · 4 avaliações"',
  /O que dizem os clientes/i.test(sec2.texto) && /★ 4,0/.test(sec2.texto) && /4 avaliações/.test(sec2.texto), sec2.texto);
igual('com os 3 comentários bons (o de 2 estrelas fica de fora)', sec2.cartoes, 3);
verdade('e sem a reclamação', !/sem shoyu/.test(sec2.texto), sec2.texto);
await c.evaluate(() => document.getElementById('capaAvaliacoes').scrollIntoView({ block: 'center' }));
await foto(c, 'avaliar-3-capa');
igual('a 412px nada vaza para o lado', await c.evaluate(() => document.documentElement.scrollWidth - innerWidth), 0);

secao('4. A aba Avaliações no painel');
const ctxP = await nav.newContext({ viewport:{ width:1280, height:1000 } });
const pd = await ctxP.newPage();
pd.on('pageerror', e => erros.push('painel: ' + e.message));
await pd.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await pd.goto(BASE + '/app.html');
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 2, null, { timeout: 20000 });
await pd.waitForTimeout(800);
await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); });
verdade('a aba "Avaliações" está no menu do dono', !!(await pd.$('.aba[data-chave="avaliacoes"]')));
await pd.click('.aba[data-chave="avaliacoes"]');
await pd.waitForSelector('#avResumo .av-media', { timeout: 10000 });
const resumo = limpo(await pd.textContent('#avResumo'));
verdade('o resumo: média 4,0, 4 avaliações', /4,0/.test(resumo) && /4 avaliações/.test(resumo), resumo);
igual('a lista tem as 4, e a de 2 estrelas em destaque', [await pd.$$eval('#avLista .av-item', e => e.length),
  await pd.$$eval('#avLista .av-item.av-ruim', e => e.length)], [4, 1]);
verdade('com o que veio no pedido', /Combo 20 peças/.test(limpo(await pd.textContent('#avLista'))));
await pd.click('#avFiltros button:has-text("Para melhorar")');
igual('o filtro "Para melhorar" mostra só a ruim', await pd.$$eval('#avLista .av-item', e => e.map(x => /sem shoyu/.test(x.textContent))), [true]);
await foto(pd, 'avaliar-4-painel');
await pd.click('#avFiltros button:has-text("Todas")');
await pd.click('#avLista .av-item:has-text("Tudo perfeito") button:has-text("Tirar do link")');
await pd.waitForTimeout(800);
igual('"Tirar do link" grava no banco', (await um(`select oculta from public.avaliacoes where comentario = 'Tudo perfeito' and salao_id = $1`, [salaoId])).oculta, true);
await c.reload(); await c.waitForTimeout(3000);
verdade('e o comentário sai da capa', !/Tudo perfeito/.test(await c.textContent('#capaAvaliacoes')));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

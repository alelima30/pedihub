/* ===========================================================================
   PediHub — o tempo de entrega, do painel ao acompanhamento

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/tempo-entrega-tela.test.mjs

   "Quando pedi o lanche não tinha tempo de entrega." Na Lanchonete do Tempo:
     1. a tela de Pedidos avisa que falta o tempo e oferece 30 min, 40 min,
        1 hora e Outro — um toque grava;
     2. no link: na capa (junto do ABERTO), no topo do cardápio e ao escolher
        Entrega ou Retirada;
     3. no acompanhamento: "Chega por volta das HH:MM";
     4. "Outro" aceita o que o dono escrever (1h30), e a hora prevista segue.
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
const dono = aba();
await dono.criarConta({ email:`tempo-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dona do Tempo',
  telefone:'+5511' + (960000000 + (Date.now() % 30000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Tempo ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3260', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Burguer', preco:26, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria:'Lanches' });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3260' });
const xId = (await um(`select id from public.produtos where salao_id = $1`, [salaoId])).id;
const tempoNoBanco = async () => (await um(`select cfg->'pedidos'->>'tempo' t from public.saloes where id = $1`, [salaoId])).t;

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

secao('1. Na tela de Pedidos: 30 min, 40 min, 1 hora e Outro');
const pd = await (await nav.newContext({ viewport:{ width:1280, height:900 } })).newPage();
pd.on('pageerror', e => erros.push('painel: ' + e.message));
pd.resposta = '';
pd.on('dialog', x => x.type() === 'prompt' ? x.accept(pd.resposta) : x.accept());
await pd.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await pd.goto(BASE + '/app.html');
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 1, null, { timeout: 20000 });
await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); irPara('pedidos'); });
await pd.waitForSelector('#pdTempoBarra button');
igual('os atalhos de saída', await pd.$$eval('#pdTempoBarra button', e => e.map(x => x.textContent.trim())), ['30 min', '40 min', '1 hora', 'Outro']);
verdade('sem tempo escolhido, a tela avisa', /o cliente vê no link/.test(limpo(await pd.textContent('#pdTempoBarra'))));
await pd.click('#pdTempoBarra button:has-text("40 min")');
await pd.waitForTimeout(1200);
igual('um toque em "40 min" grava', await tempoNoBanco(), '40 min');
igual('e ele fica marcado', limpo(await pd.textContent('#pdTempoBarra button.btn-p')), '40 min');

secao('2. No link: capa, cardápio e a escolha de Entrega');
const c = await (await nav.newContext({ viewport:{ width:412, height:870 }, isMobile:true, hasTouch:true })).newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForSelector('#statusCasa .tempo-casa', { timeout: 15000 }).catch(() => {});
igual('na capa, junto do ABERTO', limpo(await c.textContent('#statusCasa .tempo-casa').catch(() => '')), '🛵 Entrega em cerca de 40 min');
await c.evaluate(() => irPara('loja'));
await c.waitForTimeout(600);
igual('no topo do cardápio', limpo(await c.textContent('#lojaAviso .tempo-casa').catch(() => '')), '🛵 Entrega em cerca de 40 min');
await c.evaluate(id => { mudarNoCarrinho(id, 1); irPara('pedido'); }, xId);
await c.waitForTimeout(500);
await c.evaluate(() => escolherNoPedido('entrega', 'entrega'));
await c.waitForTimeout(300);
igual('escolhendo Entrega', limpo(await c.textContent('.tempo-pista').catch(() => '')), '🛵 A entrega leva cerca de 40 min.');
await c.evaluate(() => escolherNoPedido('entrega', 'retirada'));
await c.waitForTimeout(300);
igual('escolhendo Retirada', limpo(await c.textContent('.tempo-pista').catch(() => '')), '🛵 Fica pronto em cerca de 40 min.');

secao('3. No acompanhamento: a hora prevista');
const cli = aba();
const p = await cli.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome:'Ana', telefone:'11977776666', entrega:'entrega',
  pagamento:'dinheiro', endereco:{ rua:'Rua A', numero:'1', bairro:'Centro' }, itens:[{ produto: xId, quantidade: 1 }] } });
await c.evaluate(t => abrirAcompanhar(t), p.token);
await c.waitForSelector('.tempo-prev', { timeout: 8000 }).catch(() => {});
const criado = (await um(`select criado_em from public.pedidos where token = $1`, [p.token])).criado_em;
const hora = await c.evaluate(d => new Date(new Date(d).getTime() + 40 * 60000).toLocaleTimeString('pt-BR', { hour:'2-digit', minute:'2-digit' }), criado.toISOString());
igual('"Chega por volta das" + a hora do pedido + 40 min', limpo(await c.textContent('.tempo-prev').catch(() => '')),
  `🛵 Chega por volta das ${hora} (40 min).`);

secao('4. "Outro": o que o dono escrever');
pd.resposta = '1h30';
await pd.click('#pdTempoBarra button:has-text("Outro")');
await pd.waitForTimeout(1200);
igual('grava "1h30"', await tempoNoBanco(), '1h30');
igual('e o botão mostra o que foi escrito', limpo(await pd.textContent('#pdTempoBarra button.btn-p')), '1h30 ✎');
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForTimeout(1500);
await c.evaluate(t => abrirAcompanhar(t), p.token);
await c.waitForSelector('.tempo-prev', { timeout: 8000 }).catch(() => {});
const hora2 = await c.evaluate(d => new Date(new Date(d).getTime() + 90 * 60000).toLocaleTimeString('pt-BR', { hour:'2-digit', minute:'2-digit' }), criado.toISOString());
igual('1h30 vira 90 minutos na hora prevista', limpo(await c.textContent('.tempo-prev').catch(() => '')),
  `🛵 Chega por volta das ${hora2} (1h30).`);

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

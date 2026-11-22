/* ===========================================================================
   PediHub — os entregadores, de ponta a ponta (75_entregadores)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/entregador-tela.test.mjs

   Na Pizzaria da Rosa (entrega a R$ 8 no Centro):
     1. a dona põe os entregadores Lu e Beto, e diz que o motoboy ganha R$ 6
        por entrega mais R$ 20 de diária;
     2. chegam dois pedidos: um em dinheiro (troco para R$ 100), um no Pix;
        ela aceita e, em "Saiu para entrega", escolhe a Lu;
     3. no acerto, "Mandar no WhatsApp" leva o link da Lu;
     4. a Lu abre no celular: as duas entregas, com o endereço, o mapa, o
        WhatsApp do cliente, o que cobrar e o troco; marca "Entregue" — e o
        resumo do dia diz o que ela devolve;
     5. o acerto do painel bate; trocar o link corta o antigo.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import pg from './pg.mjs';

const exigir = createRequire(import.meta.url);
const { chromium, devices } = exigir(process.env.PLAYWRIGHT || 'playwright');
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
// FOTOS=pasta guarda as telas (para mostrar como fica).
const foto = async (pg, nome) => { if(process.env.FOTOS) await pg.screenshot({ path: path.join(process.env.FOTOS, nome + '.png') }); };

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
const dona = aba();
await dona.criarConta({ email:`rosa-${m}@teste.com`, senha:'minhasenhaboa', nome:'Rosa',
  telefone:'+5511' + (910000000 + (Date.now() % 50000000)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao: 'Pizzaria da Rosa ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3253', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
const slug = (await um(`select slug from public.saloes where id = $1`, [salaoId])).slug;
const pizza = (await dona.inserir('produtos', { salaoId, nome:'Pizza', preco:50, custo:0, estoque:0,
  ativo:true, vendaOnline:true })).id;
await dona.atualizar('saloes', salaoId, { cfg:{ pedidos:{ taxas:[{ bairro:'Centro', taxa:8 }] } } });
ok('uma pizzaria com entrega a R$ 8 no Centro');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
async function pagina(url, opcoes, sessao){
  const ctx = await nav.newContext(opcoes);
  const p = await ctx.newPage();
  p.on('pageerror', e => erros.push(e.message));
  p.alertas = [];
  p.on('dialog', x => { p.alertas.push(x.message()); x.accept(); });
  await p.addInitScript(([b, s]) => {
    window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
    if(s && location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
  }, [BASE, sessao || null]);
  await p.goto(url);
  return p;
}

secao('1. A dona põe os entregadores e quanto eles ganham');
const pd = await pagina(BASE + '/app.html', { viewport:{ width:1280, height:1000 } }, dona.sessao());
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 1,
  null, { timeout: 20000 });
await pd.waitForTimeout(800);
await pd.evaluate(() => abrirConfigPedidos());
await pd.waitForSelector('#pcMotoModo');
verdade('"valor por entrega" só aparece no modo fixo', !(await pd.isVisible('#pcMotoValor')));
await pd.fill('#pcEntregadores', 'Lu\nBeto');
await pd.selectOption('#pcMotoModo', 'fixo');
await pd.fill('#pcMotoValor', '6');
await pd.fill('#pcMotoDiaria', '20');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(1500);
const cfg = (await um(`select cfg->'pedidos' p from public.saloes where id = $1`, [salaoId])).p;
igual('gravou: Lu e Beto, R$ 6 por entrega e R$ 20 de diária', [cfg.entregadores, cfg.motoboy],
  [['Lu', 'Beto'], { modo:'fixo', valor:6, diaria:20 }]);

secao('2. Dois pedidos saem com a Lu');
const cli = aba();
const pedir = (tel, pag, troco) => cli.chamar('fazer_pedido', { p_slug: slug, p_pedido: {
  nome:'Maria ' + tel.slice(-2), telefone: tel, entrega:'entrega', pagamento: pag, troco,
  endereco:{ rua:'Rua das Flores', numero: tel.slice(-3), bairro:'Centro', referencia:'portão azul' },
  itens:[{ produto: pizza, quantidade: 1 }] } });
const p1 = await pedir('11910000101', 'dinheiro', '100');
const p2 = await pedir('11910000102', 'pix', null);
await pd.evaluate(() => { irPara('pedidos'); return carregarPedidos(); });
await pd.waitForTimeout(800);
for(const n of [p1.numero, p2.numero]){
  const id = (await um(`select id from public.pedidos where salao_id = $1 and numero = $2`, [salaoId, n])).id;
  const c = pd.locator(`.pedido-cartao[data-pedido="${id}"]`);
  await c.locator('button', { hasText: 'Aceitar' }).click();
  await pd.waitForTimeout(1200);
  await c.locator('button', { hasText: 'Saiu para entrega' }).click();
  await pd.waitForSelector('#modalCorpo button[data-v="Lu"]');
  await pd.click('#modalCorpo button[data-v="Lu"]');
  await pd.waitForTimeout(1500);
}
igual('no banco, os dois a caminho com a Lu', (await banco.query(`select status, entregador from public.pedidos
  where salao_id = $1 order by numero`, [salaoId])).rows.map(r => r.status + ' ' + r.entregador), ['saiu Lu', 'saiu Lu']);

secao('3. O link da Lu, pelo WhatsApp');
await pd.evaluate(() => { window._abertos = []; window.open = u => { window._abertos.push(u); return null; }; });
await pd.click('button:has-text("Entregadores")');
await pd.waitForSelector('#linksEntregadores');
igual('a lista dos links tem os dois', await pd.$$eval('#linksEntregadores [data-entregador]', e => e.map(x => x.dataset.entregador)), ['Lu', 'Beto']);
await pd.click('#linksEntregadores [data-entregador="Lu"] button:has-text("Mandar no WhatsApp")');
await pd.waitForFunction(() => window._abertos.length > 0);
const zap = await pd.evaluate(() => window._abertos[0]);
const texto = decodeURIComponent(zap.replace(/^https:\/\/wa\.me\/\?text=/, ''));
const linkLu = (texto.match(/https?:\/\/\S+entregador\.html\?t=[0-9a-f-]{36}/) || [])[0];
verdade('o WhatsApp abre com o recado e o link', /^Oi, Lu! Este é o seu link de entregas da Pizzaria da Rosa/.test(texto) && !!linkLu, texto);

secao('4. A Lu no celular');
const pe = await pagina(linkLu, { ...devices['Pixel 7'] });
await pe.waitForSelector('.ent-cartao');
igual('o topo: a casa e "Entregas de Lu"', [limpo(await pe.textContent('#entCasa')), limpo(await pe.textContent('#entQuem'))],
  ['Pizzaria da Rosa ' + m, 'Entregas de Lu']);
igual('as duas entregas a caminho', await pe.$$eval('.ent-cartao .ent-cab b', e => e.map(x => x.textContent.trim())),
  [`#${p1.numero} · Maria 01`, `#${p2.numero} · Maria 02`]);
const c1 = `.ent-cartao:has-text("Maria 01")`;
igual('o endereço e a referência', [limpo(await pe.textContent(c1 + ' .ent-end')), limpo(await pe.textContent(c1 + ' .ent-ref'))],
  ['Rua das Flores, 101 · Centro', 'Referência: portão azul']);
igual('em dinheiro: cobrar R$ 58 e levar R$ 42 de troco', limpo(await pe.innerText(c1 + ' .ent-pag')),
  'Cobrar R$ 58,00 em dinheiro O cliente paga com R$ 100,00: leve R$ 42,00 de troco');
igual('no Pix, não cobra', limpo(await pe.textContent('.ent-cartao:has-text("Maria 02") .ent-pag')),
  'Pix — R$ 58,00. Não cobra em dinheiro.');
const links = await pe.$$eval(c1 + ' .ent-botoes a', e => e.map(a => a.textContent.trim() + ' ' + a.getAttribute('href')));
verdade('Google Maps e Waze com o endereço', /^Google Maps https:\/\/www\.google\.com\/maps\/search\/\?api=1&query=Rua%20das%20Flores%2C%20101%2C%20Centro/.test(links[0])
  && /^Waze https:\/\/waze\.com\/ul\?q=Rua%20das%20Flores/.test(links[1]), links.join(' | '));
verdade('WhatsApp do cliente com o recado, e o Ligar', /^WhatsApp https:\/\/wa\.me\/5511910000101\?text=Ol%C3%A1%2C%20Maria!%20Sou%20Lu/.test(links[2])
  && links[3] === 'Ligar tel:+5511910000101', links.join(' | '));
await foto(pe, 'entregador-1-a-caminho');
await pe.click(c1 + ' .ent-entregue');
await pe.waitForTimeout(1500);
igual('ela marcou "Entregue": sobra uma a caminho', await pe.$$eval('.ent-cartao', e => e.length), 1);
const r1 = await um(`select status, comanda_id is not null venda from public.pedidos where salao_id = $1 and numero = $2`, [salaoId, p1.numero]);
igual('no banco: entregue, e já é venda', [r1.status, r1.venda], ['entregue', true]);
igual('o resumo do dia: 1 entrega, R$ 58 em dinheiro, ganha 6 + 20, devolve 32',
  (await pe.$$eval('.ent-hoje div', e => e.map(x => x.innerText))).map(limpo),
  ['Entregas 1', 'Recebeu em dinheiro R$ 58,00', 'Você ganha R$ 26,00', 'Troco que levou R$ 42,00', 'Acerto com o caixa Devolver R$ 32,00']);
await foto(pe, 'entregador-2-resumo');

secao('5. O acerto no painel, e trocar o link');
await pd.click('#modalPe button:has-text("Fechar")');
await pd.click('button:has-text("Entregadores")');
await pd.waitForSelector('#acertoTabela');
igual('Lu: 1 entrega, R$ 58 em dinheiro, ganha R$ 26, devolve R$ 32 (levou R$ 42 de troco)',
  (await pd.$$eval('#acertoTabela tr[data-entregador="Lu"] td', e => e.map(x => x.innerText))).map(limpo),
  ['Lu levou R$ 42,00 de troco', '1', 'R$ 58,00', 'R$ 26,00', 'devolve R$ 32,00']);
await foto(pd, 'entregador-3-acerto');
await pd.click('#linksEntregadores [data-entregador="Lu"] button:has-text("Trocar link")');
await pd.waitForFunction(() => window._abertos.length > 1);
const linkNovo = (decodeURIComponent(await pd.evaluate(() => window._abertos[1])).match(/entregador\.html\?t=[0-9a-f-]{36}/) || [])[0];
verdade('o link novo é outro', !!linkNovo && !linkLu.endsWith(linkNovo), linkNovo);
await pe.reload();
await pe.waitForSelector('.ent-erro');
igual('o link antigo não abre mais', limpo(await pe.textContent('.ent-erro')), 'Este link de entregas não vale mais. Peça um novo ao restaurante.');

igual('nenhum erro de JavaScript', erros, []);
await nav.close(); await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

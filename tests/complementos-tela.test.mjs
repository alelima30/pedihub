/* ===========================================================================
   PediHub — complementos no link do cliente, de ponta a ponta (67)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/complementos-tela.test.mjs

   Uma pizzaria com "Pizza grande" (Sabores: 1 a 2, vale a mais cara;
   Borda: opcional) e um refrigerante simples. No celular, o cliente:
     1. toca em adicionar a pizza e a escolha abre — sem sabor, não entra;
     2. escolhe meio a meio e a borda; a prévia mostra o preço certo;
     3. o refrigerante entra direto, sem folha;
     4. faz o pedido: no BANCO o item tem as opções escritas e o preço da
        regra, e o total bate com o que a tela mostrou.
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
await d.criarConta({ email:`compl-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dona Léo',
  telefone:'+5511' + (930000000 + (Date.now() % 50000000)) });
const cr = await d.chamar('criar_salao', { p_nome_salao: 'Pizzaria Léo ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3251', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, slug = cr[0].slug;
const pizza = (await d.inserir('produtos', { salaoId, nome:'Pizza grande', preco:0, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Pizzas' })).id;
const refri = (await d.inserir('produtos', { salaoId, nome:'Refrigerante', preco:10, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Bebidas' })).id;
await d.chamar('salvar_opcoes_do_produto', { p_produto: pizza, p_grupos: [
  { nome:'Sabores', min:1, max:2, regra:'maior', opcoes:[
    { nome:'Calabresa', preco:'50' }, { nome:'Frango', preco:'55' }, { nome:'Camarão', preco:'80' }] },
  { nome:'Borda', min:0, max:1, regra:'soma', opcoes:[{ nome:'Catupiry', preco:'8' }] }] });
ok('uma pizzaria com a pizza de sabores e borda, e um refrigerante simples');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctx = await nav.newContext({ viewport:{ width:412, height:880 }, isMobile:true, hasTouch:true });
const c = await ctx.newPage();
c.on('pageerror', e => erros.push(e.message));
c.on('dialog', x => x.accept());
await c.goto(BASE + '/agendar.html?salao=' + slug);
await c.waitForFunction(() => typeof salao !== 'undefined' && salao && typeof opcoesCasa !== 'undefined'
  && Object.keys(opcoesCasa).length, null, { timeout: 15000 });
await c.waitForTimeout(800);

secao('1. A pizza abre a escolha');
await c.evaluate(id => mudarNoCarrinho(id, 1), pizza);
await c.waitForSelector('#folhaOpcoesCorpo');
igual('a folha mostra os dois grupos', await c.$$eval('.op-grupo .op-cabeca b', e => e.map(x => x.textContent)),
  ['Sabores', 'Borda']);
await c.click('.op-confirmar');
verdade('sem sabor, não entra no carrinho (e diz o que falta)',
  await c.evaluate(() => itensNoCarrinho() === 0 && !!document.getElementById('opFalta')
    && document.getElementById('opFalta').style.display !== 'none'));

secao('2. Meio a meio e borda');
await c.click('.op-item:has-text("Calabresa")');
await c.click('.op-item:has-text("Camarão")');
await c.click('.op-item:has-text("Frango")');   // terceiro sabor: não entra (máximo 2)
await c.click('.op-item:has-text("Catupiry")');
if(process.env.FOTO) await c.screenshot({ path: process.env.FOTO });
igual('o terceiro sabor não entrou', await c.$$eval('.op-grupo:first-child .op-item.on', e => e.length), 2);
igual('a prévia: vale o Camarão (80) + borda (8) = R$ 88,00',
  limpo(await c.textContent('.op-confirmar')), 'Adicionar · R$ 88,00');
await c.click('.op-confirmar');
await c.waitForTimeout(400);
igual('a pizza entrou como uma linha, com as opções no nome',
  await c.evaluate(() => linhasComOpcoes().map(l => [l.nome, l.preco])),
  [['Pizza grande — Sabores: ½ Calabresa, ½ Camarão · Borda: Catupiry', 88]]);

secao('3. O refrigerante entra direto');
await c.evaluate(id => mudarNoCarrinho(id, 1), refri);
await c.waitForTimeout(300);
verdade('sem folha, e o carrinho soma R$ 98,00',
  await c.evaluate(() => !document.getElementById('folhaOpcoesCorpo') && totalDoCarrinho() === 98));

secao('4. O pedido no banco');
await c.evaluate(() => irPara('pedido'));
await c.waitForTimeout(500);
await c.evaluate(() => { escolherNoPedido('entrega', 'retirada'); escolherNoPedido('pagamento', 'pix');
  anotarPedido('nome', 'Maria'); anotarPedido('tel', '11999887766'); });
await c.evaluate(() => confirmarPedido());
await c.waitForTimeout(1500);
const ped = await um(`select p.total::text total, (select string_agg(i.nome || '|' || i.preco || '|' || i.quantidade, ' ; ' order by i.ordem)
                        from public.pedido_itens i where i.pedido_id = p.id) itens
                        from public.pedidos p where p.salao_id = $1`, [salaoId]);
verdade('o pedido foi gravado', !!ped, 'nenhum pedido no banco');
if(ped){
  igual('o total do banco bate com a tela (88 + 10)', ped.total, '98.00');
  igual('os itens: a pizza com as opções e o preço da regra, e o refri',
    ped.itens, 'Refrigerante|10.00|1 ; Pizza grande — Sabores: ½ Calabresa, ½ Camarão · Borda: Catupiry|88.00|1');
}

igual('nenhum erro de JavaScript na página', erros, []);
await nav.close(); await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

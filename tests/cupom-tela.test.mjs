/* ===========================================================================
   PediHub — o cupom no pedido, de ponta a ponta (34_cupons, 68_cupom_no_pedido)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/cupom-tela.test.mjs

   Na Lanchonete da Bia:
     1. a dona cria o cupom BEMVINDO10 (10%) pela tela de Cupons;
     2. o cliente pede 2 X-Burger (R$ 60) para retirar, escreve o cupom em
        minúsculas e vê o desconto (R$ 6) e o total (R$ 54) antes de confirmar;
     3. confirma: no BANCO o pedido sai com o cupom, o desconto e o total —
        quem calcula é o banco, a tela só mostra;
     4. um código que não existe diz que não vale, e não muda o total.
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
await dona.criarConta({ email:`cupom-${m}@teste.com`, senha:'minhasenhaboa', nome:'Bia',
  telefone:'+5511' + (930000000 + (Date.now() % 50000000)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao: 'Lanchonete da Bia ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3254', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
const slug = (await um(`select slug from public.saloes where id = $1`, [salaoId])).slug;
const burger = (await dona.inserir('produtos', { salaoId, nome:'X-Burger', preco:30, custo:0, estoque:0,
  ativo:true, vendaOnline:true })).id;
ok('uma lanchonete com X-Burger a R$ 30');

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

secao('1. A dona cria o cupom pela tela');
const pd = await pagina(BASE + '/app.html', { viewport:{ width:1280, height:1000 } }, dona.sessao());
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 1,
  null, { timeout: 20000 });
await pd.waitForTimeout(800);
await pd.evaluate(() => irPara('cupons'));
await pd.waitForTimeout(500);
await pd.click('#btNovoCupom');
await pd.waitForSelector('#cpCodigo');
await pd.fill('#cpCodigo', 'BEMVINDO10');
await pd.selectOption('#cpTipo', 'pct');
await pd.fill('#cpValor', '10');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(1500);
const cup = await um(`select codigo, tipo, valor::text, ativo from public.cupons where salao_id = $1`, [salaoId]);
igual('gravou: BEMVINDO10, 10%, ligado', cup && [cup.codigo, cup.tipo, cup.valor, cup.ativo], ['BEMVINDO10', 'pct', '10.00', true]);
verdade('e a lista diz que vale no pedido', /BEMVINDO10[\s\S]*vale no pedido/.test(await pd.innerText('#tela-cupons')),
  limpo(await pd.innerText('#tela-cupons')).slice(0, 200));

secao('2. O cliente aplica o cupom antes de confirmar');
const c = await pagina(`${BASE}/cardapio.html?salao=${slug}`, { ...devices['Pixel 7'] });
await c.waitForTimeout(2500);
await c.click('#btPrincipal'); await c.waitForTimeout(800);
const add = c.locator(`button[onclick*="mudarNoCarrinho('${burger}'"]:visible`).first();
await add.tap(); await c.waitForTimeout(300);
await c.locator(`button[onclick*="mudarNoCarrinho('${burger}',1)"]:visible, button[onclick*="mudarNoCarrinho('${burger}', 1)"]:visible`).first().tap();
await c.waitForTimeout(300);
await c.click('#btPrincipal'); await c.waitForTimeout(800);
await c.fill('#pdNome', 'Carla');
await c.fill('#pdTel', '(11) 97777-1234');
await c.locator('.pd-ops button:has-text("Retirar no local"), .pd-ops label:has-text("Retirar no local")').first().click();
await c.locator('.pd-ops button:has-text("Pix"), .pd-ops label:has-text("Pix")').first().click();
await c.waitForTimeout(300);
await c.fill('#pdCupom', 'naoexiste');
await c.locator('button:has-text("Aplicar")').first().click();
await c.waitForTimeout(1200);
const errado = limpo(await c.innerText('body'));
verdade('um código que não existe diz que não vale', /não (vale|existe|encontr)/i.test(errado) && /R\$ 60,00/.test(errado),
  (errado.match(/.{0,80}(cupom|Cupom).{0,80}/) || [''])[0]);
await c.fill('#pdCupom', 'bemvindo10');
await c.locator('button:has-text("Aplicar")').first().click();
await c.waitForTimeout(1500);
const certo = limpo(await c.innerText('body'));
verdade('o cupom certo mostra o desconto de R$ 6 e o total de R$ 54', /BEMVINDO10/.test(certo) && /6,00/.test(certo) && /R\$ 54,00/.test(certo),
  (certo.match(/.{0,120}54,00.{0,40}/) || [certo.slice(-300)])[0]);
verdade('e o botão de confirmar já diz R$ 54', /54,00/.test(await c.textContent('#btPrincipal')), await c.textContent('#btPrincipal'));

secao('3. Confirmar: o banco grava o cupom e o total');
await c.click('#btPrincipal');
await c.waitForTimeout(2500);
const ped = await um(`select cupom_codigo, desconto::text, subtotal::text, total::text from public.pedidos where salao_id = $1`, [salaoId]);
igual('no banco: BEMVINDO10, desconto 6, subtotal 60, total 54',
  ped && [ped.cupom_codigo, ped.desconto, ped.subtotal, ped.total], ['BEMVINDO10', '6.00', '60.00', '54.00']);
igual('e o uso do cupom foi registrado', Number((await um(`select count(*) n from public.cupom_usos u
  join public.cupons k on k.id = u.cupom_id where k.salao_id = $1`, [salaoId])).n), 1);

igual('nenhum erro de JavaScript', erros, []);
await nav.close(); await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

/* ===========================================================================
   PediHub — a data de nascimento numa lanchonete, de ponta a ponta

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/aniversario-lanchonete.test.mjs

   "Data de nascimento está funcionando?" Numa lanchonete (modo Pedidos):
     1. no link, o cliente cria a conta com o aniversário: a data vai para a
        conta E para a ficha da lanchonete;
     2. o pedido dele, depois, cai na MESMA ficha — a data não se perde;
     3. o painel mostra o aniversariante (aba Aniversariantes e cartão do Hoje);
     4. o dono cadastra um cliente à mão com a data, e ela fica gravada.
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
const data = d => d ? new Date(d).toISOString().slice(0, 10) : null;

const m = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dono = aba();
await dono.criarConta({ email:`niver-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono do Niver',
  telefone:'+5511' + (940000000 + (Date.now() % 30000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Niver ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3270', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Burguer', preco:26, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria:'Lanches' });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3270' });
const xId = (await um(`select id from public.produtos where salao_id = $1`, [salaoId])).id;

/* O aniversário é HOJE (no fuso do restaurante, que na bancada é o de São
   Paulo), num ano qualquer: assim ele aparece no cartão do Hoje também. */
const hojeSP = new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10);
const NASC = '1992' + hojeSP.slice(4);
const telCli = '119' + String(70000000 + (Date.now() % 9999999)).padStart(8, '0');
const telFmt = `(${telCli.slice(0, 2)}) ${telCli.slice(2, 7)}-${telCli.slice(7)}`;

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

secao('1. No link: criar conta com o aniversário');
const c = await (await nav.newContext({ viewport:{ width:412, height:870 }, isMobile:true, hasTouch:true })).newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
c.on('dialog', x => x.accept());
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForFunction(() => typeof abrirConta === 'function' && typeof salao !== 'undefined' && salao, null, { timeout: 15000 });
await c.evaluate(() => abrirConta('criar'));
await c.waitForSelector('#cNasc', { state: 'visible' });
await c.fill('#cNome', 'Bruna Aniversário');
await c.fill('#cTel', telFmt);
await c.fill('#cEmail', `bruna-${m}@teste.com`);
await c.fill('#cSenha', 'senhadabruna1');
// Sem aniversário: a tela pede.
await c.evaluate(() => criarContaCliente());
await c.waitForTimeout(400);
verdade('sem a data, a tela pede o aniversário', /anivers/i.test(limpo(await c.textContent('#avisoConta'))),
  limpo(await c.textContent('#avisoConta')));
// Data no futuro: recusa.
await c.fill('#cNasc', '2099-01-01');
await c.evaluate(() => criarContaCliente());
await c.waitForTimeout(400);
verdade('data no futuro é recusada', /ainda não chegou/i.test(limpo(await c.textContent('#avisoConta'))),
  limpo(await c.textContent('#avisoConta')));
await c.fill('#cNasc', NASC);
await c.evaluate(() => criarContaCliente());
await c.waitForTimeout(3500);
const perfil = await um(`select nascimento from public.perfis where email = $1`, [`bruna-${m}@teste.com`]);
igual('a conta guarda a data', data(perfil && perfil.nascimento), NASC);
const ficha = await um(`select id, nascimento, telefone from public.clientes where salao_id = $1 and nome = 'Bruna Aniversário'`, [salaoId]);
verdade('a lanchonete ganha a ficha dela na hora', !!ficha);
igual('com a data de nascimento', data(ficha && ficha.nascimento), NASC);

secao('2. O pedido dela cai na mesma ficha');
const cli = aba();
const p = await cli.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome:'Bruna Aniversário', telefone: telCli,
  entrega:'retirada', pagamento:'dinheiro', itens:[{ produto: xId, quantidade: 1 }] } });
const ped = await um(`select id from public.pedidos where token = $1`, [p.token]);
for(const st of ['em_preparo', 'pronto', 'entregue'])
  await dono.chamar('mudar_status_pedido', { p_pedido: ped.id, p_status: st });
const fim = await um(`select status, cliente_id from public.pedidos where id = $1`, [ped.id]);
igual('o pedido foi entregue', fim.status, 'entregue');
igual('e ficou na ficha dela (a que tem a data)', fim.cliente_id, ficha && ficha.id);
const depois = await um(`select count(*)::int n, max(nascimento)::text nasc from public.clientes
  where salao_id = $1 and regexp_replace(coalesce(telefone,''), '\\D', '', 'g') like '%' || $2`, [salaoId, telCli.slice(-8)]);
igual('continua uma ficha só para o telefone dela', depois.n, 1);
igual('e a data continua lá', depois.nasc, NASC);

secao('3. No painel: Aniversariantes e o cartão do Hoje');
const pd = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
pd.on('pageerror', e => erros.push('painel: ' + e.message));
pd.on('dialog', x => x.accept());
await pd.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await pd.goto(BASE + '/app.html');
await pd.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.clientes)
  && bd.clientes.some(c => c.nome === 'Bruna Aniversário'), null, { timeout: 20000 });
await pd.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); irPara('aniversarios'); });
await pd.waitForTimeout(800);
verdade('a aba Aniversariantes mostra a Bruna', /Bruna/.test(limpo(await pd.textContent('#listaNiver').catch(() => ''))),
  limpo(await pd.textContent('#listaNiver').catch(() => '')));
await pd.evaluate(() => irPara('hoje'));
await pd.waitForTimeout(800);
verdade('e o Hoje lembra do aniversário', /Bruna/.test(limpo(await pd.textContent('main').catch(() => ''))));

secao('4. O dono cadastra um cliente à mão com a data');
await pd.evaluate(() => { irPara('clientes'); abrirCliente(); });
await pd.waitForSelector('#kNasc');
await pd.fill('#kNome', 'Carlos do Balcão');
await pd.fill('#kTel', '(11) 97777-' + String(1000 + (Date.now() % 8999)));
await pd.fill('#kNasc', '1985-03-09');
await pd.evaluate(() => salvarCliente());
await pd.waitForTimeout(2500);
const carlos = await um(`select nascimento from public.clientes where salao_id = $1 and nome = 'Carlos do Balcão'`, [salaoId]);
igual('a data entra no banco', data(carlos && carlos.nascimento), '1985-03-09');
await pd.evaluate(() => { irPara('aniversarios'); escolherMesNiver(3); });
await pd.waitForTimeout(500);
verdade('e ele aparece em Aniversariantes de março', /Carlos/.test(limpo(await pd.textContent('#listaNiver').catch(() => ''))),
  limpo(await pd.textContent('#listaNiver').catch(() => '')));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

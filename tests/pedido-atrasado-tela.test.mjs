/* ===========================================================================
   PediHub — o pedido atrasado pelo tempo de entrega

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/pedido-atrasado-tela.test.mjs

   "Se o tempo de entrega é de 1h, tem que aparecer que está atrasada a
   entrega." Com o tempo de entrega em "1 hora":
     1. pedido de 70 min, em preparo: "⏰ ATRASADO 10 min", cartão em vermelho
        e a linha "o prometido era até HH:MM (1 hora)";
     2. saiu para entrega há 2 h 5 min: "ATRASADO 1 h 5 min";
     3. pedido de 55 min: "⏳ vence em 5 min";
     4. pedido de 10 min: só "Prometido ao cliente até HH:MM";
     5. retirada pronta há 90 min: sem prazo (está cumprido);
     6. o aviso no alto: "2 pedidos atrasados";
     7. sem tempo de entrega escolhido, nada disso aparece.
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

const m = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dono = aba();
await dono.criarConta({ email:`atraso-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono do Atraso',
  telefone:'+5511' + (990000000 + (Date.now() % 9000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Atraso ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3320', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
await dono.inserir('produtos', { salaoId, nome:'X-Bacon', preco:30, custo:0, estoque:0, ativo:true, vendaOnline:true });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3320', cfg:{ pedidos:{ tempo:'1 hora' } } });
const xId = (await dono.lista('produtos', { salaoId }))[0].id;

// Cada pedido lançado no balcão (já nasce em preparo), com a idade e a etapa da cena.
async function pedido(nome, entrega, minutos, etapas){
  const r = await dono.chamar('lancar_pedido', { p_salao: salaoId, p_pedido: { origem:'telefone', nome,
    telefone:'1197700' + String(3000 + Math.floor(Math.random() * 6999)), entrega, pagamento:'dinheiro',
    endereco: entrega === 'entrega' ? { rua:'Rua A', numero:'1', bairro:'Centro' } : null,
    itens:[{ produto: xId, quantidade: 1 }] } });
  const id = (await banco.query(`select id from public.pedidos where salao_id = $1 and nome = $2`, [salaoId, nome])).rows[0].id;
  for(const st of etapas || []) await dono.chamar('mudar_status_pedido', { p_pedido: id, p_status: st });
  await banco.query(`update public.pedidos set criado_em = now() - make_interval(mins => $2) where id = $1`, [id, minutos]);
  return r;
}
await pedido('Ana Setenta', 'entrega', 70);
await pedido('Beto Saiu', 'entrega', 125, ['saiu']);
await pedido('Caio Quase', 'entrega', 55);
await pedido('Duda Novo', 'entrega', 10);
await pedido('Edu Retira', 'retirada', 90, ['pronto']);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const p = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
p.on('pageerror', e => erros.push(e.message));
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await p.goto(BASE + '/app.html');
await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 1, null, { timeout: 20000 });
await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); window.tocarSomDePedido = () => {}; irPara('pedidos'); });
await p.waitForTimeout(500);
await p.evaluate(() => carregarPedidos());
await p.waitForSelector('.pedido-cartao');
const cartao = nome => p.evaluate(n => {
  const c = [...document.querySelectorAll('.pedido-cartao')].find(x => x.textContent.includes(n));
  if(!c) return null;
  const t = c.querySelector('.t-fora-do-prazo, .t-vence');
  const l = c.querySelector('.pedido-prazo');
  return { tag: t ? t.textContent.trim() : '', linha: l ? l.textContent.replace(/\s+/g, ' ').trim() : '',
           vermelho: c.classList.contains('pedido-fora-do-prazo') };
}, nome);

secao('1. 70 minutos, em preparo: atrasado 10 min');
if(process.env.SAIDA){
  await p.evaluate(() => document.querySelector('.pedido-aviso-prazo').scrollIntoView({ block: 'start' }));
  await p.waitForTimeout(300);
  await p.screenshot({ path: process.env.SAIDA + '/pedido-atrasado.png' });
}
const a = await cartao('Ana Setenta');
igual('a etiqueta', a.tag, '⏰ ATRASADO 10 min');
verdade('o cartão em vermelho', a.vermelho);
verdade('e a linha com a hora prometida', /Atrasado 10 min — o prometido ao cliente era até \d\d:\d\d \(1 hora\)/.test(a.linha), a.linha);

secao('2. Saiu para entrega há 2 h 5 min');
igual('"ATRASADO 1 h 5 min"', (await cartao('Beto Saiu')).tag, '⏰ ATRASADO 1 h 5 min');

secao('3. 55 minutos: vence em 5');
const c = await cartao('Caio Quase');
igual('"vence em 5 min"', c.tag, '⏳ vence em 5 min');
igual('e ainda não está em vermelho', c.vermelho, false);

secao('4. 10 minutos: só o prometido');
const d = await cartao('Duda Novo');
igual('sem etiqueta', d.tag, '');
verdade('"Prometido ao cliente até HH:MM (1 hora)"', /^🕙 Prometido ao cliente até \d\d:\d\d \(1 hora\)\.$/.test(d.linha), d.linha);

secao('5. Retirada pronta: o prazo foi cumprido');
igual('sem prazo nenhum', await cartao('Edu Retira'), { tag: '', linha: '', vermelho: false });

secao('6. O aviso no alto da tela');
verdade('"2 pedidos atrasados"', /2 pedidos atrasados — passaram do tempo de entrega \(1 hora\)/.test(
  limpo(await p.textContent('.pedido-aviso-prazo').catch(() => ''))), limpo(await p.textContent('.pedido-aviso-prazo').catch(() => '')));

secao('7. Sem tempo de entrega escolhido');
await p.evaluate(() => { escolherTempoEntrega(''); desenharPedidos(); });
await p.waitForTimeout(800);
igual('nenhuma etiqueta de prazo', await p.$$eval('.t-fora-do-prazo, .t-vence, .pedido-prazo', e => e.length), 0);
igual('nem o aviso', await p.$('.pedido-aviso-prazo') ? 'tem' : 'não tem', 'não tem');

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

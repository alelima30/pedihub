/* ===========================================================================
   PediHub — os aniversariantes na tela de Pedidos

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/pedido-aniversario-tela.test.mjs

   "Caso tenha aniversariante, é bom aparecer na tela de pedidos dizendo: há um
   aniversariante essa semana, ou hoje, ou amanhã." Com fichas que fazem
   aniversário hoje, amanhã, daqui a 4 dias, daqui a 10 e ontem:
     1. o aviso no alto: "Tem aniversariante hoje!", com hoje, amanhã e o de
        daqui a 4 dias (o de 10 dias e o de ontem, não), e "Dar os parabéns"
        só no de hoje;
     2. no cartão do pedido de quem faz aniversário: "🎂 Aniversário hoje" em
        destaque, ou o dia; quem não tem ficha com data, nada;
     3. "Ocultar hoje" esconde o aviso, e ele continua escondido ao abrir de
        novo (o selo do cartão fica);
     4. sem ninguém hoje: "Tem aniversariante amanhã"; só na semana: "Tem
        aniversariante nesta semana"; ninguém: nenhum aviso;
     5. "Ver aniversariantes" leva à tela dos aniversariantes.
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

// O "hoje" do restaurante (São Paulo), e não o da máquina de teste.
const HOJE = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Sao_Paulo' });
const maisDias = (iso, n) => {
  const [a, m, d] = iso.split('-').map(Number);
  return new Date(Date.UTC(a, m - 1, d + n)).toISOString().slice(0, 10);
};
// Mesmo dia e mês, `anos` anos para trás (29/02 não entra: o teste quer a data exata).
const nasceu = (iso, anos) => (Number(iso.slice(0, 4)) - anos) + iso.slice(4);

const m = Date.now().toString(36) + Math.floor(Math.random()*1000);
const sufixo = String(Date.now() % 9000 + 1000);
const dono = aba();
await dono.criarConta({ email:`niverped-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono do Niver',
  telefone:'+5511' + (970000000 + (Date.now() % 9000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Niver ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3330', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
await dono.inserir('produtos', { salaoId, nome:'X-Salada', preco:25, custo:0, estoque:0, ativo:true, vendaOnline:true });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3330' });
const xId = (await dono.lista('produtos', { salaoId }))[0].id;

const fichas = {
  ana:  { nome:'Ana Hoje',     telefone:'119770' + sufixo + '1', nascimento: nasceu(HOJE, 30) },
  beto: { nome:'Beto Amanhã',  telefone:'119770' + sufixo + '2', nascimento: nasceu(maisDias(HOJE, 1), 25) },
  caio: { nome:'Caio Semana',  telefone:'119770' + sufixo + '3', nascimento: nasceu(maisDias(HOJE, 4), 40) },
  duda: { nome:'Duda Longe',   telefone:'119770' + sufixo + '4', nascimento: nasceu(maisDias(HOJE, 10), 22) },
  edu:  { nome:'Edu Ontem',    telefone:'119770' + sufixo + '5', nascimento: nasceu(maisDias(HOJE, -1), 33) },
};
for(const f of Object.values(fichas)) f.id = (await dono.inserir('clientes', { salaoId, ...f })).id;

async function pedido(nome, telefone){
  return dono.chamar('lancar_pedido', { p_salao: salaoId, p_pedido: { origem:'telefone', nome, telefone,
    entrega:'retirada', pagamento:'dinheiro', itens:[{ produto: xId, quantidade: 1 }] } });
}
await pedido('Ana Hoje', fichas.ana.telefone);
await pedido('Caio Semana', '55' + fichas.caio.telefone);   // com o 55 na frente: acha igual
await pedido('Fábio Sem Ficha', '119770' + sufixo + '9');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctx = await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true });
const p = await ctx.newPage();
p.on('pageerror', e => erros.push(e.message));
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html') && !localStorage.getItem('pedihub.sessao'))
    localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
async function abrirPedidos(){
  await p.goto(BASE + '/app.html');
  await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.clientes) && bd.clientes.length >= 5,
    null, { timeout: 20000 });
  await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); window.tocarSomDePedido = () => {}; irPara('pedidos'); });
  await p.waitForTimeout(400);
  await p.evaluate(() => carregarPedidos());
  await p.waitForSelector('.pedido-cartao');
}
await abrirPedidos();

const aviso = () => p.evaluate(() => {
  const a = document.getElementById('pedidoNiver');
  if(!a) return null;
  return { titulo: a.querySelector('.pedido-niver-tit').textContent.replace(/\s+/g, ' ').trim(),
           linhas: [...a.querySelectorAll('.niver-linha')].map(l => ({
             quem: l.querySelector('.niver-quem b').textContent.trim(),
             quando: l.querySelector('.niver-quando').textContent.replace(/\s+/g, ' ').trim(),
             parabens: !!l.querySelector('button') })) };
});
const selo = nome => p.evaluate(n => {
  const c = [...document.querySelectorAll('.pedido-cartao')].find(x => x.textContent.includes(n));
  const t = c && c.querySelector('.t-niver');
  return t ? { texto: t.textContent.trim(), hoje: t.classList.contains('t-niver-hoje') } : null;
}, nome);

secao('1. O aviso no alto da tela de Pedidos');
const a1 = await aviso();
if(process.env.SAIDA){
  await p.evaluate(() => document.getElementById('pedidoNiver').scrollIntoView({ block: 'start' }));
  await p.waitForTimeout(300);
  await p.screenshot({ path: process.env.SAIDA + '/pedido-aniversario.png' });
}
igual('"Tem aniversariante hoje!"', a1 && a1.titulo, '🎂 Tem aniversariante hoje!');
igual('hoje, amanhã e o de daqui a 4 dias (nem o de 10 dias, nem o de ontem)',
  a1 && a1.linhas.map(l => l.quem), ['Ana Hoje', 'Beto Amanhã', 'Caio Semana']);
igual('Ana: "hoje · faz 30 anos"', a1 && a1.linhas[0].quando, 'hoje · faz 30 anos');
igual('Beto: "amanhã"', a1 && a1.linhas[1].quando.split(' · ')[0], 'amanhã');
verdade('Caio: o dia da semana e a data', a1 && /^[a-záéíóúç]{3}, \d\d\/\d\d/.test(a1.linhas[2].quando), a1 && a1.linhas[2].quando);
igual('"Dar os parabéns" só no de hoje', a1 && a1.linhas.map(l => l.parabens), [true, false, false]);

secao('2. O selo no cartão do pedido');
igual('Ana: "🎂 Aniversário hoje", em destaque', await selo('Ana Hoje'), { texto: '🎂 Aniversário hoje', hoje: true });
const sc = await selo('Caio Semana');
verdade('Caio (pediu com o 55 na frente): "🎂 Aniversário" e o dia', sc && /^🎂 Aniversário [a-záéíóúç]{3}, \d\d\/\d\d$/.test(sc.texto) && !sc.hoje, JSON.stringify(sc));
igual('Fábio, sem ficha com data: nada', await selo('Fábio Sem Ficha'), null);

secao('3. "Ocultar hoje"');
await p.click('#pedidoNiver button:has-text("Ocultar hoje")');
await p.waitForTimeout(300);
igual('o aviso some', await aviso(), null);
verdade('o selo do cartão fica', !!(await selo('Ana Hoje')));
await abrirPedidos();
igual('e continua escondido ao abrir de novo', await aviso(), null);

secao('4. Hoje, amanhã, a semana e ninguém');
const tituloCom = async semData => p.evaluate(nomes => {
  localStorage.removeItem(chaveNiverOculto());
  for(const c of bd.clientes) if(nomes.includes(c.nome)) c.nascimento = null;
  desenharPedidos();
  const a = document.getElementById('pedidoNiver');
  return a ? a.querySelector('.pedido-niver-tit').textContent.replace(/\s+/g, ' ').trim() : null;
}, semData);
igual('sem ninguém hoje: "Tem aniversariante amanhã"', await tituloCom(['Ana Hoje']), '🎂 Tem aniversariante amanhã');
igual('só na semana: "Tem aniversariante nesta semana"', await tituloCom(['Beto Amanhã']), '🎂 Tem aniversariante nesta semana');
igual('ninguém: nenhum aviso', await tituloCom(['Caio Semana']), null);

secao('5. "Ver aniversariantes"');
await p.evaluate(() => {   // a Ana volta a fazer aniversário hoje, para o aviso voltar
  bd.clientes.find(x => x.nome === 'Ana Hoje').nascimento = '1995' + hoje().slice(4);
  desenharPedidos(); });
await p.click('#pedidoNiver button:has-text("Ver aniversariantes")');
await p.waitForTimeout(400);
igual('abre a tela dos aniversariantes', await p.evaluate(() => telaAtual), 'aniversarios');

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

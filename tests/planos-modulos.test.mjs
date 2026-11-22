/* ===========================================================================
   PediHub — os planos do PediHub, cobrados pelo banco e pela tela (22_cotas, 66, 76)

     bash tests/bancada/subir.sh
     PLAYWRIGHT=… node tests/planos-modulos.test.mjs

   ── OS PLANOS ──────────────────────────────────────────────────────────────
     Grátis        até 50 pedidos no mês pelo link, 40 itens no cardápio,
                   300 clientes; sem caixa, relatórios, cupons, aparência e
                   mensagens; o link sai simples (com o selo)
     Essencial     R$ 69,90 — tudo, sem mensagens automáticas
     Profissional  R$ 119,90 — o Essencial + 1.000 mensagens e o Crediário
     Os planos que vieram do AgendaPro (Básico, Dupla, Equipe, Restaurante)
     estão desligados e não se vendem (76).

   ── O QUE ESTE ARQUIVO PROTEGE ─────────────────────────────────────────────
     1. O BANCO recusa cada módulo no Grátis — pelo caminho que o console
        usaria, não pelo botão — e diz "a partir do plano Essencial".
     2. O Essencial usa todos, e não manda mensagem automática.
     3. O link do Grátis sai simples (sem a aparência guardada) e com o selo;
        a personalização continua guardada para quando assinar.
     4. A tela: cadeado nas abas, aviso no lugar do módulo, os três planos.
   =========================================================================== */
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import pg from './pg.mjs';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let passou = 0, falhou = 0;
const ok  = m => { console.log('  ✓ ' + m); passou++; };
const nao = (m, d) => { console.log('  ✗ ' + m + (d ? '\n      ' + d : '')); falhou++; };
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const igual = (m, a, b) => JSON.stringify(a) === JSON.stringify(b) ? ok(m)
  : nao(m, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const secao = t => console.log('\n' + t);

function novaAba(){
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
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
const um = async (sql, args = []) => (await banco.query(sql, args)).rows[0];
const recusa = async (sql, args = []) => {
  try{ await banco.query(sql, args); return null; }
  catch(e){ return e.message; }
};

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const tel = () => '+5511' + (100000000 + Math.floor(Math.random()*89999999));

async function montar(nome, plano){
  const d = novaAba();
  await d.criarConta({ email:`pm-${nome}-${marca}@teste.com`, senha:'minhasenhaboa',
    nome:'Dona ' + nome, telefone: tel() });
  const cr = await d.chamar('criar_salao', { p_nome_salao:'Restaurante ' + nome + ' ' + marca,
    p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
  const salao = cr[0].salao_id;
  const slug = (await um(`select slug from public.saloes where id=$1`, [salao])).slug;
  const cli = (await um(`insert into public.clientes (salao_id, nome, telefone)
                          values ($1, 'Cliente ' || $2, '1197777' || lpad((random()*9999)::int::text, 4, '0'))
                          returning id`, [salao, nome])).id;
  return { d, salao, slug, cli, plano: async (p) => banco.query(
    `update public.assinaturas set plano=$2, status='ativa', vence_em = current_date + 30
      where salao_id=$1`, [salao, p]) };
}

/* ══════════════════════════════════════════════════════════════════════════
   0 — OS NÚMEROS
   ══════════════════════════════════════════════════════════════════════════ */
secao('0) Os planos');
const pl = Object.fromEntries((await banco.query(
  `select codigo, preco_mes, recursos, ativo from public.planos`)).rows.map(r => [r.codigo, r]));
igual('à venda: Grátis, Essencial a R$ 69,90 e Profissional a R$ 119,90',
  Object.values(pl).filter(p => p.ativo && p.codigo !== 'trial').map(p => p.codigo + ' ' + Number(p.preco_mes)).sort(),
  ['gratuito 0', 'individual 69.9', 'time 119.9']);
igual('os planos do AgendaPro estão desligados', ['basico', 'duo', 'equipe', 'salao'].map(k => pl[k] ? pl[k].ativo : false),
  [false, false, false, false]);
const g = pl.gratuito.recursos;
igual('Grátis: 50 pedidos no mês, 40 itens, 300 clientes, 0 mensagem',
  [g.pedidos_mes, g.max_produtos, g.max_clientes, g.mensagens_mes], [50, 40, 300, 0]);
igual('Grátis: com cardápio no link, sem caixa, relatórios, cupons e aparência',
  ['loja','caixa','relatorios','cupons','aparencia'].map(k => g[k]), [true,false,false,false,false]);
igual('Essencial: com todos os módulos, sem mensagens',
  ['loja','caixa','relatorios','cupons','aparencia'].map(k => pl.individual.recursos[k]).concat(Number(pl.individual.recursos.mensagens_mes)),
  [true,true,true,true,true,0]);
igual('Profissional: 1.000 mensagens e o Crediário',
  [Number(pl.time.recursos.mensagens_mes), pl.time.recursos.crediario], [1000, true]);

/* ══════════════════════════════════════════════════════════════════════════
   1 — O GRÁTIS, RECUSADO PELO BANCO
   ══════════════════════════════════════════════════════════════════════════ */
secao('1) No Grátis, o banco recusa cada módulo');
const G = await montar('Gratis');
// Enquanto ainda está no teste (tudo liberado), monta o que vai ficar guardado.
await banco.query(`update public.saloes set cfg = coalesce(cfg,'{}'::jsonb)
  || '{"cor":"#123456","tema":"escuro","fundo":"x"}'::jsonb where id=$1`, [G.salao]);
await banco.query(`insert into public.cupons (salao_id, codigo, valor) values ($1, 'ANTIGO10', 10)`, [G.salao]);
await G.plano('gratuito');

const ESSENCIAL = /a partir do plano Essencial/;
let r;
r = await recusa(`insert into public.caixas (salao_id) values ($1)`, [G.salao]);
verdade('abrir caixa: recusado, "a partir do plano Essencial"', r && ESSENCIAL.test(r), String(r));
r = await G.d.chamar('relatorio', { p_salao: G.salao, p_de: '2026-01-01', p_ate: '2026-12-31' })
  .then(() => null).catch(e => e.message);
verdade('relatório, pela sessão do dono: recusado', r && ESSENCIAL.test(r), String(r));
r = await recusa(`insert into public.cupons (salao_id, codigo, valor) values ($1, 'NOVO10', 10)`, [G.salao]);
verdade('criar cupom: recusado', r && ESSENCIAL.test(r), String(r));
igual('o link nem mostra campo de cupom (o antigo não vale)',
  (await um(`select public.casa_tem_cupom($1) as t`, [G.slug])).t, false);
verdade('comanda e caixa desligados, mesmo com o interruptor ligado',
  (await um(`select public.usa_comanda($1) as u`, [G.salao])).u === false);
const prodJa = Number((await um(`select count(*) as n from public.produtos where salao_id=$1`, [G.salao])).n);
await banco.query(`insert into public.produtos (salao_id, nome, preco, ativo)
  select $1, 'Item ' || g, 10, true from generate_series(1, $2::int) g`, [G.salao, 40 - prodJa]);
r = await recusa(`insert into public.produtos (salao_id, nome, preco, ativo) values ($1, 'O 41º', 10, true)`, [G.salao]);
verdade('o 41º item do cardápio: recusado', !!r, String(r));
const cliJa = Number((await um(`select count(*) as n from public.clientes where salao_id=$1`, [G.salao])).n);
await banco.query(`insert into public.clientes (salao_id, nome)
  select $1, 'Extra ' || g from generate_series(1, $2::int) g`, [G.salao, 300 - cliJa]);
r = await recusa(`insert into public.clientes (salao_id, nome) values ($1, 'O 301º')`, [G.salao]);
verdade('o 301º cliente: recusado', !!r, String(r));
igual('e nenhuma mensagem automática', (await um(`select public.pode_enviar($1) as p`, [G.salao])).p, false);

secao('2) O link do Grátis é o simples');
const vg = (await um(`select public.vitrine($1) as v`, [G.slug])).v;
igual('sem a cor e o tema guardados', [vg.salao.cor, vg.salao.tema], [null, null]);
igual('com o selo "Feito com PediHub"', vg.salao.selo, true);
igual('o cardápio continua no link', (await um(`select public.pedidos_da_casa($1) as c`, [G.slug])).c.ligado, true);
const cfgG = (await um(`select cfg from public.saloes where id=$1`, [G.salao])).cfg;
igual('e a aparência continua guardada no restaurante', [cfgG.cor, cfgG.tema], ['#123456', 'escuro']);

/* ══════════════════════════════════════════════════════════════════════════
   3 — O ESSENCIAL USA TUDO, MENOS MENSAGEM
   ══════════════════════════════════════════════════════════════════════════ */
secao('3) O Essencial usa todos os módulos, sem mensagem automática');
await G.plano('individual');
r = await recusa(`insert into public.caixas (salao_id) values ($1)`, [G.salao]);
igual('abrir caixa: aceito', r, null);
r = await G.d.chamar('relatorio', { p_salao: G.salao, p_de: '2026-01-01', p_ate: '2026-12-31' })
  .then(() => null).catch(e => e.message);
igual('relatório: aceito', r, null);
igual('criar cupom: aceito',
  await recusa(`insert into public.cupons (salao_id, codigo, valor) values ($1, 'ESSENCIAL10', 10)`, [G.salao]), null);
igual('o link volta a ter cupom', (await um(`select public.casa_tem_cupom($1) as t`, [G.slug])).t, true);
verdade('comanda e caixa ligados', (await um(`select public.usa_comanda($1) as u`, [G.salao])).u === true);
const vb = (await um(`select public.vitrine($1) as v`, [G.slug])).v;
igual('o link volta com a aparência guardada, sem selo', [vb.salao.cor, vb.salao.selo], ['#123456', false]);
igual('mensagem automática: nenhuma (franquia 0)',
  [Number((await um(`select public.teto_mensagens($1) as t`, [G.salao])).t),
   (await um(`select public.pode_enviar($1) as p`, [G.salao])).p], [0, false]);

/* A assinatura só o gestor lê; a equipe pergunta o plano por `plano_do_salao`
   — só o código, e só do restaurante onde trabalha. Sem isto a tela dela
   achava que era o Grátis e trancava o caixa de quem paga. */
secao('3b) A equipe sabe o plano, e só o do próprio restaurante');
igual('quem é do restaurante: recebe o código do plano',
  await G.d.chamar('plano_do_salao', { p_salao: G.salao }), 'individual');
const F = await montar('Fora');
igual('quem é de outro restaurante: não recebe nada',
  await F.d.chamar('plano_do_salao', { p_salao: G.salao }), null);
r = await novaAba().chamar('plano_do_salao', { p_salao: G.salao })
  .then(v => 'respondeu ' + JSON.stringify(v)).catch(() => null);
igual('sem login: nem chega a perguntar', r, null);

/* ══════════════════════════════════════════════════════════════════════════
   4 — A TELA
   ══════════════════════════════════════════════════════════════════════════ */
secao('4) A tela: cadeado, aviso e os três planos');
const T = await montar('Tela');
await T.plano('gratuito');
const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const abrir = async (sessao, sufixo = '') => {
  const p = await (await nav.newContext({ viewport:{ width:1360, height:900 } })).newPage();
  p.on('pageerror', e => erros.push(e.message));
  p.on('dialog', d => d.accept());
  await p.addInitScript(([b, s]) => {
    window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
    localStorage.setItem('pedihub.sessao', JSON.stringify(s));
  }, [BASE, sessao]);
  await p.goto(BASE + '/app.html' + sufixo);
  await p.waitForTimeout(3500);
  await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); });
  await p.waitForTimeout(600);
  return p;
};
const pg1 = await abrir(T.d.sessao(), '?oferta=1');
const cadeados = await pg1.evaluate(() =>
  [...document.querySelectorAll('#abas .aba.aba-travada')].map(b => b.dataset.chave).sort());
igual('Grátis: cadeado em Cupons e Relatórios (o Cardápio e os Pedidos ficam abertos)', cadeados, ['cupons', 'relatorios']);
const telaTravada = async (p, k) => {
  await p.evaluate(k => irPara(k), k);
  await p.waitForTimeout(700);
  return p.evaluate(k => {
    const t = document.getElementById('tela-' + k);
    const av = t.querySelector(':scope > .trava-plano');
    return { travada: t.classList.contains('travada'), texto: av ? av.innerText : '' };
  }, k);
};
for(const k of ['relatorios', 'cupons']){
  const t = await telaTravada(pg1, k);
  verdade(`${k}: abre no aviso "a partir do plano Essencial", sem falar de agenda`,
    t.travada && /plano Essencial/.test(t.texto) && !/agenda|Básico/i.test(t.texto), JSON.stringify(t));
}
await pg1.evaluate(() => { irPara('salao'); });
await pg1.waitForTimeout(800);
await pg1.evaluate(() => trocarAbaSalao('aparencia'));
await pg1.waitForTimeout(500);
const apar = await pg1.evaluate(() => {
  const t = document.querySelector('#painelSalao .sub-tela[data-sub="aparencia"]');
  return { travada: t && t.classList.contains('travada'),
           texto: (t && t.querySelector('.trava-plano') || {}).innerText || '' };
});
verdade('Aparência do link: travada, com o aviso', apar.travada && /Aparência do link/.test(apar.texto), JSON.stringify(apar));
verdade('a aba Caixa não aparece (sem comanda no Grátis)',
  !(await pg1.evaluate(() => !!document.querySelector('#abas .aba[data-chave="caixa"]'))));

await pg1.evaluate(() => irPara('plano'));
await pg1.waitForFunction(() => /119,90/.test((document.getElementById('tela-plano') || {}).innerText || ''), null, { timeout: 8000 }).catch(() => {});
const planoTxt = await pg1.evaluate(() => (document.getElementById('tela-plano') || {}).innerText || '');
verdade('tela do Plano: Essencial e o Profissional recomendado, a R$ 119,90',
  /Essencial/.test(planoTxt) && /PLANO RECOMENDADO\s*Profissional/.test(planoTxt) && /119,90/.test(planoTxt), planoTxt.slice(0, 400));
verdade('o uso do plano fala de itens do cardápio, e não de serviços',
  /Itens no cardápio/.test(planoTxt) && !/Serviços no cardápio/.test(planoTxt), planoTxt.slice(0, 400));
verdade('e nenhum plano do AgendaPro', !/Básico|Dupla|49,90/.test(planoTxt), planoTxt.slice(0, 400));

await T.plano('individual');
const pg2 = await abrir(T.d.sessao());
igual('Essencial: nenhum cadeado', await pg2.evaluate(() =>
  document.querySelectorAll('#abas .aba.aba-travada').length), 0);
const tb = await telaTravada(pg2, 'relatorios');
verdade('Essencial: Relatórios abre normal', !tb.travada, JSON.stringify(tb));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();

await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} verificações dos planos${
  falhou ? `, ${falhou} falharam` : ''}.`);
process.exit(falhou ? 1 : 0);

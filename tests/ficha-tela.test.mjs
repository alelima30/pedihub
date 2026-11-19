/* ═══════════════════════════════════════════════════════════════════════════
   A FICHA DO SERVIÇO NA TELA (62_ficha_servico.sql)

     1. no painel, o serviço ganha "Explicação para a cliente"; o modelo pronto
        preenche os campos, e salvar grava a ficha no banco;
     2. salvar um serviço sem ficha não grava nada (continua nulo);
     3. no link (celular): o botão "Como funciona", o convite "Primeira vez
        aqui?" e o "Ver o que está incluso" no cartão;
     4. a ficha abre por cima, sem escolher o serviço; as dúvidas abrem;
     5. comparar os dois lado a lado; agendar pela ficha leva à escolha;
     6. o texto do dono é escapado; nada vaza da tela em 360px;
     7. sem ficha nenhuma, a página é a de sempre;
     8. no passo a passo, o cartão oferece os modelos e não passa por cima
        do que a dona já escreveu.
   ═══════════════════════════════════════════════════════════════════════════ */
import fs from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from './pg.mjs';

const exigir = createRequire(import.meta.url);
const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const CHROMIUM = process.env.CHROMIUM || '/opt/pw-browsers/chromium';
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const BASE = process.env.BANCADA || 'http://127.0.0.1:8123';

let ok = 0, ruim = 0;
const e = (m, c, d) => c ? (console.log('  ✓ ' + m), ok++)
                         : (console.log('  ✗ ' + m + (d ? '\n      ' + d : '')), ruim++);
const secao = t => console.log('\n' + t);

function aba(){
  const g = {};
  const j = { AGENDAPRO:{ url:BASE, chave:'k', ambiente:'bancada' },
    localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)},
                   removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage',
    fs.readFileSync(RAIZ + '/dados.js','utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage);
  return j.Dados;
}

const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
const um = async (sql, args = []) => (await banco.query(sql, args)).rows[0];

const m = Date.now().toString(36);
const dona = aba();
await dona.criarConta({ email:`ficha-${m}@t.com`, senha:'minhasenhaboa',
  nome:'Dona da Ficha', telefone:'+5511' + (900000000 + (Date.now() % 89999999)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao:'Studio Ficha ' + m,
  p_tipo:'salao', p_telefone:'(11) 99887-6655', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;
await banco.query(`update public.assinaturas set plano = 'salao', status = 'ativa', trial_ate = null where salao_id = $1`, [SALAO]);
await banco.query(`delete from public.servicos where salao_id = $1`, [SALAO]);
const serv = async (nome, preco) => (await um(`insert into public.servicos (salao_id, nome, categoria, duracao_min, preco)
  values ($1, $2, 'Unhas', 90, $3) returning id`, [SALAO, nome, preco])).id;
const GEL = await serv('Alongamento em gel', 150);
const FIBRA = await serv('Fibra de vidro', 180);
const MANI = await serv('Manicure simples', 40);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
async function abrir(caminho, sessao, op = {}){
  const ctx = await nav.newContext(Object.assign({ viewport:{ width:1280, height:900 } }, op.ctx || {}));
  const p = await ctx.newPage();
  p.on('pageerror', x => erros.push('pageerror: ' + x.message));
  p.on('dialog', async d => { erros.push('ALERT: ' + d.message()); await d.dismiss(); });
  await p.addInitScript(([base, ses]) => {
    window.AGENDAPRO = { url: base, chave:'k', ambiente:'bancada' };
    if(ses) localStorage.setItem('agendapro.sessao', JSON.stringify(ses));
  }, [BASE, sessao || null]);
  await p.goto(BASE + caminho);
  await p.waitForTimeout(3500);
  await p.evaluate(() => { const w = document.getElementById('primeiroDia'); if(w) w.hidden = true; });
  return p;
}
const fichaNoBanco = async id => (await um(`select ficha from public.servicos where id = $1`, [id])).ficha;

/* ═══════════════════════════════════ 1 ══ */
secao('1. No painel, a dona escreve a ficha');
const p = await abrir('/app.html', dona.sessao());
await p.evaluate(id => abrirServico(id), GEL);
await p.waitForTimeout(400);
e('o serviço tem "Explicação para a cliente"', await p.locator('#fichaCx summary').isVisible());
e('o "Como fazer" da equipe continua lá', await p.locator('#sProc').count() === 1);
await p.locator('#fichaCx summary').click();
const opcoes = await p.$$eval('#fModelo option', os => os.map(o => o.textContent));
e('o modelo que combina com o nome vem primeiro — ' + opcoes[1], /Alongamento em gel · combina/.test(opcoes[1] || ''));
await p.selectOption('#fModelo', 'Alongamento em gel');
const inc = await p.inputValue('#fInc');
e('o modelo preenche o que está incluso', inc.split('\n').length >= 3 && /Cutilagem/.test(inc), inc);
e('e as dúvidas', await p.locator('#fDuvidas .ficha-duv-linha').count() === 2);
await p.fill('#fNao', 'Decoração, cobrada à parte');
await p.selectOption('#fComparar', FIBRA);
await p.locator('.modal .btn-p').click();
await p.waitForTimeout(3500);
let f = await fichaNoBanco(GEL);
e('salvar gravou a ficha no banco', !!(f && Array.isArray(f.inclui) && f.inclui.includes('Cutilagem e preparo da unha')), JSON.stringify(f));
e('com o que a dona mudou', f && f.naoInclui === 'Decoração, cobrada à parte');
e('e o comparar com a fibra', f && f.compararCom === FIBRA);

// A fibra também, pelo modelo.
await p.evaluate(id => abrirServico(id), FIBRA);
await p.waitForTimeout(400);
await p.locator('#fichaCx summary').click();
await p.selectOption('#fModelo', 'Fibra de vidro');
await p.locator('.modal .btn-p').click();
await p.waitForTimeout(3500);
e('a fibra também tem ficha', !!(await fichaNoBanco(FIBRA)));

/* ═══════════════════════════════════ 2 ══ */
secao('2. Serviço sem ficha continua sem ficha');
await p.evaluate(id => abrirServico(id), MANI);
await p.waitForTimeout(400);
e('serviço sem ficha abre com a caixa fechada', !(await p.evaluate(() => document.getElementById('fichaCx').open)));
await p.locator('.modal .btn-p').click();
await p.waitForTimeout(3000);
e('salvar sem preencher não grava ficha', (await fichaNoBanco(MANI)) === null);
await p.context().close();

/* Um texto com HTML, direto no banco: a página tem que mostrar como texto. */
await banco.query(`update public.servicos set ficha = ficha || jsonb_build_object('cuidadosDepois',
  '<img src=x onerror="window.__invadiu=1">Use luvas') where id = $1`, [GEL]);

/* ═══════════════════════════════════ 3 ══ */
secao('3. No link, no celular');
const c = await abrir('/agendar.html?salao=' + SLUG, null, { ctx:{ viewport:{ width:360, height:780 } } });
const rotulos = await c.$$eval('#capaInfo .recurso-rot', xs => xs.map(x => x.textContent.trim()));
e('o botão "Como funciona" está na fileira — ' + JSON.stringify(rotulos), rotulos.includes('Como funciona'));
e('o convite "Primeira vez aqui?" aparece', await c.locator('.ficha-convite').isVisible());
const chips = await c.$$eval('.ficha-chip', xs => xs.map(x => x.textContent.trim()));
e('com os serviços que têm ficha — ' + JSON.stringify(chips),
  chips.includes('Alongamento em gel') && chips.includes('Fibra de vidro') && !chips.includes('Manicure simples'));
const atalhos = await c.$$eval('#capaServicos .sv-cartao', cs => cs.map(x =>
  [x.querySelector('b').textContent.trim(), (x.querySelector('.sv-cartao-ficha') || {}).textContent || '']));
e('o cartão do gel tem "Ver o que está incluso"',
  atalhos.some(([n, t]) => n.startsWith('Alongamento') && /Ver o que está incluso/.test(t)), JSON.stringify(atalhos));
e('o da manicure (sem ficha) não tem', atalhos.some(([n, t]) => n.startsWith('Manicure') && !t));
const largura = await c.evaluate(() => document.documentElement.scrollWidth);
e('nada vaza da tela em 360px — ' + largura, largura <= 360);

/* ═══════════════════════════════════ 4 ══ */
secao('4. A ficha abre por cima');
await c.locator('#capaServicos .sv-cartao', { hasText: 'Alongamento em gel' }).locator('.sv-cartao-ficha').click();
await c.waitForTimeout(700);
e('a folha abriu', await c.locator('.folha[data-folha="ficha"]').isVisible());
e('e o toque não escolheu o serviço (continua na capa)', await c.evaluate(() => tela === 'capa' && !escolha.servicos.length));
const folha = await c.locator('.folha').innerText();
e('mostra o que está incluso', /O que está incluso[\s\S]*Cutilagem/.test(folha), folha.slice(0, 300));
e('o que não está', /Não está incluso[\s\S]*Decoração, cobrada à parte/.test(folha));
e('quanto dura e a manutenção', /3 a 4 semanas/.test(folha) && /21 dias/.test(folha));
e('o HTML do dono aparece como texto', folha.includes('<img src=x'));
e('e não roda', await c.evaluate(() => window.__invadiu === undefined && !document.querySelector('.folha img[src="x"]')));
e('o preço segue a escolha da capa (escondido)', !/R\$\s*150/.test(folha));
const duv = c.locator('.ficha-duvida').first();
await duv.locator('summary').click();
e('a dúvida abre ao tocar', await duv.evaluate(d => d.open));
const largFolha = await c.evaluate(() => document.querySelector('.folha').scrollWidth <= document.querySelector('.folha').clientWidth + 1);
e('a folha cabe na largura', largFolha);

/* ═══════════════════════════════════ 5 ══ */
secao('5. Comparar e agendar');
await c.locator('.ficha-comparar').click();
await c.waitForTimeout(600);
const tab = await c.locator('.folha').innerText();
e('a comparação mostra os dois', /Alongamento em gel ou Fibra de vidro\?/.test(tab), tab.slice(0, 200));
e('com o que cada um inclui', /Alongamento em fibra/.test(tab) && /Alongamento no formato escolhido/.test(tab));
await c.evaluate(() => fecharFolha(true));
await c.locator('#capaInfo .recurso', { hasText: 'Como funciona' }).click();
await c.waitForTimeout(600);
const lista = await c.locator('.folha').innerText();
e('"Como funciona" lista os serviços com ficha', /Alongamento em gel/.test(lista) && /Fibra de vidro/.test(lista) && !/Manicure simples/.test(lista));
e('e oferece a comparação no topo', await c.locator('.folha .ficha-item-comparar').count() === 1);
await c.locator('.folha .ficha-item', { hasText: 'Fibra de vidro' }).last().click();
await c.waitForTimeout(600);
await c.locator('.folha .ficha-acao .boas-cta').click();
await c.waitForTimeout(900);
const ag = await c.evaluate(() => ({ tela, s: escolha.servicos.slice(), folha: !!document.getElementById('folha') }));
e('"Agendar" leva para a escolha com a fibra marcada — ' + JSON.stringify(ag),
  ag.tela === 'servico' && ag.s.length === 1 && ag.s[0] === FIBRA && !ag.folha);
const atalhoNaEscolha = await c.locator('#listaServicos .sv-cartao', { hasText: 'Fibra de vidro' }).locator('.sv-cartao-ficha').count();
e('na lista de escolher, o atalho da ficha também está', atalhoNaEscolha === 1);
await c.locator('#listaServicos .sv-cartao', { hasText: 'Fibra de vidro' }).locator('.sv-cartao-ficha').click();
await c.waitForTimeout(600);
const naEscolha = await c.evaluate(() => ({ s: escolha.servicos.slice(), txt: document.querySelector('.folha').innerText }));
e('abrir a ficha ali não desmarca a fibra', naEscolha.s.includes(FIBRA));
e('e ali o preço aparece', /R\$\s*180/.test(naEscolha.txt), naEscolha.txt.slice(0, 200));
await c.context().close();

/* ═══════════════════════════════════ 7 ══ */
secao('7. Sem ficha nenhuma, a página é a de sempre');
await banco.query(`update public.servicos set ficha = null where salao_id = $1`, [SALAO]);
const c2 = await abrir('/agendar.html?salao=' + SLUG, null, { ctx:{ viewport:{ width:390, height:844 } } });
e('sem botão "Como funciona"', await c2.locator('#capaInfo .recurso', { hasText: 'Como funciona' }).count() === 0);
e('sem convite', await c2.locator('.ficha-convite').count() === 0);
e('sem atalho nos cartões', await c2.locator('.sv-cartao-ficha').count() === 0);
await c2.context().close();

/* ═══════════════════════════════════ 8 ══ */
secao('8. No passo a passo');
const pd = await abrir('/app.html', dona.sessao());
await pd.evaluate(() => abrirPrimeiroDia(PD_PASSOS.findIndex(x => x.desenhar === pdDesenharRecursos) + 1));
await pd.waitForTimeout(600);
const cartao = await pd.evaluate(() => {
  const c = document.querySelector('#pdCorpo .pd-rec[data-rec="ficha"]');
  return c ? c.innerText.replace(/\s+/g, ' ') : '';
});
e('"Mais recursos" tem o cartão da explicação dos serviços', /Explique seus serviços/.test(cartao), cartao);
e('e ele vem primeiro', await pd.evaluate(() => document.querySelector('#pdCorpo .pd-rec').dataset.rec === 'ficha'));
e('oferece os modelos que combinam com os nomes',
  /Alongamento em gel/.test(cartao) && /Fibra de vidro/.test(cartao) && /Manicure simples/.test(cartao), cartao);
// O dono já escreveu a da fibra: o modelo não pode passar por cima.
await banco.query(`update public.servicos set ficha = '{"explicacao":"Escrita pela dona"}' where id = $1`, [FIBRA]);
await pd.reload(); await pd.waitForTimeout(3500);
await pd.evaluate(() => abrirPrimeiroDia(PD_PASSOS.findIndex(x => x.desenhar === pdDesenharRecursos) + 1));
await pd.waitForTimeout(600);
await pd.click('#pdFichaModelos');
await pd.waitForTimeout(3500);
const gelPd = await fichaNoBanco(GEL), maniPd = await fichaNoBanco(MANI), fibraPd = await fichaNoBanco(FIBRA);
e('um toque preencheu o gel e a manicure pelos modelos',
  !!(gelPd && gelPd.inclui && maniPd && maniPd.inclui && /Lixamento/.test(maniPd.inclui.join())), JSON.stringify(maniPd));
e('e a fibra, que a dona já tinha escrito, ficou como estava', fibraPd && fibraPd.explicacao === 'Escrita pela dona'
  && !fibraPd.inclui, JSON.stringify(fibraPd));
const depois = await pd.evaluate(() => document.querySelector('#pdCorpo .pd-rec[data-rec="ficha"]').innerText.replace(/\s+/g, ' '));
e('o cartão conta os que têm explicação — ' + depois.slice(0, 120), /3 de 3 serviços com explicação/.test(depois));
e('e não oferece mais modelo', await pd.locator('#pdFichaModelos').count() === 0);
await pd.click('#pdFichaEscrever');
await pd.waitForTimeout(600);
e('"Escrever" abre o serviço com a explicação aberta',
  await pd.evaluate(() => !!document.getElementById('fichaCx') && document.getElementById('fichaCx').open
    && document.getElementById('primeiroDia').hidden));
await pd.context().close();

e('nenhum erro de JavaScript', erros.length === 0, erros.slice(0, 3).join(' | '));

await banco.query(`delete from public.saloes where id = $1`, [SALAO]).catch(() => {});
await banco.end();
await nav.close();
console.log(`\n${ok} passaram, ${ruim} falharam`);
process.exit(ruim ? 1 : 0);

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
        do que a dona já escreveu;
     9. as DÚVIDAS FREQUENTES da casa (63_duvidas_casa.sql): a dona escreve
        em Meu negócio, cada uma vira uma moldura com título no botão
        "Dúvidas" do link; e a cliente compara os dois serviços que quiser.
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
  const j = { PEDIHUB:{ url:BASE, chave:'k', ambiente:'bancada' },
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
    window.PEDIHUB = { url: base, chave:'k', ambiente:'bancada' };
    if(ses) localStorage.setItem('pedihub.sessao', JSON.stringify(ses));
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
const c = await abrir('/cardapio.html?salao=' + SLUG, null, { ctx:{ viewport:{ width:360, height:780 } } });
const rotulos = await c.$$eval('#capaInfo .recurso-rot', xs => xs.map(x => x.textContent.trim()));
e('o botão "Dúvidas" está na fileira — ' + JSON.stringify(rotulos), rotulos.includes('Dúvidas') && !rotulos.includes('Como funciona'));
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

/* ═══════════════════════════════════ 3b ══ */
secao('3b. Quatro atalhos: nenhuma palavra cortada ao meio');
/* "Pagamento / s" e "Informaçõe / s" num celular de verdade. Com horário,
   pagamento, apresentação e a ficha, a fileira tem os quatro botões. */
await banco.query(`update public.saloes set cfg = coalesce(cfg, '{}'::jsonb) || $2::jsonb where id = $1`, [SALAO,
  JSON.stringify({ funcionamento: { '1': [['09:00','18:00']], '2': [['09:00','18:00']] },
                   pagamentos: { formas: ['pix', 'credito'] }, sobre: 'Studio de unhas.' })]);
const palavrasInteiras = () => [...document.querySelectorAll('#capaInfo .recurso-rot')].map(el => {
  const t = el.firstChild, txt = t.textContent, cortadas = [];
  let i = 0;
  for(const w of txt.split(/\s+/).filter(Boolean)){
    const ini = txt.indexOf(w, i); i = ini + w.length;
    const r = document.createRange(); r.setStart(t, ini); r.setEnd(t, ini + w.length);
    const linhas = new Set([...r.getClientRects()].filter(x => x.width > 0).map(x => Math.round(x.top)));
    if(linhas.size > 1) cortadas.push(w);
  }
  const botao = el.closest('.recurso');
  return { rot: txt, cortadas, vaza: el.scrollWidth > botao.clientWidth + 1 };
});
for(const [larg, tipo] of [[320, 'salao'], [360, 'salao'], [390, 'salao'], [360, 'barbearia']]){
  await banco.query(`update public.saloes set tipo = $2 where id = $1`, [SALAO, tipo]);
  const q = await abrir('/cardapio.html?salao=' + SLUG, null, { ctx:{ viewport:{ width: larg, height: 780 } } });
  const r = await q.evaluate(palavrasInteiras);
  e(`${larg}px (${tipo}): os quatro atalhos — ${r.map(x => x.rot).join(' · ')}`, r.length === 4, JSON.stringify(r));
  e(`${larg}px (${tipo}): nenhuma palavra quebrada no meio`, r.every(x => !x.cortadas.length), JSON.stringify(r.filter(x => x.cortadas.length)));
  e(`${larg}px (${tipo}): nenhum rótulo sai do botão`, r.every(x => !x.vaza), JSON.stringify(r.filter(x => x.vaza)));
  await q.context().close();
}
await banco.query(`update public.saloes set tipo = 'salao' where id = $1`, [SALAO]);

/* "Ver o que está incluso" com a seta caída na linha de baixo, em cima do
   botão redondo do cartão "elegante" (print da Barbearia Lima). */
secao('3c. O atalho do cartão: a seta nunca sozinha, nada por baixo do botão redondo');
await banco.query(`update public.saloes set cfg = cfg || '{"moldura":"elegante"}'::jsonb where id = $1`, [SALAO]);
const atalhoNoCartao = () => [...document.querySelectorAll('#capaServicos .sv-cartao')].map(c => {
  const a = c.querySelector('.sv-cartao-ficha'), ir = c.querySelector('.sv-cartao-ir');
  if(!a) return null;
  const t = a.firstChild, txt = t.textContent;
  const r = document.createRange();
  const linhaDe = i => { r.setStart(t, i); r.setEnd(t, i + 1);
    const q = [...r.getClientRects()].filter(x => x.width > 0)[0]; return q ? Math.round(q.top) : null; };
  const seta = txt.lastIndexOf('→');
  const antes = txt.slice(0, seta).replace(/\s+$/, '').length - 1;
  const B = ir ? ir.getBoundingClientRect() : null;
  const cobre = !!B && [...a.getClientRects()].some(q => q.right > B.left + 0.5 && q.left < B.right - 0.5
                                                     && q.bottom > B.top + 0.5 && q.top < B.bottom - 0.5);
  return { txt, sozinha: linhaDe(seta) !== linhaDe(antes), cobre, temBotao: !!ir };
}).filter(Boolean);
for(const larg of [320, 360, 390]){
  const q = await abrir('/cardapio.html?salao=' + SLUG, null, { ctx:{ viewport:{ width: larg, height: 780 } } });
  const r = await q.evaluate(atalhoNoCartao);
  e(`${larg}px (elegante): os cartões com explicação têm o atalho e o botão redondo`, r.length >= 2 && r.every(x => x.temBotao), JSON.stringify(r));
  e(`${larg}px (elegante): a seta nunca cai sozinha na linha de baixo`, r.every(x => !x.sozinha), JSON.stringify(r));
  e(`${larg}px (elegante): o atalho não passa por baixo do botão redondo`, r.every(x => !x.cobre), JSON.stringify(r));
  await q.context().close();
}
await banco.query(`update public.saloes set cfg = cfg - 'moldura' where id = $1`, [SALAO]);

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
await c.locator('#capaInfo .recurso', { hasText: 'Dúvidas' }).click();
await c.waitForTimeout(600);
const lista = await c.locator('.folha').innerText();
e('"Dúvidas" lista os serviços com ficha', /Alongamento em gel/.test(lista) && /Fibra de vidro/.test(lista) && !/Manicure simples/.test(lista));
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
const c2 = await abrir('/cardapio.html?salao=' + SLUG, null, { ctx:{ viewport:{ width:390, height:844 } } });
e('sem botão "Dúvidas"', await c2.locator('#capaInfo .recurso', { hasText: 'Dúvidas' }).count() === 0);
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
// As dúvidas da casa, no próprio passo a passo.
await pd.evaluate(() => abrirPrimeiroDia(PD_PASSOS.findIndex(x => x.desenhar === pdDesenharRecursos) + 1));
await pd.waitForTimeout(600);
e('"Mais recursos" tem o cartão das dúvidas, logo depois da explicação',
  await pd.evaluate(() => [...document.querySelectorAll('#pdCorpo .pd-rec')].map(c => c.dataset.rec).slice(0, 2).join() === 'ficha,duvidas'));
const ideiasPd = await pd.$$eval('#pdDuvIdeias .ficha-chip', xs => xs.map(x => x.textContent.trim()));
e('com ideias de perguntas — ' + ideiasPd.slice(0, 3).join(' | '), ideiasPd.includes('Qual a diferença entre gel, fibra e acrílico?'));
await pd.locator('#pdDuvIdeias .ficha-chip', { hasText: 'Atendem criança?' }).click();
e('tocar na ideia abre a pergunta numa caixa que dá para editar',
  await pd.inputValue('#pdDuvEd .dcP') === 'Atendem criança?' && await pd.evaluate(() => document.activeElement.classList.contains('dcR')));
await pd.click('#pdDuvSalvar');
e('sem resposta não salva, e explica', /resposta/.test(await pd.locator('#pdDuvAviso').innerText()));
await pd.fill('#pdDuvEd .dcP', 'Atendem criança de colo?');
await pd.fill('#pdDuvEd .dcR', 'Sim, a partir de 2 anos.');
await pd.click('#pdDuvSalvar');
await pd.waitForTimeout(3500);
const duvPd = (await um(`select cfg -> 'duvidas' d from public.saloes where id = $1`, [SALAO])).d;
e('salvou com o título que a dona editou — ' + JSON.stringify(duvPd),
  Array.isArray(duvPd) && duvPd.some(d => d.p === 'Atendem criança de colo?' && d.r === 'Sim, a partir de 2 anos.'));
e('o cartão conta a dúvida', /1 dúvida no seu link/.test(await pd.locator('#pdCorpo .pd-rec[data-rec="duvidas"]').innerText()));
await pd.click('#pdDuvidasCasa');
await pd.waitForTimeout(700);
e('"Ver e editar todas" leva para Meu negócio, com a dúvida editável',
  await pd.evaluate(() => document.getElementById('primeiroDia').hidden
    && [...document.querySelectorAll('#duvidasCasa .dcP')].some(i => i.value === 'Atendem criança de colo?')));
// As ideias seguem o tipo de negócio.
const porTipo = await pd.evaluate(() => Object.fromEntries(['clinica', 'tatuagem', 'pet', 'barbearia']
  .map(t => [t, sugestoesDeDuvida({ tipo: t, cfg: {} })])));
e('clínica, tatuagem, pet e barbearia têm ideias próprias',
  porTipo.clinica.includes('Atendem por convênio?') && porTipo.tatuagem.includes('Quanto tempo leva para cicatrizar?')
  && porTipo.pet.includes('Precisa estar com a vacina em dia?') && porTipo.barbearia.includes('Posso escolher o barbeiro?'), JSON.stringify(porTipo).slice(0, 300));
await pd.context().close();
await banco.query(`update public.saloes set cfg = cfg - 'duvidas' where id = $1`, [SALAO]);

/* ═══════════════════════════════════ 9 ══ */
secao('9. As dúvidas frequentes da casa');
await banco.query(`update public.servicos set ficha = null where salao_id = $1`, [SALAO]);
const ds = await abrir('/app.html', dona.sessao());
await ds.evaluate(() => { irPara('salao'); trocarAbaSalao('dados'); });
await ds.waitForTimeout(500);
e('Meu negócio tem "Dúvidas frequentes"', await ds.locator('#secaoDuvidas').isVisible());
const sugs = await ds.$$eval('#duvidasSug .ficha-chip', xs => xs.map(x => x.textContent.trim()));
e('com ideias de perguntas — ' + sugs.slice(0, 3).join(' | '),
  sugs.includes('Como funciona Alongamento em gel?') && sugs.includes('Qual a diferença entre gel, fibra e acrílico?'));
await ds.locator('#duvidasSug .ficha-chip', { hasText: 'Qual a diferença entre gel, fibra e acrílico?' }).click();
e('tocar na ideia cria a moldura com o título pronto',
  await ds.locator('#duvidasCasa .duv-ed-linha .dcP').last().inputValue() === 'Qual a diferença entre gel, fibra e acrílico?');
e('e o cursor já vai para a resposta', await ds.evaluate(() => document.activeElement.classList.contains('dcR')));
await ds.locator('#duvidasCasa .dcR').last().fill('O gel é mais flexível.\nA fibra é mais resistente.');
await ds.click('#btMaisDuvida');
await ds.locator('#duvidasCasa .dcP').last().fill('Como funciona a unha em <b>gel</b>?');
await ds.locator('#duvidasCasa .dcR').last().fill('<img src=x onerror="window.__invadiu=2">Primeiro preparamos a unha.');
await ds.click('#btMaisDuvida');
await ds.locator('#duvidasCasa .dcP').last().fill('Pergunta sem resposta');
await ds.setViewportSize({ width: 360, height: 780 });
await ds.waitForTimeout(300);
e('no celular, nada sai da moldura de cada dúvida', await ds.evaluate(() => [...document.querySelectorAll('.duv-ed-linha')]
  .every(l => { const L = l.getBoundingClientRect();
    return [...l.querySelectorAll('input, textarea, button')].every(x => x.getBoundingClientRect().right <= L.right + 0.5); })));
await ds.click('button:has-text("Salvar dados")');
await ds.waitForTimeout(3500);
const cfgD = (await um(`select cfg -> 'duvidas' d from public.saloes where id = $1`, [SALAO])).d;
e('salvar gravou as dúvidas no banco — ' + JSON.stringify(cfgD).slice(0, 90),
  Array.isArray(cfgD) && cfgD.length === 2 && cfgD[0].p.startsWith('Qual a diferença'));
e('a pergunta sem resposta não foi', Array.isArray(cfgD) && !cfgD.some(d => d.p === 'Pergunta sem resposta'));
e('o resto do Meu negócio ficou como estava',
  (await um(`select cfg ->> 'sobre' s from public.saloes where id = $1`, [SALAO])).s === 'Studio de unhas.');
await ds.context().close();

// A entrega pública, como a cliente recebe.
const anon = aba();
const entregue = await anon.duvidasDaCasa(SLUG);
e('a porta pública entrega as duas, só pergunta e resposta',
  entregue.length === 2 && entregue.every(d => Object.keys(d).sort().join() === 'p,r'), JSON.stringify(entregue));
// Lixo gravado direto no cfg: o banco peneira na entrega.
await banco.query(`update public.saloes set cfg = jsonb_set(cfg, '{duvidas}', cfg->'duvidas' || $2::jsonb) where id = $1`,
  [SALAO, JSON.stringify([{ p: 'Só pergunta' }, 7, { p: 'x'.repeat(400), r: 'longa', segredo: 'não' }])]);
const peneirado = await anon.duvidasDaCasa(SLUG);
e('o banco peneira: sem resposta e não-objeto ficam de fora, título com teto, chave estranha some',
  peneirado.length === 3 && peneirado[2].p.length === 150 && !('segredo' in peneirado[2]), JSON.stringify(peneirado).slice(0, 200));
await banco.query(`update public.saloes set status = 'suspenso' where id = $1`, [SALAO]);
e('restaurante fora do ar não entrega nada', (await anon.duvidasDaCasa(SLUG)).length === 0);
await banco.query(`update public.saloes set status = 'ativo' where id = $1`, [SALAO]);
await banco.query(`update public.saloes set cfg = jsonb_set(cfg, '{duvidas}', (cfg->'duvidas') - 2 - 3 - 4) where id = $1`, [SALAO]);

const d = await abrir('/cardapio.html?salao=' + SLUG, null, { ctx:{ viewport:{ width:360, height:780 } } });
const rotD = await d.$$eval('#capaInfo .recurso-rot', xs => xs.map(x => x.textContent.trim()));
e('só com as dúvidas da casa (nenhuma ficha), o botão "Dúvidas" aparece — ' + rotD.join(' · '),
  rotD.join() === 'Pagamentos,Horários,Dúvidas,Informações');
const chipsD = await d.$$eval('.ficha-convite .ficha-chip', xs => xs.map(x => x.textContent.trim()));
e('o "Primeira vez aqui?" mostra as perguntas — ' + JSON.stringify(chipsD),
  chipsD.length === 2 && chipsD[1] === 'Como funciona a unha em <b>gel</b>?');
await d.locator('.ficha-convite .ficha-chip').nth(1).click();
await d.waitForTimeout(600);
const molduras = await d.$$eval('.folha .duv-moldura', ms => ms.map(m => ({
  t: m.querySelector('.duv-titulo').textContent, aberta: m.open })));
e('a folha "Dúvidas" tem uma moldura por pergunta — ' + JSON.stringify(molduras),
  molduras.length === 2 && molduras[0].t.startsWith('Qual a diferença'));
e('e abre já com a pergunta tocada aberta', molduras[1] && molduras[1].aberta && !molduras[0].aberta);
const respD = await d.locator('.folha .duv-moldura').nth(1).locator('.duv-resposta').innerText();
e('o HTML da dona aparece como texto', respD.includes('<img src=x') && molduras[1].t.includes('<b>gel</b>'));
e('e não roda', await d.evaluate(() => window.__invadiu === undefined && !document.querySelector('.folha img, .folha b')));
await d.locator('.folha .duv-moldura').nth(0).locator('summary').click();
const resp0 = await d.locator('.folha .duv-moldura').nth(0).locator('.duv-resposta').innerText();
e('tocar no título abre a resposta, com as quebras de linha', d && /flexível\.\nA fibra/.test(resp0), JSON.stringify(resp0));
e('a folha cabe na largura', await d.evaluate(() => document.querySelector('.folha').scrollWidth <= document.querySelector('.folha').clientWidth + 1));
e('sem ficha de serviço, não há comparar', await d.locator('.folha .duv-comparar').count() === 0);
await d.context().close();

// Com as fichas de volta: dúvidas da casa + comparar o par que a cliente quiser.
await banco.query(`update public.servicos set ficha = '{"explicacao":"Gel","inclui":["Preparo","Gel"],"dura":"3 semanas"}' where id = $1`, [GEL]);
await banco.query(`update public.servicos set ficha = '{"explicacao":"Fibra","inclui":["Preparo","Fibra"]}' where id = $1`, [FIBRA]);
await banco.query(`update public.servicos set ficha = '{"explicacao":"Mão"}' where id = $1`, [MANI]);
const d2 = await abrir('/cardapio.html?salao=' + SLUG, null, { ctx:{ viewport:{ width:360, height:780 } } });
await d2.locator('#capaInfo .recurso', { hasText: 'Dúvidas' }).click();
await d2.waitForTimeout(600);
const txtD2 = await d2.locator('.folha').innerText();
e('a folha junta as dúvidas da casa, o comparar e cada serviço',
  /Qual a diferença/.test(txtD2) && /COMPARE OS SERVIÇOS/i.test(txtD2) && /COMO FUNCIONA CADA SERVIÇO/i.test(txtD2), txtD2.slice(0, 300));
e('a primeira dúvida já vem aberta', await d2.evaluate(() => document.querySelector('.folha .duv-moldura').open));
await d2.selectOption('#duvCompA', MANI);
await d2.selectOption('#duvCompB', FIBRA);
await d2.click('.duv-comparar .boas-b2');
await d2.waitForTimeout(600);
const tabD = await d2.locator('.folha').innerText();
e('a cliente compara o par que escolheu', /Manicure simples ou Fibra de vidro\?/.test(tabD), tabD.slice(0, 120));
await d2.evaluate(() => { fecharFolha(true); abrirFolha('duvidas'); });
await d2.waitForTimeout(500);
await d2.selectOption('#duvCompA', GEL);
await d2.selectOption('#duvCompB', GEL);
await d2.click('.duv-comparar .boas-b2');
await d2.waitForTimeout(400);
e('o mesmo serviço dos dois lados não abre comparação', await d2.locator('.folha[data-folha="duvidas"]').count() === 1);
await d2.context().close();

e('nenhum erro de JavaScript', erros.length === 0, erros.slice(0, 3).join(' | '));

await banco.query(`delete from public.saloes where id = $1`, [SALAO]).catch(() => {});
await banco.end();
await nav.close();
console.log(`\n${ok} passaram, ${ruim} falharam`);
process.exit(ruim ? 1 : 0);

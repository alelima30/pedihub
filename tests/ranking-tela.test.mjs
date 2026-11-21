/* ═══════════════════════════════════════════════════════════════════════════
   O RANKING NA TELA (60_dashboard.sql)

     1. o link da cliente conta a visita sozinho — e de onde ela veio;
     2. a dona abre o Ranking: o resumo, as novas e as que voltaram, quem
        abriu o link, e os rankings com a ordem certa;
     3. trocar o período refaz a conta;
     4. no celular nada vaza da tela;
     5. quem atende vê só os próprios números; a recepção nem tem a aba;
     6. no plano Grátis a aba mostra a trava, e o banco recusa.
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
await dona.criarConta({ email:`rank-${m}@t.com`, senha:'minhasenhaboa',
  nome:'Dona do Ranking', telefone:'+5511' + (900000000 + (Date.now() % 89999999)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao:'Restaurante Ranking ' + m,
  p_tipo:'salao', p_telefone:'(11) 99887-6655', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;
await banco.query(`update public.assinaturas set plano = 'salao', status = 'ativa', trial_ate = null where salao_id = $1`, [SALAO]);
const ju = (await dona.lista('profissionais', { salaoId: SALAO }))[0];
await banco.query(`update public.profissionais set nome = 'Ju Dona' where id = $1`, [ju.id]);

// A Bia, com login, que só atende.
const bia = aba();
await bia.criarConta({ email:`rank-b-${m}@t.com`, senha:'minhasenhaboa',
  nome:'Bia Atende', telefone:'+5511' + (800000000 + (Date.now() % 89999999)) });
const biaPerfil = (await um(`select id from public.perfis where nome = 'Bia Atende' order by criado_em desc limit 1`)).id;
await banco.query(`insert into public.vinculos (perfil_id, salao_id, papel) values ($1, $2, 'profissional')`, [biaPerfil, SALAO]);
const biaProf = (await um(`insert into public.profissionais (salao_id, perfil_id, nome, ativo)
  values ($1, $2, 'Bia', true) returning id`, [SALAO, biaPerfil])).id;
// A Rita, recepção, sem ficha de quem atende.
const rita = aba();
await rita.criarConta({ email:`rank-r-${m}@t.com`, senha:'minhasenhaboa',
  nome:'Rita Recepção', telefone:'+5511' + (700000000 + (Date.now() % 89999999)) });
const ritaPerfil = (await um(`select id from public.perfis where nome = 'Rita Recepção' order by criado_em desc limit 1`)).id;
await banco.query(`insert into public.vinculos (perfil_id, salao_id, papel) values ($1, $2, 'recepcao')`, [ritaPerfil, SALAO]);

/* A agenda deste mês, com a resposta sabida: a Maria marcou 3 (1ª), a
   Joana 1; a Ju atendeu 3, a Bia 1; a Carla é nova pelo link. Tudo nos
   primeiros dias do mês para "Este mês" (que termina hoje) pegar tudo. */
const cli = async nome => (await um(`insert into public.clientes (salao_id, nome, telefone)
  values ($1, $2, $3) returning id`, [SALAO, nome, String(11900000000 + Math.floor(Math.random() * 89999999))])).id;
const MARIA = await cli('Maria Souza'), JOANA = await cli('Joana Lima'), CARLA = await cli('Carla Nova');
const H = (await um(`select (now() at time zone 'America/Sao_Paulo')::date as d,
  date_trunc('month', now() at time zone 'America/Sao_Paulo')::date as ini`));
const hojeSP = H.d.toISOString().slice(0, 10), iniMes = H.ini.toISOString().slice(0, 10);
await banco.query(`alter table public.agendamentos disable trigger user`);
const ag = (c, p, hora, st, org, v) => banco.query(`insert into public.agendamentos
  (salao_id, cliente_id, profissional_id, inicio, fim, status, origem, valor_previsto)
  values ($1, $2, $3, ($4::date + $5::time) at time zone 'America/Sao_Paulo',
          ($4::date + $5::time + interval '1 hour') at time zone 'America/Sao_Paulo', $6, $7, $8)`,
  [SALAO, c, p, iniMes, hora, st, org, v]);
// A Maria e a Joana já vinham antes deste mês.
await banco.query(`insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim, status, origem, valor_previsto)
  select $1, c, $2, now() - interval '90 days' + make_interval(hours => (i * 2)::int),
         now() - interval '90 days' + make_interval(hours => (i * 2 + 1)::int), 'concluido', 'recepcao', 50
    from unnest($3::uuid[]) with ordinality as u(c, i)`, [SALAO, ju.id, [MARIA, JOANA]]);
await ag(MARIA, ju.id, '08:00', 'concluido', 'recepcao', 50);
await ag(MARIA, ju.id, '09:00', 'concluido', 'online', 50);
await ag(MARIA, biaProf, '10:00', 'concluido', 'online', 80);
await ag(JOANA, ju.id, '11:00', 'concluido', 'recepcao', 200);
await ag(CARLA, ju.id, '12:00', 'faltou', 'online', 50);
await banco.query(`alter table public.agendamentos enable trigger user`);

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
  await p.goto(BASE + caminho, op.referer ? { referer: op.referer } : {});
  await p.waitForTimeout(3500);
  // O passo a passo do primeiro dia abre sozinho num restaurante novo; aqui não é o assunto.
  await p.evaluate(() => { const w = document.getElementById('primeiroDia'); if(w) w.hidden = true; });
  return p;
}

/* ═══════════════════════════════════ 1 ══ */
secao('1. O link conta a visita');
const v1 = await abrir('/agendar.html?salao=' + SLUG + '&utm_source=instagram');
await v1.reload(); await v1.waitForTimeout(2500);                       // a mesma pessoa, de novo
const v2 = await abrir('/agendar.html?salao=' + SLUG, null, { referer: 'https://wa.me/' });
const vis = await banco.query(`select origem, vezes from public.link_visitas where salao_id = $1 order by origem`, [SALAO]);
e('duas pessoas diferentes viraram duas linhas — ' + JSON.stringify(vis.rows),
  vis.rows.length === 2, JSON.stringify(vis.rows));
e('a primeira veio pelo Instagram, e abriu 2 vezes',
  vis.rows.some(r => r.origem === 'instagram' && r.vezes === 2));
e('a segunda veio pelo WhatsApp', vis.rows.some(r => r.origem === 'whatsapp'));
const codigo = await v1.evaluate(() => localStorage.getItem('pedihub.visitante'));
e('o aparelho guarda só um código aleatório', /^[A-Za-z0-9_-]{24}$/.test(codigo || ''), codigo);
e('e o banco não guarda esse código como veio',
  Number((await um(`select count(*) n from public.link_visitas where visitante like '%' || $1 || '%'`, [codigo])).n) === 0);
await v1.context().close(); await v2.context().close();

/* ═══════════════════════════════════ 2 ══ */
secao('2. A dona abre o Ranking');
const p = await abrir('/app.html', dona.sessao());
e('a aba Ranking está no menu', await p.evaluate(() => !!document.querySelector('#abas .aba[data-chave="ranking"]')));
await p.evaluate(() => irPara('ranking'));
await p.waitForTimeout(2500);
const txt = await p.evaluate(() => document.getElementById('rkCorpo').innerText);
const listas = await p.evaluate(() => [...document.querySelectorAll('#rkCorpo .rk-card')].map(c => ({
  titulo: (c.querySelector('h3') || {}).textContent,
  linhas: [...c.querySelectorAll('.rk-lista li')].map(li => li.querySelector('.rk-nome').firstChild.textContent.trim()
    + ' = ' + li.querySelector('.rk-val').textContent.trim()) })));
const lista = t => (listas.find(l => l.titulo === t) || { linhas: [] }).linhas;
const num = rot => p.evaluate(r => { const n = [...document.querySelectorAll('#rkCorpo .rk-num')]
  .find(x => x.querySelector('span').textContent === r); return n ? n.querySelector('b').textContent : null; }, rot);
e('5 horários marcados no mês', await num('horários marcados') === '5', await num('horários marcados'));
e('4 atendimentos (a Carla faltou), e a falta aparece', await num('atendimentos') === '4' && /1 falta/.test(txt));
e('3 marcados pelo link', await num('marcados pelo link') === '3');
e('R$ 380 em atendimentos', /R\$\s?380,00/.test(await num('em atendimentos') || ''), await num('em atendimentos'));
e('1 nova — pelo link', await num('novas') === '1' && /1 pelo link · 0 no balcão/.test(txt));
e('2 voltaram (Maria e Joana já vinham)', await num('voltaram') === '2');
e('2 pessoas abriram o link, 3 visitas', await num('pessoas diferentes') === '2' && /3 visitas no total/.test(txt));
e('quem mais marcou: Maria, 3 horários — ' + JSON.stringify(lista('Clientes que mais marcaram')[0]),
  lista('Clientes que mais marcaram')[0] === 'Maria Souza = 3 horários');
e('quem mais gastou: Joana, R$ 200', /^Joana Lima = R\$\s?200,00$/.test(lista('Clientes que mais gastaram')[0] || ''),
  lista('Clientes que mais gastaram')[0]);
e('quem mais atendeu: Ju, 3 atendimentos; depois a Bia, 1',
  JSON.stringify(lista('Quem mais atendeu')) === JSON.stringify(['Ju Dona = 3 atendimentos', 'Bia = 1 atendimento']),
  JSON.stringify(lista('Quem mais atendeu')));
e('o rendimento do link é horário por pessoa, nunca porcentagem acima de 100',
  await num('horários por pessoa que abriu') === '1,5' && !/\d{3}%/.test(txt), await num('horários por pessoa que abriu'));
e('de onde vieram: Instagram e WhatsApp, 1 pessoa cada',
  lista('Quem abriu o seu link').length === 2 && lista('Quem abriu o seu link').every(l => / = 1 pessoa$/.test(l)),
  JSON.stringify(lista('Quem abriu o seu link')));
e('as três primeiras posições ficam em destaque',
  await p.evaluate(() => document.querySelectorAll('#rkCorpo .rk-pos.rk-top').length > 0));

/* ═══════════════════════════════════ 3 ══ */
secao('3. Trocar o período');
await p.click('#rkAtalhos button:has-text("Mês passado")');
await p.waitForTimeout(2000);
e('o botão fica marcado', await p.evaluate(() =>
  document.querySelector('#rkAtalhos button.on').textContent) === 'Mês passado');
e('e o mês passado (sem nada) diz zero, com frase em vez de lista vazia',
  await num('horários marcados') === '0' && /Nenhum horário marcado neste período/.test(
    await p.evaluate(() => document.getElementById('rkCorpo').innerText)));
await p.click('#rkAtalhos button:has-text("Este mês")');
await p.waitForTimeout(2000);

/* ═══════════════════════════════════ 4 ══ */
secao('4. No celular');
await p.setViewportSize({ width: 360, height: 780 });
await p.waitForTimeout(600);
const vaza = await p.evaluate(() => {
  const larg = document.documentElement.clientWidth;
  return [...document.querySelectorAll('#tela-ranking *')]
    .filter(el => { const b = el.getBoundingClientRect(); return b.width && b.right > larg + 1; })
    .map(el => el.className || el.tagName).slice(0, 5);
});
e('nada passa da borda a 360px', vaza.length === 0, JSON.stringify(vaza));
e('a página não rola de lado', await p.evaluate(() =>
  document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1));

/* ═══════════════════════════════════ 5 ══ */
secao('5. Quem atende, e a recepção');
const pb = await abrir('/app.html', bia.sessao());
e('a Bia tem a aba Ranking', await pb.evaluate(() => !!document.querySelector('#abas .aba[data-chave="ranking"]')));
await pb.evaluate(() => irPara('ranking'));
await pb.waitForTimeout(2500);
const tb = await pb.evaluate(() => document.getElementById('rkCorpo').innerText);
e('e vê "Os seus números"', /Os seus números/.test(tb), tb.slice(0, 80));
e('só o horário dela (1)', await pb.evaluate(() => [...document.querySelectorAll('#rkCorpo .rk-num')]
  .find(x => x.querySelector('span').textContent === 'horários marcados').querySelector('b').textContent) === '1');
e('sem as visitas do link e sem a Joana (que não é cliente dela)',
  !/Quem abriu o seu link/.test(tb) && !/Joana/.test(tb));
const pr = await abrir('/app.html', rita.sessao());
e('a recepção não tem a aba Ranking',
  !(await pr.evaluate(() => !!document.querySelector('#abas .aba[data-chave="ranking"]'))));

/* ═══════════════════════════════════ 6 ══ */
secao('6. No plano Grátis');
await banco.query(`update public.assinaturas set plano = 'gratuito' where salao_id = $1`, [SALAO]);
let recusa = null;
try{ await dona.chamar('dashboard', { p_salao: SALAO, p_de: iniMes, p_ate: hojeSP }); }
catch(x){ recusa = x.message; }
e('o banco recusa — ' + JSON.stringify(recusa), /a partir do plano Básico/.test(recusa || ''));
const pg2 = await abrir('/app.html', dona.sessao());
const trava = await pg2.evaluate(() => typeof moduloLiberado === 'function' && !moduloLiberado('relatorios'));
e('e a tela sabe que o módulo está travado', trava === true);

e('nenhum erro de JavaScript', erros.length === 0, erros.slice(0, 3).join(' | '));

await banco.query(`delete from public.agendamento_servicos where agendamento_id in
  (select id from public.agendamentos where salao_id = $1)`, [SALAO]).catch(() => {});
await banco.query(`delete from public.saloes where id = $1`, [SALAO]).catch(() => {});
await banco.end();
await nav.close();
console.log(`\n${ok} passaram, ${ruim} falharam`);
process.exit(ruim ? 1 : 0);

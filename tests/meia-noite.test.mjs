/* ═══════════════════════════════════════════════════════════════════════════
   HORÁRIO QUE ATRAVESSA A MEIA-NOITE

   Achado pelo teste do Ranking na bateria: um horário das 23:30 às 00:30
   fazia o painel abrir dizendo "NÃO consegui salvar no banco — range lower
   bound must be less than or equal to range upper bound", e a partir daí NADA
   mais gravava naquele salão. O fim virava "00:30 do mesmo dia", antes do
   começo; a tela achava que o horário tinha mudado e tentava regravá-lo.

     1. o painel abre sem aviso, com o fim no dia seguinte;
     2. salvar outra coisa não mexe nos horários da madrugada;
     3. a agenda mostra 00:30 (e não 24:30);
     4. folga de um dia inteiro e férias de vários dias voltam iguais;
     5. a conversão de volta leva o fim para o dia seguinte.
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

function aba(){ const g = {}; const j = { AGENDAPRO:{ url:BASE, chave:'k', ambiente:'bancada' },
  localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)}, removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage', fs.readFileSync(RAIZ + '/dados.js','utf8'))(
    j, { info(){}, error(){}, log(){} }, fetch, j.localStorage); return j.Dados; }
const banco = new pg.Client({ host: process.env.PGHOST || '/tmp', port: +(process.env.PGPORT || 5444),
  user: process.env.PGUSER || 'postgres', database: process.env.PGBANCO || 'app' });
await banco.connect();

const m = Date.now().toString(36); const dona = aba();
await dona.criarConta({ email:`mn-${m}@t.com`, senha:'minhasenhaboa', nome:'Dona MN',
  telefone:'+5511' + (900000000 + (Date.now() % 89999999)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao:'Madrugada ' + m, p_tipo:'salao',
  p_telefone:'(11) 99887-6655', p_documento:null, p_origem:null });
const S = cr[0].salao_id; const pr = (await dona.lista('profissionais', { salaoId: S }))[0];
const c = (await banco.query(`insert into public.clientes (salao_id, nome, telefone)
  values ($1,'Noturna','11977770000') returning id`, [S])).rows[0].id;
await banco.query(`alter table public.agendamentos disable trigger user`);
for(const [dias, st] of [[-3, 'concluido'], [2, 'confirmado']])
  await banco.query(`insert into public.agendamentos (salao_id, cliente_id, profissional_id, inicio, fim, status, origem, valor_previsto)
    values ($1,$2,$3, ((now() at time zone 'America/Sao_Paulo')::date + $4::int + time '23:30') at time zone 'America/Sao_Paulo',
                      ((now() at time zone 'America/Sao_Paulo')::date + $4::int + 1 + time '00:30') at time zone 'America/Sao_Paulo',
                      $5, 'recepcao', 50)`, [S, c, pr.id, dias, st]);
await banco.query(`alter table public.agendamentos enable trigger user`);
// Uma folga de um dia inteiro e férias de uma semana.
await banco.query(`insert into public.bloqueios (salao_id, profissional_id, inicio, fim, motivo) values
  ($1, $2, ((now() at time zone 'America/Sao_Paulo')::date + 5)::timestamp at time zone 'America/Sao_Paulo',
           ((now() at time zone 'America/Sao_Paulo')::date + 6)::timestamp at time zone 'America/Sao_Paulo', 'Folga'),
  ($1, $2, ((now() at time zone 'America/Sao_Paulo')::date + 10)::timestamp at time zone 'America/Sao_Paulo',
           ((now() at time zone 'America/Sao_Paulo')::date + 17)::timestamp at time zone 'America/Sao_Paulo', 'Férias')`, [S, pr.id]);
const retrato = async () => JSON.stringify((await banco.query(
  `select inicio, fim from public.agendamentos where salao_id = $1
   union all select inicio, fim from public.bloqueios where salao_id = $1 order by 1`, [S])).rows);
const antes = await retrato();

const nav = await chromium.launch({ executablePath: CHROMIUM });
const p = await (await nav.newContext({ viewport:{ width:1280, height:900 } })).newPage();
const avisos = [];
p.on('dialog', async d => { avisos.push(d.message()); await d.dismiss(); });
p.on('pageerror', x => avisos.push('pageerror ' + x.message));
await p.addInitScript(([b, s]) => { window.AGENDAPRO = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('agendapro.sessao', JSON.stringify(s)); }, [BASE, dona.sessao()]);
await p.goto(BASE + '/app.html'); await p.waitForTimeout(4000);
await p.evaluate(() => { const w = document.getElementById('primeiroDia'); if(w) w.hidden = true; });

console.log('\n1. Abrir');
e('o painel abre sem "NÃO consegui salvar"', avisos.length === 0, JSON.stringify(avisos));
const tela = await p.evaluate(() => bd.agendamentos.map(a => [a.inicio, a.fim]));
e('na tela, o fim é 00:30 do dia seguinte (1470), depois do começo (1410)',
  tela.length === 2 && tela.every(([i, f]) => i === 1410 && f === 1470), JSON.stringify(tela));
const bl = await p.evaluate(() => bd.bloqueios.map(b => [b.inicio, b.fim]).sort((x, y) => x[1] - y[1]));
e('a folga vai de 0 a 1440 (o dia inteiro), as férias de 0 a 7×1440',
  JSON.stringify(bl) === JSON.stringify([[0, 1440], [0, 10080]]), JSON.stringify(bl));

console.log('\n2. Salvar outra coisa');
await p.evaluate(() => { acharSalao(salaoAtual).nome = 'Madrugada renomeada'; salvar(); });
await p.waitForTimeout(3000);
e('salvar o nome do salão funciona', avisos.length === 0, JSON.stringify(avisos));
e('e os horários da madrugada, a folga e as férias ficam exatamente iguais no banco', await retrato() === antes);

console.log('\n3. A agenda');
await p.evaluate(() => { irPara('agenda'); diaAtual = bd.agendamentos.find(a => a.status === 'confirmado').data; pintar(); });
await p.waitForTimeout(800);
const texto = await p.evaluate(() => document.getElementById('tela-agenda').innerText);
e('o horário da madrugada aparece no dia certo', /23:30\s*Noturna/.test(texto), texto.slice(0, 200));
e('e nada na tela diz 24:30', !/24:30/.test(texto));
const detalhe = await p.evaluate(() => { const a = bd.agendamentos.find(x => x.status === 'confirmado');
  return hm(a.inicio) + '–' + hm(a.fim); });
e('o começo e o fim escritos: 23:30–00:30', detalhe === '23:30–00:30', detalhe);

console.log('\n4. A volta para o banco');
const ida = await p.evaluate(() => [telaParaInstante('2026-11-18', 1470, 'America/Sao_Paulo'),
  telaParaInstante('2026-11-18', 1440, 'America/Sao_Paulo'), telaParaInstante('2026-12-31', 1470, 'America/Sao_Paulo'),
  hm(1470), hm(1410)]);
e('23:30 + 1 hora vai para 00:30 do dia seguinte', ida[0] === '2026-11-19 00:30:00 America/Sao_Paulo', ida[0]);
e('meia-noite em ponto é 00:00 do dia seguinte', ida[1] === '2026-11-19 00:00:00 America/Sao_Paulo', ida[1]);
e('e na virada do ano, o ano vira', ida[2] === '2027-01-01 00:30:00 America/Sao_Paulo', ida[2]);
e('hm escreve 00:30 e 23:30', ida[3] === '00:30' && ida[4] === '23:30', JSON.stringify(ida.slice(3)));

e('nenhum erro de JavaScript', !avisos.some(a => a.startsWith('pageerror')), JSON.stringify(avisos));

await banco.query(`delete from public.saloes where id = $1`, [S]).catch(() => {});
await banco.end(); await nav.close();
console.log(`\n${ok} passaram, ${ruim} falharam`);
process.exit(ruim ? 1 : 0);

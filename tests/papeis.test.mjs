/* ===========================================================================
   PediHub — o painel obedece o papel de quem entrou

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/papeis.test.mjs

   ── O DEFEITO QUE ESTA SUÍTE EXISTE PARA IMPEDIR ───────────────────────────
   O convite passou a dar login para a recepção e para quem atende. Mas o
   painel era o MESMO para todo mundo: a recepcionista entrava e via Plano,
   Meu negócio e Equipe.

   O banco recusava a escrita dela — o RLS sempre esteve certo, e continua
   sendo ele quem recusa. O problema era a tela OFERECER: uma recepcionista
   lendo o valor do plano e a comissão das colegas, e levando erro em inglês
   quando tentava salvar algo que a própria tela deixou ela abrir.

   ── NO RESTAURANTE ───────────────────────────────────────────────────────
     dona            tudo
     caixa/balcão    Pedidos, Mesas, Caixa, Clientes e o Cardápio; sem Plano,
                     Meu negócio, Equipe, Relatórios e Hoje (faturamento)
     garçom          Pedidos e Mesas; sem Caixa (a gaveta é do restaurante)
   Esconder a aba não é proteger o dado: o BANCO recusa o relatório para o
   balcão e o caixa para o garçom.

   ── COMO ELA MEDE ──────────────────────────────────────────────────────────
   Três pessoas de verdade, três navegadores separados, no MESMO restaurante. Não
   se troca papel por variável: o papel vem do vínculo, como no ar.
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
const verdade = (m, c, d) => c ? ok(m) : nao(m, d);
const igual = (m, a, b) => a === b ? ok(m)
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

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const tel = () => '+5511' + (100000000 + Math.floor(Math.random()*89999999));

// ── A dona monta o restaurante ───────────────────────────────────────────────
const dDona = novaAba();
await dDona.criarConta({ email:`p-dona-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone: tel() });
const cr = await dDona.chamar('criar_salao', { p_nome_salao:'Restaurante Papéis ' + marca,
  p_tipo:'restaurante', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id;

const banco = new pg.Client({ host: process.env.PGHOST || '/tmp',
  port: +(process.env.PGPORT || 5444), user: process.env.PGUSER || 'postgres',
  database: process.env.PGBANCO || 'app' });
await banco.connect();
await banco.query(`update public.assinaturas set plano='time', status='ativa', vence_em = current_date + 30
  where salao_id=$1`, [SALAO]);
await dDona.inserir('produtos', { salaoId: SALAO, nome:'X-Burger', preco:30, custo:0, estoque:0,
  ativo:true, vendaOnline:true });
await dDona.atualizar('saloes', SALAO, { cfg:{ pedidos:{ mesas: 6 } } });

// ── Convida o caixa/balcão e um garçom ────────────────────────────────────
// No restaurante o garçom entra SEM ficha (77): o nome em cada item vem do cadastro dele.
async function convidar(papel, nome, email){
  const r = await dDona.chamar('criar_convite',
    { p_salao: SALAO, p_papel: papel, p_para_quem: nome, p_profissional: null });
  const d = novaAba();
  await d.criarConta({ email, senha:'minhasenhaboa', nome, telefone: tel() });
  await d.chamar('aceitar_convite', { p_token: r.token });
  return d;
}
const dRecep  = await convidar('recepcao', 'Rita Caixa', `p-recep-${marca}@teste.com`);
const dGarcom = await convidar('profissional', 'Wilson Garçom', `p-garcom-${marca}@teste.com`);
igual('os dois convites viraram vínculo ativo',
  Number((await banco.query(`select count(*) n from public.vinculos where salao_id=$1 and status='ativo'
    and papel in ('recepcao','profissional')`, [SALAO])).rows[0].n), 2);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];

async function abrirPainel(dados, rotulo){
  const p = await (await nav.newContext({ viewport:{width:1360,height:900} })).newPage();
  p.on('pageerror', e => erros.push(rotulo + ': ' + e.message));
  // A comanda e o caixa estão DESLIGADOS na plataforma (COMANDA_LIGADA no
  // app.html); este teste mede as telas deles, então liga só nesta aba.
  await p.addInitScript(() => { try{ sessionStorage.setItem('pedihub.comanda', '1'); }catch(e){} });
  await p.addInitScript(([b, s]) => {
    window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
    localStorage.setItem('pedihub.sessao', JSON.stringify(s));
  }, [BASE, dados.sessao()]);
  await p.goto(BASE + '/app.html');
  await p.waitForTimeout(4000);
  return p;
}
const abasDe = p => p.evaluate(() =>
  [...document.querySelectorAll('#abas .aba')].map(b => b.dataset.chave));
const recusa = (p, fn, args) => p.evaluate(async ([fn, args]) => {
  try{ await Dados.chamar(fn, args); return null; }catch(e){ return e.message || 'recusado'; }
}, [fn, args]);

/* ══════════════════════════════════════════════════════════════════════════
   1. A DONA VÊ TUDO
   ══════════════════════════════════════════════════════════════════════════ */
secao('A dona');
const pgDona = await abrirPainel(dDona, 'dona');
const abasDona = await abasDe(pgDona);
/* "Todas" contado a partir da própria regra da tela (minhasTelas), e não
   escrito à mão: número escrito num teste envelhece. O que importa é que ela
   veja as do dia a dia E as da gestão. */
igual('vê todas as abas do sistema', abasDona.length, await pgDona.evaluate(() => minhasTelas().length));
verdade('Pedidos, Mesas e Caixa', ['pedidos','mesas','caixa'].every(k => abasDona.includes(k)), JSON.stringify(abasDona));
verdade('e a gestão: Hoje, Relatórios, Equipe, Meu negócio e Plano',
  ['hoje','relatorios','equipe','salao','plano'].every(k => abasDona.includes(k)), JSON.stringify(abasDona));
verdade('e nada do salão (agenda, serviços, pacotes, ranking)',
  !['agenda','servicos','pacotes','ranking','procedimentos'].some(k => abasDona.includes(k)), JSON.stringify(abasDona));
igual('e o papel dela aparece na lateral',
  (await pgDona.evaluate(() =>
    (document.getElementById('latQuemPapel') || {}).textContent) || '').trim(), 'Proprietário');

// O convite de garçom, pela tela: não pede ficha nenhuma, e sai o link.
await pgDona.evaluate(() => { irPara('equipe'); abrirConvite(); });
await pgDona.waitForTimeout(400);
await pgDona.click('label.serv-op:has(input[name="vPapel"][value="profissional"])');
await pgDona.waitForTimeout(200);
verdade('Equipe → Convidar alguém → garçom: não pede "ficha" nem fala de agenda',
  !(await pgDona.isVisible('#vFicha')) && !/agenda/i.test(await pgDona.innerText('#modalCorpo')),
  await pgDona.innerText('#modalCorpo'));
await pgDona.fill('#vNome', 'Beto, garçom de sábado');
await pgDona.click('#modalPe button:has-text("Gerar link")');
await pgDona.waitForSelector('#vLink', { timeout: 8000 }).catch(() => {});
verdade('e o link do convite sai na hora', /convite\.html\?c=/.test(await pgDona.inputValue('#vLink').catch(() => '')),
  await pgDona.innerText('#vSaida').catch(() => ''));
await pgDona.evaluate(() => fecharModal());

/* ══════════════════════════════════════════════════════════════════════════
   2. O CAIXA / BALCÃO
   ══════════════════════════════════════════════════════════════════════════ */
secao('O caixa e balcão');
const pgRecep = await abrirPainel(dRecep, 'recepcao');
const abasRecep = await abasDe(pgRecep);
verdade('trabalha: Pedidos, Mesas, Caixa e Clientes',
  ['pedidos','mesas','caixa','clientes'].every(k => abasRecep.includes(k)), JSON.stringify(abasRecep));
verdade('NÃO vê o Plano nem Meu negócio',
  !abasRecep.includes('plano') && !abasRecep.includes('salao'), JSON.stringify(abasRecep));
verdade('NÃO vê Equipe', !abasRecep.includes('equipe'), JSON.stringify(abasRecep));
verdade('NÃO vê Relatórios nem Hoje — faturamento não é assunto do balcão',
  !abasRecep.includes('relatorios') && !abasRecep.includes('hoje'), JSON.stringify(abasRecep));
verdade('e o BANCO recusa o relatório para ele, não só a tela',
  (await recusa(pgRecep, 'relatorio', { p_salao: SALAO, p_de:'2026-01-01', p_ate:'2026-12-31' })) !== null,
  'o balcão leu o faturamento do restaurante inteiro');
await pgRecep.evaluate(() => irPara('plano'));
await pgRecep.waitForTimeout(400);
igual('e chamar a aba escondida cai em Pedidos', await pgRecep.evaluate(() => telaAtual), 'pedidos');

/* ══════════════════════════════════════════════════════════════════════════
   3. O GARÇOM
   ══════════════════════════════════════════════════════════════════════════ */
secao('O garçom');
const pgGarcom = await abrirPainel(dGarcom, 'garcom');
const abasGarcom = await abasDe(pgGarcom);
verdade('vê Pedidos e Mesas', ['pedidos','mesas'].every(k => abasGarcom.includes(k)), JSON.stringify(abasGarcom));
verdade('NÃO vê Plano, Meu negócio, Equipe, Relatórios nem Hoje',
  !['plano','salao','equipe','relatorios','hoje'].some(k => abasGarcom.includes(k)), JSON.stringify(abasGarcom));
verdade('NÃO vê a aba Caixa — a gaveta é dinheiro do restaurante inteiro',
  !abasGarcom.includes('caixa'), JSON.stringify(abasGarcom));
await pgGarcom.evaluate(() => irPara('caixa'));
await pgGarcom.waitForTimeout(400);
igual('e digitar a aba na mão cai em Pedidos', await pgGarcom.evaluate(() => telaAtual), 'pedidos');
const idGarcom = (dGarcom.sessaoAtual() || {}).usuarioId;
const caixaGarcom = await banco.query(`select set_config('request.jwt.claim.sub', $1, true)`, [idGarcom])
  .then(async () => {
    try{ await banco.query(`begin; set local role authenticated;
      select set_config('request.jwt.claim.sub', '${idGarcom}', true);
      insert into public.caixas (salao_id) values ('${SALAO}');`); await banco.query('rollback'); return null; }
    catch(e){ await banco.query('rollback').catch(() => {}); return e.message; }
  });
verdade('e o BANCO recusa abrir o caixa para ele, não só a tela', caixaGarcom !== null, 'o garçom abriu o caixa');
verdade('e o papel dele aparece na lateral como garçom',
  /garçom/i.test((await pgGarcom.evaluate(() =>
    (document.getElementById('latQuemPapel') || {}).textContent) || '')),
  await pgGarcom.evaluate(() => (document.getElementById('latQuemPapel') || {}).textContent));

secao('Sem erro de JavaScript');
igual('nenhum erro no console', erros.length, 0, erros.join(' | '));
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

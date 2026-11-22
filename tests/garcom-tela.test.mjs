/* ===========================================================================
   PediHub — o garçom no celular, de ponta a ponta (73_conta_da_mesa_garcom)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/garcom-tela.test.mjs

   No Bar do Toninho:
     1. o dono diz que tem 10 mesas, em duas praças ("Praça 1: 1-5" e
        "Praça 2: 6 a 10") — e a aba "Mesas" aparece;
     2. o Wilson (garçom, conta própria, no celular) entra, escolhe a
        Praça 2 e vê só as mesas 6 a 10;
     3. toca na mesa 7, "Lançar itens": o cardápio vem com as FOTOS, separado
        por categoria; tocar na foto amplia (para mostrar ao cliente);
     4. põe a picanha e o vinho e manda para a cozinha: no BANCO cada item
        sai com o nome dele, e a conta da mesa mostra "Wilson · na cozinha";
        o mapa pinta a mesa 7 com o total;
     5. fecha a conta: 10% de serviço, dividida por 2, no crédito — o banco
        fecha a conta, a venda entra no caixa e a mesa fica livre.
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
// FOTOS=pasta guarda as telas do celular (para mostrar como fica).
const foto = async (pg, nome) => { if(process.env.FOTOS) await pg.screenshot({ path: path.join(process.env.FOTOS, nome + '.png') }); };
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
const dono = aba();
await dono.criarConta({ email:`toninho-${m}@teste.com`, senha:'minhasenhaboa', nome:'Toninho',
  telefone:'+5511' + (930000000 + (Date.now() % 50000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Bar do Toninho ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3252', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
await dono.inserir('produtos', { salaoId, nome:'Picanha na chapa', preco:80, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Pratos', foto:'icones/icone-512.png',
  descricao:'Picanha fatiada com farofa e vinagrete' });
await dono.inserir('produtos', { salaoId, nome:'Vinho tinto', preco:60, custo:0, estoque:0,
  ativo:true, vendaOnline:true, categoria:'Bebidas' });

const garcom = aba();
await garcom.criarConta({ email:`wilson-${m}@teste.com`, senha:'minhasenhaboa', nome:'Wilson Souza',
  telefone:'+5511' + (920000000 + (Date.now() % 50000000)) });
const wilsonId = (await um(`select id from auth.users where email = $1`, [`wilson-${m}@teste.com`])).id;
await banco.query(`insert into public.vinculos (perfil_id, salao_id, papel, status) values ($1, $2, 'profissional', 'ativo')`,
  [wilsonId, salaoId]);
ok('um bar com picanha (com foto) e vinho, e o Wilson na equipe');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
async function abrirPainel(sessao, opcoes){
  const ctx = await nav.newContext(opcoes);
  const p = await ctx.newPage();
  p.on('pageerror', e => erros.push(e.message));
  p.on('dialog', x => { p.alertas.push(x.message()); x.accept(); });
  p.alertas = [];
  await p.addInitScript(([b, s]) => {
    window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
    if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
  }, [BASE, sessao]);
  await p.goto(BASE + '/app.html');
  await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos)
    && bd.produtos.length >= 2, null, { timeout: 20000 });
  await p.waitForTimeout(800);
  return p;
}

secao('1. O dono põe as mesas e as praças');
const pd = await abrirPainel(dono.sessao(), { viewport:{ width:1280, height:1000 } });
verdade('sem mesas, não há aba "Mesas"', !(await pd.$('.aba[data-chave="mesas"]')));
await pd.evaluate(() => abrirConfigPedidos());
await pd.waitForSelector('#pcPracas');
await pd.fill('#pcMesas', '10');
await pd.fill('#pcPracas', 'Praça 1: 1-5\nPraça 2: 6 a 10\nisto não é praça');
await pd.click('#modalPe .btn-p');
await pd.waitForTimeout(1500);
const cfg = await um(`select cfg->'pedidos' p from public.saloes where id = $1`, [salaoId]);
igual('gravou 10 mesas e as duas praças (a linha torta fica de fora)',
  [cfg.p.mesas, (cfg.p.pracas || []).map(x => `${x.nome}: ${x.de}-${x.ate}`)], [10, ['Praça 1: 1-5', 'Praça 2: 6-10']]);
verdade('a aba "Mesas" aparece na hora', !!(await pd.$('.aba[data-chave="mesas"]')));

secao('2. O Wilson, no celular, escolhe a praça');
const p = await abrirPainel(garcom.sessao(), { ...devices['Pixel 7'] });
await p.evaluate(() => irPara('mesas'));
await p.waitForSelector('#mesasMapa .mesa-cartao');
igual('as praças no topo', await p.$$eval('#mesasPracas button', e => e.map(x => x.textContent.trim())),
  ['Todas', 'Praça 1', 'Praça 2']);
await p.click('#mesasPracas button:has-text("Praça 2")');
igual('na Praça 2, só as mesas 6 a 10, todas livres', await p.$$eval('#mesasMapa .mesa-cartao', e => e.map(x =>
  x.querySelector('b').textContent + ':' + x.querySelector('.mesa-info').textContent)),
  ['Mesa 6:livre', 'Mesa 7:livre', 'Mesa 8:livre', 'Mesa 9:livre', 'Mesa 10:livre']);

secao('3. A mesa 7 e o cardápio com fotos');
await p.click('#mesasMapa .mesa-cartao:has-text("Mesa 7")');
await p.waitForSelector('#modalPe button:has-text("Lançar itens")');
await p.click('#modalPe button:has-text("Lançar itens")');
await p.waitForSelector('#npCardapio .garcom-item');
igual('o cardápio: os dois itens, por categoria', await p.$$eval('#npCardapio .garcom-item', e => e.map(x =>
  x.dataset.cat + ' · ' + x.querySelector('.garcom-txt b').textContent)), ['Bebidas · Vinho tinto', 'Pratos · Picanha na chapa']);
verdade('a picanha mostra a foto', await p.$eval('#npCardapio .garcom-item:has-text("Picanha") .garcom-foto',
  b => /icone-512\.png/.test(b.style.backgroundImage)));
await foto(p, '2-cardapio-com-fotos');
await p.click('.mesas-pracas button:has-text("Pratos")');
igual('o filtro "Pratos" deixa só a picanha', await p.$$eval('#npCardapio .garcom-item', e =>
  e.filter(x => x.style.display !== 'none').map(x => x.querySelector('.garcom-txt b').textContent)), ['Picanha na chapa']);
await p.click('#npCardapio .garcom-item:has-text("Picanha") .garcom-foto');
await p.waitForSelector('.garcom-zoom img');
igual('tocar na foto amplia, com o nome, o preço e a descrição', await p.$$eval('.garcom-zoom-caixa > b, .garcom-zoom-caixa > span, .garcom-zoom-caixa > p',
  e => e.map(x => x.textContent.replace(/\s+/g, ' ').trim())), ['Picanha na chapa', 'R$ 80,00', 'Picanha fatiada com farofa e vinagrete']);
await foto(p, '3-foto-ampliada');
await p.click('.garcom-zoom');
verdade('e fecha com um toque', !(await p.$('.garcom-zoom')));

secao('4. Mandar para a cozinha');
await p.click('#npCardapio .garcom-item:has-text("Picanha") button:has-text("+ Pôr")');
await p.click('.mesas-pracas button:has-text("Todos")');
await p.click('#npCardapio .garcom-item:has-text("Vinho") button:has-text("+ Pôr")');
await p.fill('#npObs', 'picanha ao ponto');
await p.click('#modalPe button:has-text("Mandar para a cozinha")');
await p.waitForSelector('#modalPe button:has-text("Fechar conta")', { timeout: 8000 }).catch(() => {});
const ped = await um(`select p.origem, p.status, p.mesa, p.garcom_nome, p.total::text, p.observacao,
    (select string_agg(i.nome || ':' || coalesce(i.garcom_nome, '-'), ' ; ' order by i.ordem) from public.pedido_itens i where i.pedido_id = p.id) itens
  from public.pedidos p where p.salao_id = $1`, [salaoId]);
verdade('o pedido foi gravado', !!ped, 'nada no banco; alertas: ' + p.alertas.join(' | '));
if(ped){
  igual('mesa 7, em preparo, R$ 140, lançado pelo Wilson',
    [ped.origem, ped.status, ped.mesa, ped.garcom_nome, ped.total, ped.observacao],
    ['mesa', 'em_preparo', '7', 'Wilson', '140.00', 'picanha ao ponto']);
  igual('cada item com o nome de quem lançou', ped.itens, 'Picanha na chapa:Wilson ; Vinho tinto:Wilson');
}
igual('a conta da mesa mostra quem lançou e a cozinha', await p.$$eval('.mesa-itens .np-linha small', e => e.map(x => x.textContent.replace(/\s+/g, ' ').trim())),
  ['Wilson · na cozinha', 'Wilson · na cozinha']);
await foto(p, '4-conta-da-mesa');
igual('total da mesa R$ 140', limpo(await p.textContent('#modalCorpo .np-total')), 'Total da mesa R$ 140,00');
await p.click('#modalPe button:has-text("Fechar")');
await p.waitForTimeout(300);
igual('no mapa, a mesa 7 ocupada com o total', limpo(await p.textContent('#mesasMapa .mesa-cartao.ocupada')).replace(/ · \d+ min/, ''),
  'Mesa 7 R$ 140,00 2 item(ns)');

secao('5. Fechar a conta');
await foto(p, '1-mapa-das-mesas');
await p.click('#mesasMapa .mesa-cartao:has-text("Mesa 7")');
await p.click('#modalPe button:has-text("Fechar conta")');
await p.waitForFunction(() => /Total/.test((document.getElementById('fcResumo') || {}).textContent || ''));
await p.fill('#fcPessoas', '2');
await p.click('#fcFormas button:has-text("Crédito")');
igual('a prévia: 140 + 10% = 154, por pessoa 77', limpo(await p.innerText('#fcResumo')),
  'Consumo R$ 140,00 · serviço 10% R$ 14,00 · Total R$ 154,00 Por pessoa (2): R$ 77,00');
await foto(p, '5-fechar-conta');
await p.click('#modalPe button:has-text("Fechar a conta")');
await p.waitForTimeout(2000);
igual('o aviso de mesa fechada', limpo(p.alertas.pop()),
  'Mesa 7 fechada: R$ 154,00 (R$ 77,00 por pessoa). Já entrou no caixa, e a mesa está livre.');
const conta = await um(`select c.fechada_em is not null fechada, c.pagamento, c.taxa_servico::text servico, c.total::text total,
    (select count(*) from public.pedidos x join public.pagamentos pg on pg.comanda_id = x.comanda_id
      where x.conta_id = c.id and pg.forma = 'credito')::int vendas
  from public.mesa_contas c where c.salao_id = $1`, [salaoId]);
igual('no banco: conta fechada no crédito, serviço 14, total 154, a venda no caixa',
  [conta.fechada, conta.pagamento, conta.servico, conta.total, conta.vendas], [true, 'credito', '14.00', '154.00', 1]);
await p.waitForTimeout(300);
igual('a mesa 7 voltou a ficar livre no mapa', limpo(await p.textContent('#mesasMapa .mesa-cartao:has-text("Mesa 7") .mesa-info')), 'livre');

igual('nenhum erro de JavaScript', erros, []);
await nav.close(); await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} de ${passou + falhou} passaram.`);
process.exit(falhou ? 1 : 0);

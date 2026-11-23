/* ===========================================================================
   PediHub — o cartão fidelidade no acompanhamento do pedido (71 + 78)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/fidelidade-tela.test.mjs

   O relato: "fiz vários pedidos e diz que faltam 3". O banco conta só os
   pedidos ENTREGUES do mesmo celular — e o pedido recém-feito ainda não está.
   A tela dizia só "faltam 3", e parecia conta errada. Agora tem de dizer:
     1. quantos já contaram ("7 de 10 pedidos entregues"), com os selos;
     2. que ESTE pedido entra na conta quando for entregue;
     3. depois de entregue, o número sobe e o aviso some;
     4. no 10º entregue, o pedido seguinte sai com o desconto sozinho.
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
await dono.criarConta({ email:`fid-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dona Lia',
  telefone:'+5511' + (950000000 + (Date.now() % 40000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanche da Lia ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3254', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id, SLUG = cr[0].slug;
await dono.inserir('produtos', { salaoId, nome:'X-Salada', preco:20, custo:0, estoque:0, ativo:true, vendaOnline:true });
const prod = (await banco.query(`select id from public.produtos where salao_id = $1`, [salaoId])).rows[0].id;
await banco.query(`update public.saloes set cfg = jsonb_set(coalesce(cfg, '{}'), '{pedidos}',
  coalesce(cfg->'pedidos', '{}') || '{"fidelidade":{"ligado":true,"pedidos":10,"desconto":10}}') where id = $1`, [salaoId]);
const TEL = '119' + String(70000000 + (Date.now() % 9000000)).padStart(8, '0');
// Sete pedidos já ENTREGUES deste celular.
await banco.query(`insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status)
  select $1, 700 + g, 'Bia', $2, 'retirada', 20, 0, 20, 'pix', 'entregue' from generate_series(1, 7) g`, [salaoId, TEL]);

const cliente = aba();
const pedir = () => cliente.chamar('fazer_pedido', { p_slug: SLUG, p_pedido: { nome:'Bia', telefone: TEL,
  entrega:'retirada', pagamento:'pix', itens:[{ produto: prod, quantidade: 1 }] } });

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctx = await nav.newContext({ viewport:{ width:412, height:915 }, isMobile:true, hasTouch:true });
const p = await ctx.newPage();
p.on('pageerror', e => erros.push(e.message));
await p.goto(BASE + '/cardapio.html?salao=' + SLUG);
await p.waitForTimeout(2500);
const cartao = async token => {
  await p.evaluate(t => abrirAcompanhar(t), token);
  await p.waitForFunction(() => document.querySelector('#acompanharCorpo .fid-cartao'), null, { timeout: 10000 });
  return p.evaluate(() => {
    const c = document.querySelector('#acompanharCorpo .fid-cartao');
    return { texto: c.innerText.replace(/\s+/g, ' ').trim(),
             cheios: c.querySelectorAll('.fid-selos .on').length,
             selos: c.querySelectorAll('.fid-selos span').length };
  });
};

secao('1. Sete entregues, e o oitavo acabou de ser feito');
const r8 = await pedir();
const c8 = await cartao(r8.token);
verdade('diz quantos já contaram: 7 de 10 pedidos entregues', /7 de 10 pedidos entregues/.test(c8.texto), c8.texto);
igual('com 7 selos cheios de 10', [c8.cheios, c8.selos], [7, 10]);
verdade('faltam 3', /Faltam 3 para ganhar 10% de desconto/.test(c8.texto), c8.texto);
verdade('e avisa que ESTE pedido entra quando for entregue', /Este pedido entra na conta quando for entregue/.test(c8.texto), c8.texto);

if(process.env.FOTOS){ await p.waitForTimeout(900); await p.screenshot({ path: path.join(process.env.FOTOS, 'fidelidade.png') }); }

secao('2. O oitavo é entregue');
await banco.query(`update public.pedidos set status = 'entregue', entregue_em = now() where token = $1`, [r8.token]);
const c8b = await cartao(r8.token);
verdade('o número sobe: 8 de 10, faltam 2', /8 de 10/.test(c8b.texto) && /Faltam 2/.test(c8b.texto), c8b.texto);
verdade('e o aviso "este pedido entra" some', !/Este pedido entra/.test(c8b.texto), c8b.texto);

secao('3. No 10º entregue, o próximo sai com o desconto');
await banco.query(`insert into public.pedidos (salao_id, numero, nome, telefone, tipo_entrega, subtotal, taxa_entrega, total, pagamento, status)
  select $1, 800 + g, 'Bia', $2, 'retirada', 20, 0, 20, 'pix', 'entregue' from generate_series(1, 2) g`, [salaoId, TEL]);
const r11 = await pedir();
igual('o 11º sai com 10% sozinho: 20 − 2 = 18', [Number(r11.desconto), Number(r11.total), r11.fidelidade], [2, 18, true]);
await p.evaluate(t => abrirAcompanhar(t), r11.token);
await p.waitForTimeout(1500);
verdade('e o acompanhamento mostra a linha "Desconto fidelidade"',
  /Desconto fidelidade/.test(limpo(await p.textContent('#acompanharCorpo'))), limpo(await p.textContent('#acompanharCorpo')).slice(0, 300));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

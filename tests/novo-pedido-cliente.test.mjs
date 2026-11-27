/* ===========================================================================
   PediHub — o Novo pedido do painel: o cliente cadastrado, o cliente novo e
   os adicionais organizados

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/novo-pedido-cliente.test.mjs

   "Não posso achar o cliente já cadastrado? Nem cadastrar na hora?" e, nos
   adicionais, "tem que melhorar também" (eram botões soltos):
     1. digitando parte do nome, aparece a ficha; um toque preenche nome e
        WhatsApp, e mostra "✓ Cliente cadastrado · N pedidos · 🎂";
     2. escolhida a entrega, o último endereço dele já vem nos campos;
     3. digitado o WhatsApp de quem tem ficha, ela é reconhecida sozinha;
     4. WhatsApp novo: "Cliente novo", com o aniversário opcional — lançado o
        pedido, a ficha nasce com o nome, o WhatsApp e o aniversário;
     5. os adicionais em linhas (marcação, nome, preço), a observação do item
        e a quantidade — e o pedido grava os dois.
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
const um = async (sql, args) => (await banco.query(sql, args)).rows[0];

const m = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dono = aba();
await dono.criarConta({ email:`npcli-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono do Balcão',
  telefone:'+5511' + (910000000 + (Date.now() % 9000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao: 'Lanchonete do Balcão ' + m, p_tipo: 'restaurante',
  p_telefone:'(11) 98111-3330', p_documento:null, p_origem:null });
const salaoId = cr[0].salao_id;
await dono.inserir('produtos', { salaoId, nome:'PRENSÃO', preco:30, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria:'Lanches' });
await dono.inserir('produtos', { salaoId, nome:'Coca lata', preco:6, custo:0, estoque:0, ativo:true, vendaOnline:true, categoria:'Bebidas' });
await dono.atualizar('saloes', salaoId, { whatsapp:'(11) 98111-3330' });
const prods = await dono.lista('produtos', { salaoId });
const prensao = prods.find(x => x.nome === 'PRENSÃO').id, coca = prods.find(x => x.nome === 'Coca lata').id;
await dono.chamar('salvar_opcoes_do_produto', { p_produto: prensao, p_grupos: [
  { nome:'Adicionais', min:0, max:14, regra:'soma', opcoes:[{ nome:'Calabresa', preco:'12' }, { nome:'Bacon', preco:'13' }, { nome:'Ovo', preco:'3' }] }] });

// O Carlos já pediu antes, com entrega: tem ficha (pelo WhatsApp) e endereço.
const TEL = '11997301462';
await dono.chamar('lancar_pedido', { p_salao: salaoId, p_pedido: { origem:'telefone', nome:'Carlos Lima', telefone: TEL,
  entrega:'entrega', pagamento:'dinheiro', endereco:{ rua:'Rua Cerquilho', numero:'24', bairro:'Cidade Nova I', referencia:'Portão branco' },
  itens:[{ produto: coca, quantidade: 1 }] } });
const hojeSP = new Date(Date.now() - 3 * 3600e3).toISOString().slice(0, 10);
await banco.query(`update public.clientes set nascimento = $2 where salao_id = $1 and telefone = $3`,
  [salaoId, '1990' + hojeSP.slice(4), TEL]);

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const p = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
p.on('pageerror', e => erros.push(e.message));
p.on('dialog', x => x.accept());
await p.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  if(location.pathname.endsWith('app.html')) localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, dono.sessao()]);
await p.goto(BASE + '/app.html');
await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.clientes)
  && bd.clientes.some(c => c.nome === 'Carlos Lima'), null, { timeout: 20000 });
await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); window.tocarSomDePedido = () => {}; irPara('pedidos'); });
await p.waitForTimeout(400);
await p.evaluate(() => abrirNovoPedido());
await p.waitForSelector('#npNome');

secao('1. Buscar o cliente pelo nome');
await p.fill('#npNome', 'carl');
await p.waitForSelector('#npSugestoes .np-sug-item', { timeout: 4000 }).catch(() => {});
igual('a ficha aparece na busca', await p.$$eval('#npSugestoes .np-sug-item b', e => e.map(x => x.textContent)), ['Carlos Lima']);
await p.click('#npSugestoes .np-sug-item');
await p.waitForTimeout(900);
igual('um toque preenche o nome e o WhatsApp', [await p.inputValue('#npNome'), await p.inputValue('#npTel')],
  ['Carlos Lima', '(11) 99730-1462']);
const card = limpo(await p.textContent('#npCliente'));
verdade('"✓ Cliente cadastrado", com os pedidos e o aniversário', /Cliente cadastrado: Carlos Lima · 1 pedido · último em \d\d\/\d\d · 🎂 faz aniversário hoje/.test(card), card);

secao('2. A entrega já vem com o último endereço');
await p.check('input[name="npModo"][value="entrega"]');
await p.waitForTimeout(300);
igual('rua, número, bairro e referência', [await p.inputValue('#npRua'), await p.inputValue('#npNum'),
  await p.inputValue('#npBairro'), await p.inputValue('#npRef')], ['Rua Cerquilho', '24', 'Cidade Nova I', 'Portão branco']);

secao('3. Pelo WhatsApp, reconhece sozinho');
await p.evaluate(() => npTrocarCliente());
await p.fill('#npTel', '(11) 99730-1462');
await p.waitForTimeout(900);
igual('o nome vem da ficha', await p.inputValue('#npNome'), 'Carlos Lima');
verdade('e aparece "Cliente cadastrado"', /Cliente cadastrado: Carlos Lima/.test(limpo(await p.textContent('#npCliente'))));

secao('4. Cliente novo: o cadastro na hora');
await p.evaluate(() => npTrocarCliente());
await p.check('input[name="npModo"][value="retirada"]');
await p.fill('#npNome', 'Bruna Nova');
await p.fill('#npTel', '(11) 98888-7766');
await p.waitForTimeout(700);
verdade('"Cliente novo — o cadastro é criado com o pedido"', /Cliente novo — o cadastro é criado com o pedido/.test(limpo(await p.textContent('#npCliente'))));
verdade('com o aniversário opcional', !!(await p.$('#npNasc')));
await p.fill('#npNasc', '1995-03-10');

secao('5. Os adicionais organizados, a observação e a quantidade');
await p.click('#npCardapio .np-item:has-text("PRENSÃO")');
await p.waitForSelector('#npFolha .np-op');
const linhas = await p.$$eval('#npFolha .np-op', e => e.map(b => [b.querySelector('.np-op-nome').textContent.trim(),
  b.querySelector('.np-op-preco').textContent.replace(/\s+/g, ' ').trim(), getComputedStyle(b).width === getComputedStyle(b.parentElement).width]));
igual('cada adicional numa linha da largura toda, com o preço', linhas,
  [['Calabresa', '+ R$ 12,00', true], ['Bacon', '+ R$ 13,00', true], ['Ovo', '+ R$ 3,00', true]]);
await p.click('#npFolha .np-op:has-text("Bacon")');
await p.click('#npFolha .np-op:has-text("Ovo")');
verdade('o grupo diz quantos foram escolhidos', /2 escolhidos/.test(limpo(await p.textContent('#npFolha .np-grupo-t'))));
await p.fill('#npObsItem', 'sem cebola');
await p.click('#npFolha button[aria-label="Mais um"]');
await p.click('#npFolha .np-op:has-text("Calabresa")');   // marcar de novo não pode apagar a observação
igual('a observação não se perde ao marcar outro', await p.inputValue('#npObsItem'), 'sem cebola');
await p.click('#npFolha .np-op:has-text("Calabresa")');
verdade('o total: (30 + 13 + 3) × 2', /Pôr no pedido · R\$\s*92,00/.test(limpo(await p.textContent('#npFolha .np-folha-pe'))),
  limpo(await p.textContent('#npFolha .np-folha-pe')));
await p.click('#npFolha button:has-text("Pôr no pedido")');
await p.waitForTimeout(300);
verdade('na lista: 2 de PRENSÃO, com os adicionais e a observação',
  /PRENSÃO — Adicionais: Bacon, Ovo \(sem cebola\)/.test(limpo(await p.textContent('#npLista'))) && /92,00/.test(limpo(await p.textContent('#npLista'))),
  limpo(await p.textContent('#npLista')));
await p.evaluate(() => lancarNovoPedido());
await p.waitForTimeout(2500);

const ficha = await um(`select nome, nascimento::text n from public.clientes where salao_id = $1 and telefone = '11988887766'`, [salaoId]);
igual('a ficha da Bruna nasceu com o pedido, com o aniversário', ficha, { nome: 'Bruna Nova', n: '1995-03-10' });
const item = await um(`select i.quantidade, i.observacao from public.pedido_itens i join public.pedidos p on p.id = i.pedido_id
  where p.salao_id = $1 and p.nome = 'Bruna Nova'`, [salaoId]);
igual('o item grava a quantidade e a observação', item, { quantidade: 2, observacao: 'sem cebola' });

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
await banco.end();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

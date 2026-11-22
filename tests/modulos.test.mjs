/* ===========================================================================
   PediHub — a loja (cardápio) ligada e desligada, e o cfg que não derruba

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/modulos.test.mjs

   Herdado do AgendaPro, onde a casa tinha dois módulos (serviços e loja). No
   PediHub sobra o que vale para o restaurante:
     1. o BANCO peneira a lista, e não só a tela: loja desligada não publica o
        cardápio para quem abrir o inspetor;
     2. a peneira é de LETRA. `(cfg->>'loja')::boolean` LEVANTA com lixo, e
        quem cai é a `vitrine()` — a única porta do link da cliente. O
        restaurante inteiro sai do ar por um caractere;
     3. a CAPA do restaurante abre com o botão de pedir, os itens do cardápio
        e nada do salão (agendar, horários, quem atende).
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

const arte = (a, b) => 'data:image/svg+xml;base64,' + Buffer.from(
  `<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360">`
  + `<rect width="640" height="360" fill="${a}"/>`
  + `<circle cx="320" cy="180" r="120" fill="${b}"/></svg>`).toString('base64');

const marca = Date.now().toString(36) + Math.floor(Math.random()*1000);
const dona = novaAba();
await dona.criarConta({ email:`mod-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Rita Alves', telefone:'+5511' + (900000000 + (Date.now() % 89999999)) });
const cr = await dona.chamar('criar_salao', { p_nome_salao:'Casa Dupla',
  p_tipo:'restaurante', p_telefone:'(11) 98111-3251', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;

/* ⚠ SÓ DOIS PRODUTOS, DE PROPÓSITO. A vitrine da capa mostra até quatro,
   então com dois não "sobra" nada — e é exatamente aí que o "Ver todos os
   produtos" some, se ele ainda depender de sobrar. A tela da loja é a única
   que deixa mudar quantidade e enviar o pedido: vitrine sem saída é vitrine
   quebrada, e um restaurante pequeno é quem mais cai nisso. */
await dona.inserir('produtos', { salaoId: SALAO, nome:'X-Burger',
  preco:45, custo:20, ativo:true, vendaOnline:true, foto: arte('#065F46','#34D399') });
await dona.inserir('produtos', { salaoId: SALAO, nome:'Suco de laranja',
  preco:60, custo:25, ativo:true, vendaOnline:true });

const COR = '#6D28D9';
await dona.atualizar('saloes', SALAO, {
  whatsapp:'(11) 98111-3251',
  endereco:{ logradouro:'Rua Avanhandava', numero:'10',
             bairro:'Cidade Nova', cidade:'Itu', uf:'SP' },
  logo: arte('#4C1D95', '#A78BFA'),
  capa: arte('#2E1065', '#7C3AED'),
  cfg: { diasLiberados:30, cor: COR } });
ok('restaurante criado: 2 itens no cardápio, WhatsApp e a cor dele');

const vitrine = async () => {
  const v = await dona.chamar('vitrine', { p_slug: SLUG });
  return Array.isArray(v) ? v[0] : v;
};
const ligar = async (servicos, loja) => {
  const sl = (await dona.lista('saloes', { id: SALAO }))[0];
  const cfg = Object.assign({}, sl.cfg);
  if(servicos === undefined) delete cfg.usaServicos; else cfg.usaServicos = servicos;
  if(loja === undefined)     delete cfg.loja;        else cfg.loja = loja;
  await dona.atualizar('saloes', SALAO, { cfg });
};

/* ══════════════════════════════════════════════════════════════════════════
   1 — O BANCO
   ══════════════════════════════════════════════════════════════════════════ */
secao('1 · A vitrine() peneira as listas, e não só a tela');

let v = await vitrine();
igual('sem nenhuma chave, os serviços estão ligados', v.salao.usaServicos, true);
igual('e a loja também', v.salao.loja, true);
igual('nenhum serviço (restaurante não tem)', (v.servicos || []).length, 0);
igual('e os dois produtos', (v.produtos || []).length, 2);

await ligar(false, undefined);
v = await vitrine();
igual('desligados os serviços, a vitrine diz que não', v.salao.usaServicos, false);
/* ⚠ A LISTA SOME DA RESPOSTA, e não só do desenho. Deixar os serviços saírem
   e pedir para a página não os desenhar publica o catálogo de uma casa que
   decidiu não trabalhar com serviços — basta abrir o inspetor. */
igual('e a lista de serviços vem VAZIA', (v.servicos || []).length, 0);
igual('os produtos continuam inteiros', (v.produtos || []).length, 2);

await ligar(undefined, false);
v = await vitrine();
igual('desligada a loja, a vitrine diz que não', v.salao.loja, false);
igual('e a lista de produtos vem vazia', (v.produtos || []).length, 0);

await ligar(false, false);
v = await vitrine();
igual('com os dois desligados, nenhum serviço', (v.servicos || []).length, 0);
igual('e nenhum produto', (v.produtos || []).length, 0);
verdade('mas a casa continua respondendo: nome, logo e endereço',
  !!v.salao && v.salao.nome === 'Casa Dupla' && !!v.salao.logo);

/* ══════════════════════════════════════════════════════════════════════════
   2 — A PENEIRA É DE LETRA
   ══════════════════════════════════════════════════════════════════════════ */
secao('2 · Lixo no cfg não derruba a página da cliente');

/* ⚠ ESTA É A VERIFICAÇÃO QUE PAGA O ARQUIVO.

   O `loja` nasceu com `(s.cfg->>'loja')::boolean`, e ficou anos sem morder
   porque NENHUMA TELA escrevia a chave: o `cfg` só continha o que o painel
   punha. A partir do momento em que o dono liga e desliga isto, a chave passa
   a existir — e `'abacaxi'::boolean` LEVANTA no Postgres, não devolve nulo.

   Quem cai é a `vitrine()`, que é a única porta da página da cliente. Não é
   "a loja some": é a casa inteira fora do ar, com o link que ela mandou para
   as clientes no WhatsApp. */
await ligar('talvez', 'sei la');
/* O `try` não é frouxidão: com `::boolean` a chamada LEVANTA, e sem o `catch`
   o arquivo morre aqui com um rastro de pilha — a verificação nunca chega a
   dizer o que estava medindo. Assim ela reprova falando. */
try{ v = await vitrine(); }
catch(e){ v = null; nao('com lixo nas duas chaves, a vitrine ainda responde',
                        'a vitrine LEVANTOU: ' + e.message); }
if(v) verdade('com lixo nas duas chaves, a vitrine ainda responde',
              !!(v && v.salao));
v = v || { salao:{}, servicos:[], produtos:[] };
igual('e o lixo deixa LIGADO, que é o lado seguro', v.salao.usaServicos, true);
igual('a loja idem', v.salao.loja, true);
igual('o cardápio volta inteiro', (v.produtos||[]).length, 2);

await ligar('FALSE', ' Não ');
v = await vitrine();
igual('"FALSE" com maiúscula desliga', v.salao.usaServicos, false);
igual('" Não " com espaço e acento também', v.salao.loja, false);

await ligar('0', 'f');
v = await vitrine();
igual('"0" desliga', v.salao.usaServicos, false);
igual('"f" desliga', v.salao.loja, false);

/* ══════════════════════════════════════════════════════════════════════════
   ⚠ E A REGRA VALE PARA TODA CHAVE DA VITRINE, NÃO SÓ PARA ESTAS DUAS

   Depois de peneirar `loja` e `usaServicos` eu parei — consertei a que estava
   mexendo e não varri o resto. Sobraram quatro com `::` cru, e a medição num
   banco de verdade mostrou as quatro derrubando a `vitrine()` inteira.

   Este laço existe para a próxima chave: quem acrescentar uma sexta e usar
   `::boolean` reprova aqui, e não no dia em que um restaurante sair do ar.

   ⚠ O LADO SEGURO NÃO É O MESMO EM TODAS, e por isso a tabela diz qual é.
   `precoNaCapa` é o único em que o erro custa dinheiro: lixo não pode
   publicar um valor que o dono não mandou mostrar. */
secao('2b · Nenhuma chave do cfg pode derrubar a vitrine');

const COM_LIXO = [
  ['loja',        true,  'a loja fica ligada'],
  ['usaServicos', true,  'os serviços ficam ligados'],
  ['brilho',      true,  'o brilho fica ligado, que é o visual de hoje'],
  ['precoNaCapa', false, 'o preço NÃO é publicado — lixo não revela valor'],
  ['fitaBrilho',  true,  'o brilho da fita fica ligado'],
  ['capaFoco',    null,  'o enquadramento vira nulo, e a página usa o padrão'],
  ['veu',         null,  'o véu vira nulo, e a página usa o padrão'],
];
for(const [chave, esperado, frase] of COM_LIXO){
  const sl = (await dona.lista('saloes', { id: SALAO }))[0];
  const limpo = Object.assign({}, sl.cfg);
  delete limpo.usaServicos; delete limpo.loja;
  await dona.atualizar('saloes', SALAO,
    { cfg: Object.assign({}, limpo, { [chave]: 'abacaxi' }) });
  let resp = null, caiu = null;
  try{ resp = await vitrine(); }catch(e){ caiu = e; }
  if(caiu){
    nao(`com lixo em "${chave}", a vitrine ainda responde`,
        'a vitrine LEVANTOU: ' + caiu.message);
  } else {
    ok(`com lixo em "${chave}", a vitrine ainda responde`);
    igual(`  e ${frase}`, resp.salao[chave] === undefined ? null : resp.salao[chave],
          esperado);
  }
}
await ligar(undefined, undefined);

/* ══════════════════════════════════════════════════════════════════════════
   3 — A CAPA DO RESTAURANTE
   ══════════════════════════════════════════════════════════════════════════ */
secao('3 · A capa do restaurante, num celular de 412px');

const nav = await chromium.launch({ executablePath: CHROMIUM });
const erros = [];
const ctx = await nav.newContext({ viewport:{ width:412, height:915 }, isMobile:true, hasTouch:true });
const p = await ctx.newPage();
p.on('pageerror', e => erros.push(e.message));
await p.goto(BASE + '/cardapio.html?salao=' + SLUG);
await p.waitForFunction(() => {
  const m = document.querySelector('#capaMarca');
  return m && m.textContent.trim().length > 0;
}, null, { timeout: 15000 });
await p.waitForTimeout(600);
const m = await p.evaluate(() => ({
  principal: ((document.querySelector('#capaBoas .boas-cta') || {}).textContent || '').trim(),
  cartoes: document.querySelectorAll('#capaLoja .pr-cartao').length,
  texto: document.getElementById('p-capa').innerText,
  rolaDeLado: document.documentElement.scrollWidth > document.documentElement.clientWidth,
}));
console.log('      CAPA: ' + JSON.stringify({ principal: m.principal, cartoes: m.cartoes }));
verdade('o botão principal é o de pedir', /pedido|card[aá]pio/i.test(m.principal), m.principal);
igual('os dois itens do cardápio na capa', m.cartoes, 2);
verdade('nada do salão na capa (agendar, horários, quem atende)',
  !/agendar|meus horários|quem atende/i.test(m.texto), m.texto.slice(0, 300));
verdade('nada vaza para o lado', !m.rolaDeLado);

await ligar(undefined, false);
await p.reload();
await p.waitForFunction(() => {
  const mm = document.querySelector('#capaMarca');
  return mm && mm.textContent.trim().length > 0;
}, null, { timeout: 15000 });
await p.waitForTimeout(600);
const sem = await p.evaluate(() => document.querySelectorAll('.pr-cartao').length);
igual('loja desligada: nenhum item aparece na capa', sem, 0);
await ligar(undefined, undefined);

igual('nenhum erro de JavaScript', erros, []);
await ctx.close();
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

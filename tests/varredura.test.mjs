/* ===========================================================================
   PediHub — varredura das duas áreas, tela por tela

     bash tests/bancada/subir.sh
     PLAYWRIGHT=/caminho/node_modules/playwright node tests/varredura.test.mjs

   As outras suítes olham um assunto de cada vez: a agenda, a segurança, a
   aparência. Esta faz o contrário — passa por TODAS as telas do dono e da
   cliente fazendo o que uma pessoa faria, e reprova ao primeiro erro de
   JavaScript, campo que não grava, lista que não atualiza ou botão que não
   responde.

   É a suíte que pega o defeito que ninguém procurou: o que aparece quando se
   abre a comanda depois de mudar de dia, quando se apaga o serviço que está
   dentro de um agendamento, quando o restaurante não tem nada cadastrado ainda.
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
const d = novaAba();
await d.criarConta({ email:`var-${marca}@teste.com`, senha:'minhasenhaboa',
  nome:'Ju Barbosa', telefone:'+5511' + (100000000 + (Date.now() % 89999999)) });
const cr = await d.chamar('criar_salao', { p_nome_salao:'Restaurante Varredura ' + marca,
  p_tipo:'salao', p_telefone:'(11) 3333-4444', p_documento:null, p_origem:null });
const SALAO = cr[0].salao_id, SLUG = cr[0].slug;
const PROF = (await d.lista('profissionais', { salaoId: SALAO }))[0];

const nav = await chromium.launch({ executablePath: CHROMIUM });
const ctx = await nav.newContext({ viewport:{ width:1360, height:900 } });
const pg = await ctx.newPage();

/* Todo erro conta: os que estouram na página e os que só sussurram no
   console. Muito defeito de tela vive inteiro dentro de um console.error que
   ninguém abre. */
const erros = [];
pg.on('pageerror', e => erros.push('pageerror: ' + e.message));
pg.on('console', m => {
  if(m.type() !== 'error') return;
  const t = m.text();
  // A bancada devolve 400 de propósito em alguns testes de recusa; o que
  // interessa aqui é erro de código, não recusa esperada do banco.
  if(/Failed to load resource/.test(t)) return;
  erros.push('console: ' + t.slice(0, 160));
});
const semErro = (onde) => {
  if(!erros.length){ ok(onde + ': sem erro de JavaScript'); return; }
  nao(onde + ': sem erro de JavaScript', erros.join('\n      '));
  erros.length = 0;
};

// A comanda e o caixa estão DESLIGADOS na plataforma (COMANDA_LIGADA no
// app.html); este teste mede as telas deles, então liga só nesta aba.
await pg.addInitScript(() => { try{ sessionStorage.setItem('pedihub.comanda', '1'); }catch(e){} });
await pg.addInitScript(([b, s]) => {
  window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' };
  localStorage.setItem('pedihub.sessao', JSON.stringify(s));
}, [BASE, d.sessao()]);
await pg.goto(BASE + '/app.html');
await pg.waitForTimeout(3500);

const ir = async (k) => { await pg.evaluate(x => irPara(x), k); await pg.waitForTimeout(900); };
const fechar = async () => { await pg.evaluate(() => fecharModal()); await pg.waitForTimeout(400); };
const salvouSemErro = async () => { await pg.waitForTimeout(2200); };

/* ══════════════════════════════════════════════════════════════════════════
   ÁREA DO RESTAURANTE — cada tela, com o restaurante ainda VAZIO

   O restaurante recém-criado não tem serviço, não tem cliente, não tem jornada. É
   o estado em que todo dono vê o sistema pela primeira vez, e é onde a tela
   costuma quebrar por assumir que alguma lista tem pelo menos um item.
   ══════════════════════════════════════════════════════════════════════════ */
secao('Restaurante vazio: todas as telas abrem');

for(const [chave, rotulo] of [['pedidos','Pedidos'], ['caixa','Caixa'],
    ['clientes','Clientes'], ['produtos','Cardápio'], ['equipe','Equipe'],
    ['salao','Meu negócio'], ['publico','Ver como cliente'], ['plano','Plano']]){
  await ir(chave);
  const viva = await pg.evaluate(k => {
    const s = document.getElementById('t-' + k) || document.querySelector('.tela.on');
    return !!s && s.offsetParent !== null;
  }, chave);
  verdade(rotulo + ' abre sem quebrar', viva);
}
semErro('restaurante vazio');

/* ══════════════════════════════════════════════════════════════════════════
   CADASTROS — criar, editar, desativar, pelo caminho da tela
   ══════════════════════════════════════════════════════════════════════════ */
// PediHub: saiu "Cadastrar serviço pela tela" (o cardápio tem o produto-cadastro).

secao('Cadastrar cliente pela tela');
await ir('clientes');
await pg.evaluate(() => abrirCliente());
await pg.waitForTimeout(600);
await pg.fill('#kNome', 'Cliente da Recepção');
await pg.fill('#kTel', '(11) 98888-7777');
await pg.fill('#kObs', 'Alergia a amônia');
await pg.evaluate(() => salvarCliente());
await salvouSemErro();

const cls = await d.lista('clientes', { salaoId: SALAO });
igual('a ficha foi para o banco', cls.length, 1);
igual('com o nome', cls[0] && cls[0].nome, 'Cliente da Recepção');
/* ⚠ O TELEFONE VAI SÓ EM DÍGITOS — foi bug medido, não zelo.
   Guardado "(11) 98888-7777", a mesma pessoa marcando pelo link (onde o
   banco procura por dígitos) virava uma SEGUNDA ficha, e o histórico dela
   rachava ao meio. */
verdade('com o telefone só em dígitos, como o banco espera',
  cls[0] && /^\d{10,13}$/.test(String(cls[0].telefone || '')),
  JSON.stringify(cls[0] && cls[0].telefone));
igual('e com a observação', cls[0] && cls[0].obs, 'Alergia a amônia');
semErro('clientes');

secao('Cliente sem telefone, e a mesma pessoa em dois caminhos');

/* ⚠ O SEGUNDO CLIENTE SEM TELEFONE NÃO GRAVAVA.
   Campo vazio virava string vazia, que NÃO é nula — e a trava do banco é
   `where telefone is not null`. A recepção levava "duplicate key value
   violates unique constraint ux_cli_tel" na cara, em inglês, ao cadastrar a
   segunda pessoa que passou sem deixar número. Em restaurante isso é rotina. */
for(const quem of ['Passante Um', 'Passante Dois']){
  await pg.evaluate(() => abrirCliente());
  await pg.waitForTimeout(500);
  await pg.fill('#kNome', quem);
  await pg.fill('#kTel', '');
  await pg.evaluate(() => salvarCliente(null));
  await salvouSemErro();
}
const semTel = (await d.lista('clientes', { salaoId: SALAO }))
  .filter(c => /Passante/.test(c.nome));
igual('duas pessoas sem telefone são cadastradas sem brigar', semTel.length, 2);
verdade('e o telefone vazio virou NULO, não texto vazio',
  semTel.every(c => c.telefone === null || c.telefone === undefined),
  JSON.stringify(semTel.map(c => c.telefone)));

/* E a mesma pessoa, cadastrada na recepção e marcando pelo link, tem de cair
   numa ficha só. */
await pg.evaluate(() => abrirCliente());
await pg.waitForTimeout(500);
await pg.fill('#kNome', 'Maria das Duas Portas');
await pg.fill('#kTel', '(11) 97777-6666');
await pg.evaluate(() => salvarCliente(null));
await salvouSemErro();
{
  const antes = (await d.lista('clientes', { salaoId: SALAO }))
    .filter(c => String(c.telefone || '') === '11977776666').length;
  igual('a recepção gravou a ficha em dígitos', antes, 1);
}

// PediHub: saíram a jornada da equipe, marcar pela recepção e a comanda nascida do atendimento.

/* ══════════════════════════════════════════════════════════════════════════
   MEU RESTAURANTE — os campos que a cliente vê
   ══════════════════════════════════════════════════════════════════════════ */
secao('Meu negócio: endereço e identidade');

await ir('salao');
await pg.fill('#cNome', 'Restaurante Varredura Editado');
await pg.fill('#cRua', 'Rua Avanhandava');
await pg.fill('#cNum', '10');
await pg.fill('#cBairro', 'Cidade Nova');
await pg.fill('#cCidade', 'Itu');
await pg.evaluate(() => salvarCadastroSalao());
await salvouSemErro();

const sl = (await d.lista('saloes', { id: SALAO }))[0];
igual('o nome do restaurante gravou', sl.nome, 'Restaurante Varredura Editado');
const end = sl.endereco || {};
igual('a rua gravou', end.logradouro, 'Rua Avanhandava');
igual('o número gravou', end.numero, '10');
igual('a cidade gravou', end.cidade, 'Itu');
semErro('meu restaurante');

/* ══════════════════════════════════════════════════════════════════════════
   ÁREA DA CLIENTE
   ══════════════════════════════════════════════════════════════════════════ */
// O celular do cliente (o link é visto no telefone).
const cel = await nav.newContext({ viewport:{ width:390, height:844 },
                                   isMobile:true, hasTouch:true });
secao('Área da cliente: restaurante que não existe');
{
  const p = await cel.newPage();
  const e2 = [];
  p.on('pageerror', x => e2.push(x.message));
  await p.addInitScript(b => { window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' }; }, BASE);
  await p.goto(BASE + '/cardapio.html?salao=nao-existe-mesmo-' + marca);
  await p.waitForTimeout(2500);
  verdade('explica que não achou, em vez de ficar em branco',
    await p.evaluate(() => /não encontrado/i.test(document.body.textContent)));
  igual('e sem erro de JavaScript', e2.length ? e2.join(' | ') : 0, 0);
  await p.close();
}

secao('Comanda: a conta tem que fechar');

// Uma comanda de balcão com um item do cardápio de R$ 110.
const cliCmd = (await d.lista('clientes', { salaoId: SALAO }))[0];
const prodCmd = await d.inserir('produtos', { salaoId: SALAO, nome:'Rodízio', preco:110, custo:0, estoque:0,
  ativo:true, vendaOnline:true });
const cmdNova = await d.inserir('comandas', { salaoId: SALAO, clienteId: cliCmd ? cliCmd.id : null });
await d.inserir('comanda_itens', { comandaId: cmdNova.id, tipo:'produto', produtoId: prodCmd.id,
  descricao:'Rodízio', qtd:1, precoUnit:110 });
await pg.reload();
await pg.waitForTimeout(3500);
erros.length = 0;
await ir('caixa');
const cmd = (await d.lista('comandas', { salaoId: SALAO })).find(c => c.id === cmdNova.id);
verdade('a comanda aberta aparece no caixa', !!cmd);

if(cmd){
  await pg.evaluate(id => abrirComanda(id), cmd.id);
  await pg.waitForTimeout(900);

  // Um desconto de 10 sobre o item de 110.
  await pg.evaluate(id => mudarDesconto(id, '10'), cmd.id);
  await pg.waitForTimeout(1800);
  const comDesconto = (await d.lista('comandas', { salaoId: SALAO }))
    .find(c => c.id === cmd.id);
  igual('o desconto gravou', Number(comDesconto && comDesconto.desconto), 10);

  await pg.evaluate(id => abrirComanda(id), cmd.id);
  await pg.waitForTimeout(900);
  const naTela = await pg.evaluate(() =>
    document.getElementById('modalCorpo').textContent.replace(/\s+/g, ' '));
  verdade('e a tela mostra o total já com o desconto (110 − 10 = 100)',
    /100,00/.test(naTela), naTela.slice(0, 200));
  await fechar();
  await salvouSemErro();
}
semErro('comanda');

// PediHub: saíram "serviço e profissional em uso", bloquear horário e a lista de espera.

await nav.close();

console.log('');
if(falhou){ console.log(`✗ ${falhou} de ${passou + falhou} falharam.`); process.exit(1); }
console.log(`✓ ${passou} verificações de varredura.`);

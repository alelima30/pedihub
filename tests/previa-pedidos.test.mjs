/* ===========================================================================
   PediHub — a prévia do painel igual ao link de pedidos, e o destaque do
   endereço configurável (85)

     bash tests/bancada/subir.sh          (deixe rodando noutro terminal)
     node tests/previa-pedidos.test.mjs

   "Tá diferente do link real... tem que estar idêntico, e ter toda a
   configuração que foi usada, organizada para qualquer um entender — por
   exemplo a cor e a moldura do endereço." Numa lanchonete de pedidos (lista,
   números, promoção, dúvidas e tempo de entrega):
     1. a prévia mostra os blocos do link de pedidos, na mesma ordem: Dúvidas
        nos atalhos, o tempo de entrega, "Primeira vez aqui?", a PROMOÇÃO, o
        "Do cardápio" em lista e o "Ver o cardápio completo"; a fita diz
        "Continuar" — e nada da vitrine de loja ("Produtos em destaque",
        "Enviar" pelo WhatsApp);
     2. "Endereço embaixo do nome" em Topo e capa: Automático, Brilho nas
        letras, Faixa clara, Sem destaque — a prévia acompanha na hora;
     3. salvo, vai ao banco e o link usa o mesmo;
     4. o botão "Mudar a cor da rua e do bairro" leva à cor da rua.
   =========================================================================== */
import fs from 'node:fs'; import path from 'node:path'; import { fileURLToPath } from 'node:url'; import { createRequire } from 'node:module';
const exigir = createRequire(import.meta.url); const { chromium } = exigir(process.env.PLAYWRIGHT || 'playwright');
const RAIZ = path.dirname(path.dirname(fileURLToPath(import.meta.url))); const BASE = 'http://127.0.0.1:8123'; 
function aba(){ const g = {}; const j = { PEDIHUB:{ url:BASE, chave:'k', ambiente:'bancada' }, localStorage:{ getItem:k=>(k in g?g[k]:null), setItem:(k,v)=>{g[k]=String(v)}, removeItem:k=>{delete g[k]} } };
  new Function('window','console','fetch','localStorage', fs.readFileSync(path.join(RAIZ,'dados.js'),'utf8'))(j, { info(){}, error(){}, log(){} }, fetch, j.localStorage); return j.Dados; }
const m = Date.now().toString(36) + Math.floor(Math.random() * 1000);
const dono = aba(); await dono.criarConta({ email:`cmp-${m}@teste.com`, senha:'minhasenhaboa', nome:'Dono Cmp', telefone:'+5511' + (960000000 + (Date.now() % 30000000)) });
const cr = await dono.chamar('criar_salao', { p_nome_salao:'Paivas Teste ' + m, p_tipo:'restaurante', p_telefone:'(11) 4019-0516', p_documento:null, p_origem:null });
const S = cr[0].salao_id, SLUG = cr[0].slug;
const it = (nome, numero, categoria, preco, descricao, extra) => dono.inserir('produtos', Object.assign({ salaoId:S, nome, numero, categoria, preco, descricao, custo:0, estoque:0, ativo:true, vendaOnline:true }, extra || {}));
await it('HOT-DOG', 1, 'Lanches individuais', 15, 'Salsicha, maionese, ketchup, mostarda, vinagrete e batata-palha.', { precoPromo: 5 });
await it('HOT-DOG DUPLO', 2, 'Lanches individuais', 17, '2 salsichas, maionese, ketchup, mostarda e batata-palha.');
await it('MISTO', 3, 'Lanches individuais', 14, 'Presunto e queijo.');
await it('AMERICANO', 20, 'Lanches', 32, 'Hambúrguer, queijo, presunto, ovo, alface e tomate.');
await it('X-SALADA', 21, 'Lanches', 26, 'Hambúrguer, queijo, alface, tomate e maionese.');
const dias = {}; for(const d of ['dom','seg','ter','qua','qui','sex','sab']) dias[d] = [{ de:'00:00', ate:'23:59' }];
await dono.atualizar('saloes', S, { whatsapp:'(11) 97095-8687', endereco:{ rua:'Rua Campinas', numero:'138', complemento:'Sala 2', bairro:'Bairro Cidade Nova', cidade:'Itu', uf:'SP' },
  cfg:{ cor:'#C2410C', tema:'claro', fundoTipo:'gradiente', gradiente:'#F59E0B,#EA580C', pagamentos:{ formas:['pix','dinheiro'] },
        funcionamento: dias, duvidas:[{ p:'Posso retirar no local?', r:'Sim.' }],
        pedidos:{ tempo:'30 min', cardapio:{ estilo:'lista', numerar:true, fixar:true }, segmento:'lanchonete' } } });
let passou = 0, falhou = 0;
const ok  = t => { console.log('  ✓ ' + t); passou++; };
const nao = (t, d) => { console.log('  ✗ ' + t + (d ? '\n      ' + d : '')); falhou++; };
const igual = (t, a, b) => JSON.stringify(a) === JSON.stringify(b) ? ok(t) : nao(t, `esperava ${JSON.stringify(b)}, veio ${JSON.stringify(a)}`);
const verdade = (t, c, d) => c ? ok(t) : nao(t, d || 'esperava verdadeiro');
const secao = t => console.log('\n' + t);
const limpo = t => String(t || '').replace(/\s+/g, ' ').trim();
const cfgDe = async () => (await dono.lista('saloes', { id: S }))[0].cfg || {};

const nav = await chromium.launch({ executablePath: process.env.CHROMIUM || '/opt/pw-browsers/chromium' });
const erros = [];
const p = await (await nav.newContext({ viewport:{ width:1280, height:1000 } })).newPage();
p.on('pageerror', e => erros.push('painel: ' + e.message));
await p.addInitScript(([b, s]) => { window.PEDIHUB = { url:b, chave:'k', ambiente:'bancada' }; localStorage.setItem('pedihub.sessao', JSON.stringify(s)); }, [BASE, dono.sessao()]);
await p.goto(BASE + '/app.html');
await p.waitForFunction(() => typeof irPara === 'function' && bd && Array.isArray(bd.produtos) && bd.produtos.length >= 5, null, { timeout: 20000 });
await p.evaluate(() => { if(typeof pdFechar === 'function') pdFechar(true); irPara('salao'); });
await p.waitForTimeout(400);
await p.evaluate(() => trocarAbaSalao('aparencia'));
await p.waitForTimeout(900);

secao('1. A prévia é a do link de pedidos');
const v = await p.evaluate(() => {
  const f = document.querySelector('#previaFone .fone');
  const txt = f.innerText.replace(/\s+/g, ' ');
  return {
    atalhos: [...f.querySelectorAll('.fone-recurso')].map(e => e.textContent.trim()),
    tempo: (f.querySelector('.fone-tempo') || {}).textContent || '',
    convite: !!f.querySelector('.fone-convite'), promo: !!f.querySelector('.fone-promo'),
    rotulo: (f.querySelector('.fone-svs .fone-rot') || {}).textContent || '',
    linhas: f.querySelectorAll('.fone-lista .fone-li').length,
    numeros: [...f.querySelectorAll('.fone-li-num')].map(e => e.textContent.trim()),
    verTodos: (f.querySelector('.fone-ver-todos') || {}).textContent || '',
    fita: (f.querySelector('.fone-fita-zap') || {}).textContent || '',
    loja: /Produtos em destaque/.test(txt),
    ordem: ['fone-boas', 'fone-convite', 'fone-promo', 'fone-lista'].map(c => {
      const e = f.querySelector('.' + c); return e ? [...f.querySelectorAll('*')].indexOf(e) : -1; }),
  };
});
igual('os atalhos, com Dúvidas antes de Informações', v.atalhos, ['Pagamentos', 'Dúvidas', 'Informações']);
igual('o tempo de entrega', limpo(v.tempo), '🛵 Entrega em cerca de 30 min');
verdade('"Primeira vez aqui?" e a faixa de PROMOÇÃO', v.convite && v.promo);
igual('"Do cardápio", e não "Produtos em destaque"', [limpo(v.rotulo), v.loja], ['Do cardápio', false]);
igual('em lista, os cinco primeiros, pelo número', [v.linhas, v.numeros], [5, ['01', '02', '03', '20', '21']]);
igual('"Ver o cardápio completo"', limpo(v.verTodos), 'Ver o cardápio completo 5');
igual('a fita diz "Continuar" (não "Enviar")', limpo(v.fita), 'Continuar');
verdade('na mesma ordem do link: Bem-vindo, Primeira vez, Promoção, Do cardápio',
  v.ordem.every((x, i) => x > 0 && (i === 0 || x > v.ordem[i - 1])), JSON.stringify(v.ordem));

secao('2. "Endereço embaixo do nome", em Topo e capa');
const op = await p.evaluate(() => [...document.querySelectorAll('#reguaEndereco button')].map(b => b.textContent.trim()));
igual('as quatro escolhas', op, ['Automático', 'Brilho nas letras', 'Faixa clara', 'Sem destaque']);
verdade('cada uma explica o que faz', /brilho/i.test(limpo(await p.textContent('#explicaEndereco'))));
igual('automático com degradê (sem foto): o texto simples', await p.getAttribute('#previaFone .fone', 'data-endereco'), 'nenhum');
await p.evaluate(() => escolherAparencia('enderecoEstilo', 'faixa'));
await p.waitForTimeout(200);
igual('"Faixa clara": a prévia acompanha na hora', await p.getAttribute('#previaFone .fone', 'data-endereco'), 'faixa');
verdade('e a rua ganha a faixa na prévia', await p.evaluate(() =>
  getComputedStyle(document.querySelector('#previaFone .fone-topo > span[data-cfg="rua"]')).backgroundColor !== 'rgba(0, 0, 0, 0)'));

secao('3. Salvo: o banco e o link');
await p.evaluate(() => salvarAparencia());
await p.waitForTimeout(1800);
igual('no banco', (await cfgDe()).enderecoEstilo, 'faixa');
const c = await (await nav.newContext({ viewport:{ width:412, height:900 }, isMobile:true, hasTouch:true })).newPage();
c.on('pageerror', e => erros.push('link: ' + e.message));
await c.goto(BASE + '/cardapio.html?salao=' + SLUG);
await c.waitForTimeout(2500);
igual('o link usa a faixa', await c.evaluate(() => document.body.dataset.endereco), 'faixa');
verdade('e a faixa aparece atrás do endereço', await c.evaluate(() =>
  getComputedStyle(document.querySelector('.marca-end')).backgroundColor !== 'rgba(0, 0, 0, 0)'));
await p.evaluate(() => escolherAparencia('enderecoEstilo', 'nenhum'));
await p.evaluate(() => salvarAparencia());
await p.waitForTimeout(1800);
await c.reload();
await c.waitForTimeout(2500);
igual('"Sem destaque": o link volta ao texto simples', await c.evaluate(() => document.body.dataset.endereco), 'nenhum');

secao('4. A cor do endereço, a um toque');
await p.evaluate(() => irParaSecaoAp('apCapa'));
await p.waitForTimeout(500);
await p.click('text=Mudar a cor da rua e do bairro');
await p.waitForTimeout(900);
verdade('abre as cores das frases e acende a da rua', await p.evaluate(() => {
  const d = document.getElementById('frasesDetalhe'); const r = document.querySelector('.cor-linha[data-chave="rua"]');
  return d && d.open && r && r.getBoundingClientRect().height > 0;
}));

igual('nenhum erro de JavaScript', erros, []);
await nav.close();
console.log(`\n${falhou ? '✗' : '✓'} ${passou} passaram, ${falhou} falharam`);
process.exit(falhou ? 1 : 0);

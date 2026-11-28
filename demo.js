/* ===========================================================================
   PediHub — dados de demonstração
   ---------------------------------------------------------------------------
   Os dois aplicativos (o do restaurante e o do cliente) leem o mesmo `localStorage`,
   então a semente precisa ser uma só. Antes ela morava dentro do `app.html`:
   quem abrisse o link do cliente primeiro — que é exatamente o que acontece
   quando o restaurante manda o link no WhatsApp — caía numa tela vazia dizendo
   "abra o app.html antes". Aqui ela é um arquivo, e as duas telas semeiam.

   Vale só para a demonstração. Com o `config.js` preenchido, os dados vêm do
   Supabase e nada disto roda.
   =========================================================================== */

(function (global) {
'use strict';

// Cores das colunas da agenda: mesma luminosidade, saturação baixa, para
// distinguir profissionais sem transformar a tela num painel de avisos.
//
// Nenhuma delas puxa para o rosa, e isso é intencional: metade dos restaurantes que
// usam isto é barbearia, e a coluna de um barbeiro pintada de lilás é a
// primeira coisa que ele nota. Sete matizes bem separados em volta do azul,
// do verde e do terroso resolvem a distinção sem esse recado.
const CORES = ['#3D6B8E','#3F7A78','#4E7C5A','#9A6B45','#5B6E9C','#6B7B54','#5F5B6E'];

function iso(d){
  return d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0')
       + '-' + String(d.getDate()).padStart(2,'0');
}
function hoje(){ return iso(new Date()); }
function somarDias(dataIso, n){
  const [a,m,dd] = dataIso.split('-').map(Number);
  const d = new Date(a, m-1, dd);
  d.setDate(d.getDate() + n);
  return iso(d);
}
/* Imagens da demonstração.

   São SVG chapado virado `data:` URL, não fotografia — cada uma pesa menos de
   700 bytes, contra os 200 KB de um JPEG de verdade. A demonstração inteira
   cabe folgada no localStorage, e o repositório não carrega binário.

   Servem para mostrar o FORMATO: onde a logo entra, o que a capa ocupa, como
   o card de serviço se comporta com e sem foto. Fingir fotografia de restaurante
   com imagem de banco seria pior — o dono trocaria tudo no primeiro minuto. */
const LOGO = {
  s1: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cmVjdCB3aWR0aD0iMTI4IiBoZWlnaHQ9IjEyOCIgZmlsbD0iIzlBMzQxMiIvPjx0ZXh0IHg9IjY0IiB5PSI2NCIgZm9udC1mYW1pbHk9IkhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmIiBmb250LXNpemU9IjU0IiBmb250LXdlaWdodD0iNzAwIiBmaWxsPSIjRkZGN0VEIiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBkb21pbmFudC1iYXNlbGluZT0iY2VudHJhbCI+Qk08L3RleHQ+PC9zdmc+',
  s2: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAxMjggMTI4Ij48cmVjdCB3aWR0aD0iMTI4IiBoZWlnaHQ9IjEyOCIgZmlsbD0iIzFDMTkxNyIvPjx0ZXh0IHg9IjY0IiB5PSI2NCIgZm9udC1mYW1pbHk9IkhlbHZldGljYSxBcmlhbCxzYW5zLXNlcmlmIiBmb250LXNpemU9IjU0IiBmb250LXdlaWdodD0iNzAwIiBmaWxsPSIjRkZGN0VEIiB0ZXh0LWFuY2hvcj0ibWlkZGxlIiBkb21pbmFudC1iYXNlbGluZT0iY2VudHJhbCI+WsOJPC90ZXh0Pjwvc3ZnPg==',
};
const CAPA = {
  s1: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2MDAgNDAwIj48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9ImciIHgxPSIwIiB5MT0iMCIgeDI9IjEiIHkyPSIxIj48c3RvcCBvZmZzZXQ9IjAiIHN0b3AtY29sb3I9IiNDMjQxMEMiLz48c3RvcCBvZmZzZXQ9IjEiIHN0b3AtY29sb3I9IiNGNTlFMEIiLz48L2xpbmVhckdyYWRpZW50PjwvZGVmcz48cmVjdCB3aWR0aD0iNjAwIiBoZWlnaHQ9IjQwMCIgZmlsbD0idXJsKCNnKSIvPjx0ZXh0IHg9IjMwMCIgeT0iMjA1IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjQiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44NSIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Zm90byBkYSBwaXp6YXJpYTwvdGV4dD48L3N2Zz4=',
  s2: 'data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2MDAgNDAwIj48ZGVmcz48bGluZWFyR3JhZGllbnQgaWQ9ImciIHgxPSIwIiB5MT0iMCIgeDI9IjEiIHkyPSIxIj48c3RvcCBvZmZzZXQ9IjAiIHN0b3AtY29sb3I9IiMxQzE5MTciLz48c3RvcCBvZmZzZXQ9IjEiIHN0b3AtY29sb3I9IiNDMjQxMEMiLz48L2xpbmVhckdyYWRpZW50PjwvZGVmcz48cmVjdCB3aWR0aD0iNjAwIiBoZWlnaHQ9IjQwMCIgZmlsbD0idXJsKCNnKSIvPjx0ZXh0IHg9IjMwMCIgeT0iMjA1IiBmb250LWZhbWlseT0iSGVsdmV0aWNhLEFyaWFsLHNhbnMtc2VyaWYiIGZvbnQtc2l6ZT0iMjQiIGZpbGw9IiNGRkZGRkYiIGZpbGwtb3BhY2l0eT0iMC44NSIgdGV4dC1hbmNob3I9Im1pZGRsZSI+Zm90byBkYSBoYW1idXJndWVyaWE8L3RleHQ+PC9zdmc+',
};

function id(){ return 'x' + Math.random().toString(36).slice(2,10); }

/* ── Dados de demonstração ───────────────────────────────────────────────
   Dois restaurantes de propósito: dá para trocar no seletor lá em cima e conferir
   que um não enxerga o outro — que é a ideia do multi-restaurante.
   ──────────────────────────────────────────────────────────────────────── */
function semear(){
  /* PediHub: dois restaurantes de exemplo — uma pizzaria (meio a meio, borda)
     e uma hamburgueria (adicionais, ponto da carne). Dá para trocar no
     seletor lá em cima e conferir que um não enxerga o outro. */
  const s1 = 'pizzaria-bella', s2 = 'burger-ze';
  const nascido = n => somarDias(hoje(), -n) + 'T09:00:00Z';
  const semana = {1:[[1080,1380]],2:[[1080,1380]],3:[[1080,1380]],4:[[1080,1380]],5:[[1080,1410]],6:[[1080,1410]],0:[[1080,1380]]};

  // Quem cuida de cada casa. Não há agenda: a ficha só existe para o sistema.
  const profs = [
    {id:'p1', salaoId:s1, nome:'Bella', comissaoPct:0, cor:CORES[0], ativo:true, jornada:{}, criadoEm:nascido(120)},
    {id:'p4', salaoId:s2, nome:'Zé',    comissaoPct:0, cor:CORES[3], ativo:true, jornada:{}, criadoEm:nascido(150)},
  ];

  const clis = [
    {id:'c1', salaoId:s1, nome:'Maria Silva',     telefone:'(11) 98888-1111', obs:'Sempre pede sem cebola'},
    {id:'c2', salaoId:s1, nome:'Joana Prado',     telefone:'(11) 98888-2222', obs:''},
    {id:'c3', salaoId:s1, nome:'Rita Nogueira',   telefone:'(11) 98888-3333', obs:'Entregar no portão dos fundos'},
    {id:'c4', salaoId:s1, nome:'Carlos Antunes',  telefone:'(11) 98888-4444', obs:''},
    {id:'c5', salaoId:s2, nome:'João Pereira',    telefone:'(11) 97777-1111', obs:'Carne bem passada'},
    {id:'c6', salaoId:s2, nome:'Pedro Alves',     telefone:'(11) 97777-2222', obs:''},
  ];

  const op = (nome, preco) => ({ id:id(), nome, preco, ativo:true });
  const sabores = () => ({ id:id(), nome:'Sabores', min:1, max:2, regra:'maior', opcoes:[
    op('Calabresa', 0), op('Margherita', 0), op('Frango com catupiry', 5), op('Portuguesa', 5), op('Camarão', 20)] });
  const borda = () => ({ id:id(), nome:'Borda', min:0, max:1, regra:'soma', opcoes:[op('Catupiry', 8), op('Cheddar', 8)] });
  const adicionais = () => ({ id:id(), nome:'Adicionais', min:0, max:4, regra:'soma', opcoes:[
    op('Bacon', 5), op('Ovo', 3), op('Cheddar extra', 4), op('Cebola caramelizada', 4)] });
  const ponto = () => ({ id:id(), nome:'Ponto da carne', min:1, max:1, regra:'soma', opcoes:[
    op('Mal passada', 0), op('Ao ponto', 0), op('Bem passada', 0)] });
  const item = (iid, salaoId, nome, categoria, preco, descricao, grupos) => ({
    id:iid, salaoId, nome, categoria, preco, custo:0, estoque:null, comissaoPct:0,
    ativo:true, vendaOnline:true, precoVisivel:true, descricao, grupos: grupos || [] });
  const prods = [
    item('d1', s1, 'Pizza grande (8 fatias)', 'Pizzas', 45, 'Escolha até 2 sabores: vale o preço do mais caro.', [sabores(), borda()]),
    item('d2', s1, 'Pizza broto (4 fatias)', 'Pizzas', 30, 'Um sabor.', [Object.assign(sabores(), { max:1 })]),
    item('d3', s1, 'Refrigerante 2L', 'Bebidas', 14, 'Coca-Cola, Guaraná ou Fanta.'),
    item('d4', s1, 'Suco natural 500ml', 'Bebidas', 9, 'Laranja ou limão.'),
    item('d5', s1, 'Petit gâteau', 'Sobremesas', 18, 'Com sorvete de creme.'),
    item('d6', s2, 'X-Burger', 'Lanches', 24, 'Pão brioche, 150 g de carne, queijo e molho da casa.', [ponto(), adicionais()]),
    item('d7', s2, 'X-Bacon', 'Lanches', 29, 'Pão brioche, 150 g de carne, queijo e bacon crocante.', [ponto(), adicionais()]),
    item('d8', s2, 'Batata frita', 'Porções', 16, 'Crocante, com sal e orégano.', [{ id:id(), nome:'Tamanho', min:1, max:1, regra:'soma',
      opcoes:[op('Pequena', 0), op('Média', 6), op('Grande', 10)] }]),
    item('d9', s2, 'Milkshake 400ml', 'Bebidas', 18, 'Chocolate, morango ou baunilha.'),
    item('d10', s2, 'Refrigerante lata', 'Bebidas', 6, ''),
  ];

  /* ── DOIS MESES DE VENDAS JÁ ENTREGUES ───────────────────────────────────
     O Relatórios abre perguntando "quanto eu vendi no mês"; sem história ele
     abriria vazio para quem está decidindo se assina. São 59 dias, para o
     mês anterior também ter movimento e a comparação aparecer. O sorteio é
     determinístico (mulberry32): o número não dança a cada F5. */
  const comandas = [];
  {
    let semente = 20261121;
    const sorteio = () => {
      semente = (semente + 0x6D2B79F5) | 0;
      let t = Math.imul(semente ^ (semente >>> 15), 1 | semente);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    const escolher = lista => lista[Math.floor(sorteio() * lista.length)];
    const carteira = clis.filter(x => x.salaoId === s1);
    const cardapio = prods.filter(x => x.salaoId === s1);
    let n = 0;
    for(let volta = 59; volta >= 1; volta--){
      const dia = somarDias(hoje(), -volta);
      const fds = [5, 6, 0].includes(new Date(dia + 'T12:00').getDay());
      const quantas = (fds ? 8 : 4) + Math.floor(sorteio() * 6);
      for(let k = 0; k < quantas; k++){
        const pizza = escolher(cardapio.slice(0, 2));
        const itens = [{ tipo:'produto', descricao:pizza.nome, qtd:1, precoUnit:pizza.preco + escolher([0, 0, 5, 20]),
                         comissaoPct:0 }];
        if(sorteio() < 0.6){ const b = escolher(cardapio.slice(2)); itens.push({ tipo:'produto', descricao:b.nome, qtd:1, precoUnit:b.preco, comissaoPct:0 }); }
        const taxa = sorteio() < 0.7 ? escolher([5, 5, 7]) : 0;
        const total = itens.reduce((s, i) => s + i.qtd * i.precoUnit, 0) + taxa;
        const forma = escolher(['pix', 'pix', 'dinheiro', 'credito', 'debito']);
        const tx = forma === 'credito' ? Math.round(total * 4.49) / 100 : forma === 'debito' ? Math.round(total * 1.99) / 100 : 0;
        comandas.push({
          id:id(), salaoId:s1, clienteId:escolher(carteira).id, numero: ++n, data: dia,
          status:'fechada', desconto:0, acrescimo:taxa,
          fechadaEm: dia + 'T' + String(19 + Math.floor(sorteio() * 4)).padStart(2, '0') + ':30:00-03:00',
          itens, pagamentos:[{ forma, valor: total, parcelas:1, taxa: tx }],
        });
      }
    }
  }

  const cfgPedidos = { pedidos:{ taxas:[{ bairro:'Centro', taxa:5 }, { bairro:'Vila Nova', taxa:7 }],
                                 minimo:25, tempo:'40 a 60 min' }, funcionamento: semana };
  return {
    planos: [
      // PediHub (66_planos_pedihub.sql): Grátis, Teste, Essencial e Profissional.
      {codigo:'gratuito',   nome:'Grátis',       maxProfissionais:1,  precoMes:0,
       recursos:{loja:true, pedidos_mes:50, max_produtos:40, caixa:false, relatorios:false,
                 cupons:false, aparencia:false, crediario:false, mensagens_mes:0}},
      {codigo:'trial',      nome:'Teste grátis', maxProfissionais:2,  precoMes:0,
       recursos:{loja:true, caixa:true, relatorios:true, cupons:true, aparencia:true,
                 crediario:true, mensagens_mes:100}},
      {codigo:'individual', nome:'Essencial',    maxProfissionais:3,  precoMes:97,
       recursos:{loja:true, caixa:true, relatorios:true, cupons:true, aparencia:true,
                 crediario:true, mensagens_mes:0}},
      {codigo:'time',       nome:'Profissional', maxProfissionais:3,  precoMes:147,
       recursos:{loja:true, caixa:true, relatorios:true, cupons:true, aparencia:true,
                 crediario:true, mensagens_mes:1000}},
    ],
    // A pizzaria assina o Profissional; a hamburgueria está no teste, acabando.
    assinaturas: [
      {salaoId:s1, plano:'time',  status:'ativa', trialAte:null, venceEm:null},
      {salaoId:s2, plano:'trial', status:'trial', trialAte:somarDias(hoje(), 2), venceEm:null},
    ],
    saloes: [
      {id:s1, slug:'pizzaria-bella-massa', nome:'Pizzaria Bella Massa', tipo:'restaurante',
       telefone:'(11) 3322-1100', whatsapp:'(11) 99911-2233', cfg: cfgPedidos,
       endereco:{logradouro:'Rua das Flores', numero:'210', complemento:'',
                 bairro:'Centro', cidade:'Itu', uf:'SP', cep:'13300000'},
       logo:LOGO.s1, capa:CAPA.s1},
      {id:s2, slug:'hamburgueria-do-ze', nome:'Hamburgueria do Zé', tipo:'restaurante',
       telefone:'(11) 3344-5500', whatsapp:'(11) 99955-6677', cfg: cfgPedidos,
       endereco:{logradouro:'Av. Central', numero:'88', complemento:'Loja 3',
                 bairro:'Vila Nova', cidade:'Itu', uf:'SP', cep:'13309100'},
       logo:LOGO.s2, capa:CAPA.s2},
    ],
    documentosCobranca: [
      {salaoId:s1, documento:'11222333000181'},
      {salaoId:s2, documento:'11144477735'},
    ],
    profissionais: profs,
    servicos: [],
    clientes: clis,
    produtos: prods,
    agendamentos: [],
    bloqueios: [],
    comandas,
    pacotes: [],
    pacote_servicos: [],
    pacote_clientes: [],
    cupons: [
      {id:'cp1', salaoId:s1, codigo:'BEMVINDO10', tipo:'pct', valor:10,
       valeAgendamento:false, valeProdutos:true, servicos:null, inicio:null,
       fim:null, limiteTotal:null, umPorCliente:true, ativo:true},
    ],
    procedimentos: [],
  };
}

global.CORES = CORES;
global.semearDemo = semear;

})(window);

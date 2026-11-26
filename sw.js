/* ===========================================================================
   PediHub — service worker
   É o que torna o site instalável e o que faz a agenda abrir sem internet.

   Estratégia: "rede primeiro, cache como rede de segurança".
   O contrário (cache primeiro) é mais rápido, mas foi a causa de um problema
   clássico no AdminPro: a pessoa atualiza a página, o service worker devolve
   a versão velha do cache e ela jura que o sistema não recebeu a correção.
   Numa agenda isso é pior ainda — mostrar horário desatualizado faz o restaurante
   marcar em cima.

   Então: tenta a rede; se der certo, guarda a cópia e entrega a versão nova.
   Só quando a rede falha é que o cache aparece.
   =========================================================================== */

/* Sobe a cada correção publicada, e tem que andar junto com o VERSAO_APP do
   app.html: o carimbo na lateral mostra aquele, e dois números divergentes
   fariam a tela afirmar uma versão que não é a que está servindo. */
const VERSAO = 'pedihub-v9.5a41bc';

const ESSENCIAIS = [
  './',
  './app.html',
  './cardapio.html',
  './criar.html',
  './entrar.html',
  // Chega-se aqui pelo link de um e-mail, às vezes na rua e com pouca rede.
  './nova-senha.html',
  './index.html',
  './estilo.css',
  './icones.js',
  './demo.js',
  './imagens.js',
  './endereco.js',
  './funcionamento.js',
  // CPF e CNPJ: mascara e digito verificador, compartilhados por tres telas.
  './documento.js',
  // O QR do link. Sem ele no cache, o painel aberto sem rede carrega uma tela
  // que chama um arquivo que não está lá — e o cartão do link fica sem o
  // quadradinho que o texto ao lado promete.
  './qr.js',
  './config.js',
  './dados.js',
  './manifest.webmanifest',
  './icones/marca.svg',
  './icones/icone-192.png',
  './icones/icone-512.png',
];

self.addEventListener('install', ev => {
  // skipWaiting: a versão nova assume na hora, sem esperar todas as abas
  // fecharem. Sem isso, uma correção pode levar dias para chegar em quem
  // deixa o app aberto o dia inteiro — que é justamente a recepção.
  self.skipWaiting();
  ev.waitUntil(
    caches.open(VERSAO)
      .then(c => c.addAll(ESSENCIAIS))
      .catch(e => console.error('[sw] não consegui montar o cache inicial:', e))
  );
});

self.addEventListener('activate', ev => {
  ev.waitUntil((async () => {
    // Limpa versões antigas — senão o armazenamento só cresce.
    const nomes = await caches.keys();
    await Promise.all(nomes.filter(n => n !== VERSAO).map(n => caches.delete(n)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', ev => {
  const req = ev.request;

  // Só cuidamos de GET do mesmo endereço. Chamada de API (Supabase, quando
  // entrar) passa direto: resposta de banco em cache é receita de dado velho.
  if(req.method !== 'GET') return;
  const u = new URL(req.url);
  if(u.origin !== self.location.origin) return;
  /* E o banco no MESMO endereço também passa direto. Olhar só a origem
     bastava com o Supabase em outro domínio; servido junto com as páginas
     (a bancada de testes, ou um domínio próprio na frente dos dois), a
     leitura da agenda ia para o cache — e sem rede o painel abria com a
     agenda de ontem como se fosse a de agora. */
  if(/^\/(rest|auth|functions|storage|realtime)\/v1\//.test(u.pathname)) return;

  ev.respondWith((async () => {
    try{
      const resposta = await fetch(req);
      if(resposta && resposta.ok){
        const copia = resposta.clone();
        caches.open(VERSAO).then(c => c.put(req, copia)).catch(() => {});
      }
      return resposta;
    }catch(e){
      const guardado = await caches.match(req);
      if(guardado) return guardado;
      // Navegação sem rede e sem cópia: devolve a casca do app.
      if(req.mode === 'navigate'){
        const casca = await caches.match('./app.html');
        if(casca) return casca;
      }
      throw e;
    }
  })());
});

/* ── O AVISO NO CELULAR (59_push.sql) ─────────────────────────────────────
   O recado chega cifrado do servidor e o navegador já entrega aberto aqui.
   Vem só o que a tela de bloqueio mostra: título, uma linha e para onde ir.

   ⚠ TODO push PRECISA mostrar uma notificação. Push recebido sem nada na
   tela é lido pelo Chrome como abuso, e ele passa a mostrar sozinho "Este
   site foi atualizado em segundo plano" — e o Safari cancela a inscrição.
   Por isso o recado ilegível vira um aviso genérico, e não silêncio. */
self.addEventListener('push', ev => {
  let r = {};
  try{ r = ev.data ? ev.data.json() : {}; }catch(e){ r = {}; }
  const titulo = String(r.titulo || 'PediHub').slice(0, 80);
  ev.waitUntil(self.registration.showNotification(titulo, {
    body: String(r.corpo || 'Novidade na sua agenda.').slice(0, 200),
    icon: './icones/icone-192.png',
    badge: './icones/icone-192.png',
    tag: String(r.tag || 'pedihub'),
    data: { url: typeof r.url === 'string' && r.url.startsWith('./') ? r.url : './app.html' },
    vibrate: [180, 80, 180],
  }));
});

/* Tocou no aviso: volta para o PediHub que já está aberto (e vai para a
   tela certa), ou abre um novo. Só endereço DESTE site — o `url` vem do
   banco, e mesmo assim nada que comece fora de './' é aceito acima. */
self.addEventListener('notificationclick', ev => {
  ev.notification.close();
  const alvo = new URL((ev.notification.data && ev.notification.data.url) || './app.html',
                       self.registration.scope).href;
  ev.waitUntil((async () => {
    const abertas = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for(const c of abertas){
      if(c.url.includes('/app.html')){
        try{ await c.focus(); }catch(e){}
        try{ return await c.navigate(alvo); }catch(e){ return; }
      }
    }
    return self.clients.openWindow(alvo);
  })());
});

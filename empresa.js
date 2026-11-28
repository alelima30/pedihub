/* ===========================================================================
   PediHub — quem vende o PediHub

   Os dados que aparecem nos Termos de uso (termos.html) e na Política de
   privacidade (privacidade.html), num lugar só. O que estiver vazio NÃO
   aparece nas páginas: não sai "CNPJ: " em branco.

   Preencha quando tiver:
     razao  → a razão social, quando abrir o CNPJ
     cnpj   → 00.000.000/0000-00
     email  → o e-mail de contato no domínio (contato@seudominio.com.br)
     cidade → a cidade e o estado da sede (ex.: São Paulo/SP)

   O WhatsApp é o mesmo do botão "Ajuda" do painel (SUPORTE_WHATSAPP, no
   app.html): só dígitos, com 55 e DDD. Trocando um, troque o outro.
   =========================================================================== */
window.PEDIHUB_EMPRESA = {
  nome:     'PediHub',
  razao:    '',
  cnpj:     '',
  email:    '',
  whatsapp: '5511963659620',
  cidade:   '',
};

/* Preenche a página: `data-empresa="x"` recebe o valor (sempre como texto,
   nunca como HTML), e o bloco `data-se="x"` some quando x está vazio. */
(function(){
  const E = window.PEDIHUB_EMPRESA || {};
  const zap = d => {
    const n = String(d || '').replace(/\D/g, '').replace(/^55/, '');
    return n.length === 11 ? '(' + n.slice(0, 2) + ') ' + n.slice(2, 7) + '-' + n.slice(7)
         : n.length === 10 ? '(' + n.slice(0, 2) + ') ' + n.slice(2, 6) + '-' + n.slice(6) : n;
  };
  function preencher(){
    document.querySelectorAll('[data-se]').forEach(el => {
      const tem = el.dataset.se.split(' ').some(k => String(E[k] || '').trim());
      el.hidden = !tem;
    });
    document.querySelectorAll('[data-empresa]').forEach(el => {
      const k = el.dataset.empresa, v = String(E[k] || '').trim();
      if(!v) return;
      if(k === 'whatsapp'){
        el.textContent = zap(v);
        if(el.tagName === 'A'){ el.href = 'https://wa.me/' + v.replace(/\D/g, ''); el.target = '_blank'; el.rel = 'noopener'; }
      } else if(k === 'email'){
        el.textContent = v;
        if(el.tagName === 'A') el.href = 'mailto:' + v;
      } else {
        el.textContent = v;
      }
    });
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', preencher);
  else preencher();
})();

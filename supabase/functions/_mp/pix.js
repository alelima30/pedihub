/* ===========================================================================
   PediHub — o Pix online e a conexão com o Mercado Pago do restaurante (81)

   JavaScript puro, sem nada do Deno nem do Node: o MESMO arquivo roda nas
   funções de borda do Supabase (mp-conectar, pix-pedido) e na bancada de
   testes, que troca o `fetch` por um Mercado Pago de mentira. Assim o que
   o teste aprova é exatamente o que vai para o ar.

   Tudo o que vem de fora chega por `ctx`:
     ctx.fetch      o fetch (o de verdade, ou o falso da bancada)
     ctx.rpc        chama uma função do banco como SERVIDOR (service_role)
     ctx.env        clientId, clientSecret, redirectUri, painelUrl,
                    pagadorEmail, avisoUrl(pedidoId), authUrl, mpApi
     ctx.agora      () => Date  (os testes podem adiantar o relógio)

   ── ⚠ O QUE NUNCA SE ACREDITA ─────────────────────────────────────────────
   O aviso do Mercado Pago (o webhook) chega sem assinatura que a gente possa
   conferir: o pagamento é da conta DO RESTAURANTE, e o aviso vem pelo
   endereço do próprio pagamento. Então o aviso é só um "vá olhar": a borda
   busca o pagamento no Mercado Pago com a credencial do restaurante e só
   confirma se ele está APROVADO, é DESTE pedido (external_reference) e tem
   o VALOR do pedido (o banco confere de novo). Um aviso inventado não paga
   pedido nenhum.

   ── ⚠ O QUE NUNCA SAI ─────────────────────────────────────────────────────
   As credenciais do restaurante ficam no banco e no servidor. A resposta para
   o navegador leva o copia-e-cola, o vencimento e "pago / não pago" — nada
   além disso. E o erro do Mercado Pago vai para o log, nunca para a tela.
   =========================================================================== */

export const MP_API  = 'https://api.mercadopago.com';
export const MP_AUTH = 'https://auth.mercadopago.com.br/authorization';
const DIA = 86400000;

const api = ctx => (ctx.env && ctx.env.mpApi) || MP_API;
const agora = ctx => (ctx.agora ? ctx.agora() : new Date());

async function mp(ctx, caminho, { metodo = 'GET', token, corpo, idem } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  if (idem) headers['X-Idempotency-Key'] = idem;
  const r = await ctx.fetch(api(ctx) + caminho, {
    method: metodo, headers, body: corpo ? JSON.stringify(corpo) : undefined });
  const dados = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error('Mercado Pago ' + metodo + ' ' + caminho.split('?')[0] + ': ' + r.status);
    e.status = r.status; e.mp = dados;
    throw e;
  }
  return dados;
}

/* ── A CONEXÃO (OAuth) ────────────────────────────────────────────────── */

export function urlDeAutorizacao(ctx, estado) {
  const q = new URLSearchParams({
    client_id: ctx.env.clientId, response_type: 'code', platform_id: 'mp',
    state: estado, redirect_uri: ctx.env.redirectUri });
  return ((ctx.env && ctx.env.authUrl) || MP_AUTH) + '?' + q.toString();
}

function contaDaResposta(ctx, r) {
  const segundos = Number(r.expires_in) || 15552000;   // 180 dias, o padrão do Mercado Pago
  return {
    userId: String(r.user_id || ''), access: r.access_token, refresh: r.refresh_token || null,
    publicKey: r.public_key || null,
    expiraEm: new Date(agora(ctx).getTime() + segundos * 1000).toISOString(),
  };
}

// O dono tocou em "Conectar": devolve o endereço do Mercado Pago para abrir.
// `rpcUsuario` chama o banco COMO o dono (é ele que o banco confere).
export async function conectarInicio(ctx, salaoId, rpcUsuario) {
  if (!ctx.env.clientId || !ctx.env.clientSecret) {
    return { status: 503, corpo: { erro: 'O Pix online ainda não foi ligado no PediHub. Fale com o suporte.' } };
  }
  if (!salaoId) return { status: 400, corpo: { erro: 'Faltou o restaurante.' } };
  let estado;
  try { estado = await rpcUsuario('mp_conexao_iniciar', { p_salao: salaoId }); }
  catch (e) { return { status: 403, corpo: { erro: 'Só a gestão do restaurante conecta o Mercado Pago.' } }; }
  return { status: 200, corpo: { url: urlDeAutorizacao(ctx, String(estado)) } };
}

// A volta do Mercado Pago: troca o código pela credencial e grava.
// Devolve sempre um endereço do painel para onde mandar o navegador.
export async function conectarVolta(ctx, query) {
  const painel = ctx.env.painelUrl;
  const ir = s => ({ redirect: painel + (painel.includes('?') ? '&' : '?') + 'mp=' + s });
  if (query.get('error')) return ir('cancelado');
  const code = query.get('code'), estado = query.get('state');
  if (!code || !estado) return ir('erro');
  try {
    const r = await mp(ctx, '/oauth/token', { metodo: 'POST', corpo: {
      client_id: ctx.env.clientId, client_secret: ctx.env.clientSecret,
      grant_type: 'authorization_code', code, redirect_uri: ctx.env.redirectUri } });
    const c = contaDaResposta(ctx, r);
    if (!c.access || !c.userId) throw new Error('resposta sem credencial');
    await ctx.rpc('mp_conexao_concluir', {
      p_estado: estado, p_user_id: c.userId, p_access: c.access, p_refresh: c.refresh,
      p_public_key: c.publicKey, p_expira_em: c.expiraEm });
    return ir('conectado');
  } catch (e) {
    console.error('mp-conectar:', e.message);
    return ir(/expirou/.test(String(e.message)) ? 'expirou' : 'erro');
  }
}

// A credencial vence em 180 dias; faltando uma semana, renova sozinha.
async function credencial(ctx, dp) {
  const c = dp.conta;
  const vence = c.expiraEm ? new Date(c.expiraEm).getTime() : Infinity;
  if (!c.refresh || vence - agora(ctx).getTime() > 7 * DIA) return c.access;
  try {
    const r = await mp(ctx, '/oauth/token', { metodo: 'POST', corpo: {
      client_id: ctx.env.clientId, client_secret: ctx.env.clientSecret,
      grant_type: 'refresh_token', refresh_token: c.refresh } });
    const n = contaDaResposta(ctx, r);
    await ctx.rpc('mp_token_atualizar', {
      p_salao: dp.salao, p_access: n.access, p_refresh: n.refresh, p_expira_em: n.expiraEm });
    return n.access;
  } catch (e) {
    console.error('mp renovar:', e.message);
    return c.access;   // ainda vale até vencer de fato
  }
}

/* ── O PIX DO PEDIDO ──────────────────────────────────────────────────── */

// Confere no Mercado Pago e, se pagou, libera o pedido. Devolve true/false.
async function conferir(ctx, dp, token, mpId) {
  if (!mpId) return false;
  const p = await mp(ctx, '/v1/payments/' + encodeURIComponent(mpId), { token });
  if (p.status !== 'approved' || String(p.external_reference) !== String(dp.id)) return false;
  await ctx.rpc('pix_confirmar', { p_pedido: dp.id, p_mp_id: String(p.id), p_valor: Number(p.transaction_amount) });
  return true;
}

const respostaPaga = dp => ({ status: 200, corpo: { pago: true, status: dp.status === 'cancelado' ? 'recebido' : dp.status } });

/* A tela da cliente: `acao` 'criar' (mostra o QR) ou 'status' (já pagou?).
   O pedido é achado pelo TOKEN dela — o mesmo segredo do acompanhamento. */
export async function pix(ctx, corpo) {
  const token = String((corpo && corpo.token) || '');
  if (!/^[0-9a-f-]{36}$/i.test(token)) return { status: 400, corpo: { erro: 'Pedido inválido.' } };
  const dp = await ctx.rpc('pix_do_pedido', { p_token: token });
  if (!dp || !dp.id) return { status: 404, corpo: { erro: 'Não achei este pedido.' } };
  if (!dp.pagoOnline) return { status: 400, corpo: { erro: 'Este pedido não é Pix online.' } };
  if (dp.pagoEm) return respostaPaga(dp);
  if (dp.status !== 'aguardando_pagamento') return { status: 200, corpo: { pago: false, vencido: true, status: dp.status } };
  if (!dp.conta) {
    return { status: 409, corpo: { erro: 'O restaurante não está recebendo Pix online agora. Fale com ele pelo WhatsApp.' } };
  }
  const tok = await credencial(ctx, dp);
  const vencido = dp.expiraEm && new Date(dp.expiraEm).getTime() <= agora(ctx).getTime();

  try {
    // Já existe o Pix: confere se caiu (inclusive no último segundo antes de vencer).
    if (dp.mpPagamentoId && await conferir(ctx, dp, tok, dp.mpPagamentoId)) return respostaPaga(dp);
  } catch (e) { console.error('pix conferir:', e.message); }
  if (vencido) {
    await ctx.rpc('pix_vencer', { p_pedido: dp.id });
    return { status: 200, corpo: { pago: false, vencido: true, status: 'cancelado' } };
  }
  if (dp.copiaCola || corpo.acao === 'status') {
    return { status: 200, corpo: { pago: false, status: dp.status, copiaCola: dp.copiaCola || null,
                                   qr: corpo.acao === 'status' ? null : (dp.qr || null), expiraEm: dp.expiraEm } };
  }

  // Criar o Pix na conta do restaurante. A chave de idempotência é o pedido:
  // dois toques (ou a rede repetindo) devolvem o MESMO Pix, nunca dois.
  const primeiro = String(dp.nome || '').trim().split(/\s+/)[0] || 'Cliente';
  let p;
  try {
    p = await mp(ctx, '/v1/payments', { metodo: 'POST', token: tok, idem: 'pedihub-' + dp.id, corpo: {
      transaction_amount: Number(dp.total),
      description: 'Pedido #' + dp.numero + ' - ' + String(dp.casa || '').slice(0, 60),
      payment_method_id: 'pix',
      external_reference: dp.id,
      notification_url: ctx.env.avisoUrl(dp.id),
      date_of_expiration: new Date(dp.expiraEm).toISOString().replace('Z', '+00:00'),
      payer: { email: ctx.env.pagadorEmail, first_name: primeiro.slice(0, 40) },
    } });
  } catch (e) {
    console.error('pix criar:', e.message, JSON.stringify(e.mp || {}).slice(0, 300));
    return { status: 502, corpo: { erro: 'Não consegui gerar o Pix agora. Tente de novo em instantes.' } };
  }
  const tx = (p && p.point_of_interaction && p.point_of_interaction.transaction_data) || {};
  const copiaCola = tx.qr_code, qr = tx.qr_code_base64 || null;
  if (!copiaCola) {
    console.error('pix criar: sem qr_code', JSON.stringify(p).slice(0, 300));
    return { status: 502, corpo: { erro: 'Não consegui gerar o Pix agora. Tente de novo em instantes.' } };
  }
  await ctx.rpc('pix_anotar', { p_pedido: dp.id, p_mp_id: String(p.id), p_copia_cola: copiaCola, p_qr: qr });
  return { status: 200, corpo: { pago: false, status: dp.status, copiaCola, qr, expiraEm: dp.expiraEm } };
}

/* O aviso do Mercado Pago (webhook). Responde SEMPRE 200 — senão ele insiste
   por dias —, e só confirma depois de conferir lá, como diz o cabeçalho. */
export async function aviso(ctx, pedidoId, corpo, query) {
  try {
    if (!/^[0-9a-f-]{36}$/i.test(String(pedidoId || ''))) return { status: 200, corpo: { ok: true } };
    const dp = await ctx.rpc('pix_do_pedido', { p_pedido: pedidoId });
    if (!dp || !dp.id || !dp.pagoOnline || dp.pagoEm || !dp.conta) return { status: 200, corpo: { ok: true } };
    const mpId = (corpo && corpo.data && corpo.data.id) || (query && (query.get('data.id') || query.get('id')))
      || dp.mpPagamentoId;
    const tok = await credencial(ctx, dp);
    await conferir(ctx, dp, tok, mpId);
  } catch (e) { console.error('pix aviso:', e.message); }
  return { status: 200, corpo: { ok: true } };
}

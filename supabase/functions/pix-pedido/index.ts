/* ===========================================================================
   PediHub — o Pix online do pedido (81)
   Supabase Edge Function (Deno). Publicada com --no-verify-jwt: quem chama é
   a página da cliente (sem login) e o aviso do Mercado Pago.

     POST { token, acao: 'criar' | 'status' }   a tela do pedido
     POST ?aviso=<id do pedido>                  o aviso do Mercado Pago

   A lógica mora em ../_mp/pix.js (o mesmo arquivo que a bancada testa).

   ── OS SEGREDOS (Supabase → Edge Functions → Secrets) ─────────────────────
     MP_CLIENT_ID, MP_CLIENT_SECRET   o aplicativo PediHub no Mercado Pago
     MP_PAGADOR_EMAIL                 o e-mail que vai como "pagador" no Pix
                                      (o Mercado Pago exige um; a cliente não
                                      precisa dar o dela)
   As credenciais DE CADA RESTAURANTE ficam no banco (mp_contas), e só este
   servidor as lê.
   =========================================================================== */
import { pix, aviso } from '../_mp/pix.js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': Deno.env.get('PAINEL_ORIGEM') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const responder = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8' } });

const rpc = async (nome: string, args: unknown) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`${nome}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
};

const ctx = {
  fetch, rpc,
  env: {
    clientId: Deno.env.get('MP_CLIENT_ID') ?? '',
    clientSecret: Deno.env.get('MP_CLIENT_SECRET') ?? '',
    pagadorEmail: Deno.env.get('MP_PAGADOR_EMAIL') ?? '',
    avisoUrl: (id: string) => `${SUPABASE_URL}/functions/v1/pix-pedido?aviso=${id}`,
  },
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const u = new URL(req.url);
  try {
    const idAviso = u.searchParams.get('aviso');
    if (idAviso) {
      const corpo = await req.json().catch(() => ({}));
      const r = await aviso(ctx, idAviso, corpo, u.searchParams);
      return responder(r.corpo, r.status);
    }
    if (req.method !== 'POST') return responder({ erro: 'use POST' }, 405);
    if (!ctx.env.pagadorEmail) return responder({ erro: 'O Pix online ainda não foi ligado no PediHub.' }, 503);
    const corpo = await req.json().catch(() => ({}));
    const r = await pix(ctx, corpo);
    return responder(r.corpo, r.status);
  } catch (e) {
    console.error('pix-pedido', String(e).slice(0, 300));
    return responder({ erro: 'Não consegui falar com o Pix agora. Tente de novo.' }, 500);
  }
});

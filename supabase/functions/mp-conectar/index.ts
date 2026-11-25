/* ===========================================================================
   PediHub — conectar o Mercado Pago do restaurante (81)
   Supabase Edge Function (Deno). Publicada com --no-verify-jwt: a VOLTA do
   Mercado Pago chega sem token nenhum. A ida confere a sessão do dono.

     POST { salaoId }  (com a sessão do painel)  → { url } do Mercado Pago
     GET  ?code=…&state=…  (a volta do Mercado Pago) → manda de volta ao painel

   Este endereço é o "URL de redirecionamento" cadastrado no aplicativo
   PediHub do Mercado Pago:
     https://<projeto>.supabase.co/functions/v1/mp-conectar

   A lógica mora em ../_mp/pix.js (o mesmo arquivo que a bancada testa).
   Segredos: MP_CLIENT_ID e MP_CLIENT_SECRET (Edge Functions → Secrets).
   =========================================================================== */
import { conectarInicio, conectarVolta } from '../_mp/pix.js';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON_KEY     = Deno.env.get('SUPABASE_ANON_KEY')!;

const CORS = {
  'Access-Control-Allow-Origin': Deno.env.get('PAINEL_ORIGEM') ?? '*',
  'Access-Control-Allow-Headers': 'authorization, content-type, apikey',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};
const responder = (corpo: unknown, status = 200) =>
  new Response(JSON.stringify(corpo), { status, headers: { ...CORS, 'Content-Type': 'application/json; charset=utf-8' } });

const chamar = async (chave: string, auth: string, nome: string, args: unknown) => {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: chave, Authorization: auth },
    body: JSON.stringify(args),
  });
  if (!r.ok) throw new Error(`${nome}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  const t = await r.text();
  return t ? JSON.parse(t) : null;
};

const ctx = {
  fetch,
  rpc: (nome: string, args: unknown) => chamar(SERVICE_KEY, `Bearer ${SERVICE_KEY}`, nome, args),
  env: {
    clientId: Deno.env.get('MP_CLIENT_ID') ?? '',
    clientSecret: Deno.env.get('MP_CLIENT_SECRET') ?? '',
    redirectUri: `${SUPABASE_URL}/functions/v1/mp-conectar`,
    painelUrl: Deno.env.get('PAINEL_URL') ?? 'https://alelima30.github.io/pedihub/app.html',
  },
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const u = new URL(req.url);
  try {
    if (req.method === 'GET') {
      const r = await conectarVolta(ctx, u.searchParams);
      return new Response(null, { status: 302, headers: { Location: r.redirect } });
    }
    if (req.method !== 'POST') return responder({ erro: 'method' }, 405);
    /* A sessão é CONFERIDA no próprio Supabase, não lida do token; e a
       chamada ao banco vai COMO o dono, para o banco decidir se ele é gestão. */
    const auth = req.headers.get('Authorization') ?? '';
    const quem = auth.startsWith('Bearer ')
      ? await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: ANON_KEY, Authorization: auth } })
          .then(r => r.ok ? r.json() : null).catch(() => null)
      : null;
    if (!quem?.id) return responder({ erro: 'Faça login de novo.' }, 401);
    const corpo = await req.json().catch(() => ({}));
    const r = await conectarInicio(ctx, String(corpo.salaoId ?? ''),
      (nome: string, args: unknown) => chamar(ANON_KEY, auth, nome, args));
    return responder(r.corpo, r.status);
  } catch (e) {
    console.error('mp-conectar', String(e).slice(0, 300));
    return responder({ erro: 'Não consegui falar com o Mercado Pago agora.' }, 500);
  }
});

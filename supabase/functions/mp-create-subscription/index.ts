// ============================================================================
// Edge Function: mp-create-subscription
// ----------------------------------------------------------------------------
// Cria uma assinatura recorrente (preapproval) no Mercado Pago para o plano
// escolhido pelo usuário e devolve o init_point (URL de checkout).
//
// Fluxo:
//   1. Valida o usuário pelo JWT do cabeçalho Authorization.
//   2. Lê o preço da combinação (account_type, with_mentorship) em plan_prices.
//   3. Cria a preapproval no Mercado Pago com cobrança mensal.
//   4. Grava a assinatura (status 'pending') em subscriptions via service role.
//   5. Retorna { init_point } para o front redirecionar ao checkout.
//
// Secrets necessários:
//   MP_ACCESS_TOKEN  -> Access Token do Mercado Pago (produção ou sandbox)
//   APP_RETURN_URL   -> (opcional) URL de retorno após o checkout
// ============================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const MP_ACCESS_TOKEN = Deno.env.get("MP_ACCESS_TOKEN") ?? "";
const APP_RETURN_URL = Deno.env.get("APP_RETURN_URL") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const PLAN_LABELS: Record<string, string> = {
  individual: "Individual",
  couple: "Casal",
  throuple: "Trisal",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ error: "Método não permitido." }, 405);
  }
  if (!MP_ACCESS_TOKEN) {
    return json({ error: "MP_ACCESS_TOKEN não configurado." }, 500);
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: "Ambiente Supabase não configurado." }, 500);
  }

  // --- Identifica o usuário a partir do JWT ---
  const authHeader = req.headers.get("Authorization") ?? "";
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const {
    data: { user },
    error: userErr,
  } = await supabase.auth.getUser();
  if (userErr || !user) {
    return json({ error: "Usuário não autenticado." }, 401);
  }

  // --- Lê o corpo da requisição ---
  let body: { account_type?: string; with_mentorship?: boolean };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Corpo inválido." }, 400);
  }

  const accountType = body.account_type ?? "";
  const withMentorship = Boolean(body.with_mentorship);
  if (!["individual", "couple", "throuple"].includes(accountType)) {
    return json({ error: "Tipo de conta inválido." }, 400);
  }

  // --- Busca o preço configurado (service role ignora RLS) ---
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
  const { data: price, error: priceErr } = await admin
    .from("plan_prices")
    .select("amount")
    .eq("account_type", accountType)
    .eq("with_mentorship", withMentorship)
    .maybeSingle();

  if (priceErr || !price) {
    return json({ error: "Preço do plano não encontrado." }, 400);
  }
  const amount = Number(price.amount);
  if (!Number.isFinite(amount) || amount <= 0) {
    return json({ error: "Preço do plano inválido." }, 400);
  }

  // --- Cria a preapproval (assinatura recorrente mensal) no Mercado Pago ---
  const reason = `Vida Rica — Plano ${PLAN_LABELS[accountType]}${
    withMentorship ? " com Mentoria" : ""
  }`;

  const preapprovalPayload: Record<string, unknown> = {
    reason,
    external_reference: user.id,
    payer_email: user.email,
    auto_recurring: {
      frequency: 1,
      frequency_type: "months",
      transaction_amount: amount,
      currency_id: "BRL",
    },
    back_url: APP_RETURN_URL || undefined,
    status: "pending",
  };

  const mpResp = await fetch("https://api.mercadopago.com/preapproval", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${MP_ACCESS_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(preapprovalPayload),
  });

  const mpData = await mpResp.json();
  if (!mpResp.ok) {
    return json(
      { error: "Falha ao criar assinatura no Mercado Pago.", details: mpData },
      502,
    );
  }

  // --- Descobre o group_id do usuário para consolidar a parceria ---
  const { data: profile } = await admin
    .from("profiles")
    .select("group_id")
    .eq("id", user.id)
    .maybeSingle();
  const groupId = profile?.group_id ?? user.id;

  // --- Persiste a assinatura pendente (substitui qualquer pendência anterior) ---
  await admin
    .from("subscriptions")
    .delete()
    .eq("user_id", user.id)
    .eq("status", "pending");

  const { error: insErr } = await admin.from("subscriptions").insert({
    user_id: user.id,
    group_id: groupId,
    account_type: accountType,
    with_mentorship: withMentorship,
    status: "pending",
    amount,
    mp_preapproval_id: mpData.id,
  });
  if (insErr) {
    return json({ error: "Falha ao registrar assinatura.", details: insErr }, 500);
  }

  return json({
    preapproval_id: mpData.id,
    init_point: mpData.init_point ?? mpData.sandbox_init_point ?? null,
  });
});

// ============================================================================
// Edge Function: mp-cancel-subscription
// ----------------------------------------------------------------------------
// Cancela a assinatura ativa do usuário: envia o pedido ao Mercado Pago e
// atualiza subscriptions + profiles.is_premium no banco.
//
// Requer JWT (usuário autenticado). Configure verify_jwt = true em config.toml.
//
// Secrets necessários:
//   MP_ACCESS_TOKEN -> Access Token do Mercado Pago
// ============================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

const MP_ACCESS_TOKEN = Deno.env.get("MP_ACCESS_TOKEN") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Método não permitido." }, 405);

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: "Ambiente Supabase não configurado." }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: userErr } = await supabase.auth.getUser();
  if (userErr || !user) return json({ error: "Usuário não autenticado." }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: sub, error: subErr } = await admin
    .from("subscriptions")
    .select("id, mp_preapproval_id, group_id")
    .eq("user_id", user.id)
    .eq("status", "active")
    .maybeSingle();

  if (subErr || !sub) {
    return json({ error: "Nenhuma assinatura ativa encontrada." }, 404);
  }

  // Cancela no Mercado Pago (falha não impede atualização no banco).
  if (sub.mp_preapproval_id && MP_ACCESS_TOKEN) {
    const mpResp = await fetch(
      `https://api.mercadopago.com/preapproval/${sub.mp_preapproval_id}`,
      {
        method: "PUT",
        headers: {
          Authorization: `Bearer ${MP_ACCESS_TOKEN}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ status: "cancelled" }),
      },
    );
    if (!mpResp.ok) {
      console.error("Falha ao cancelar preapproval no MP", await mpResp.text());
    }
  }

  await admin
    .from("subscriptions")
    .update({ status: "cancelled", updated_at: new Date().toISOString() })
    .eq("id", sub.id);

  const targetGroup = sub.group_id ?? user.id;
  await admin
    .from("profiles")
    .update({ is_premium: false })
    .or(`id.eq.${targetGroup},group_id.eq.${targetGroup}`);

  return json({ success: true });
});

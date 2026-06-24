// ============================================================================
// Edge Function: mp-webhook
// ----------------------------------------------------------------------------
// Recebe as notificações (webhooks) do Mercado Pago sobre as assinaturas
// (preapproval) e sincroniza o estado em subscriptions + profiles.is_premium.
//
// O Mercado Pago notifica com { type: "subscription_preapproval", data: { id } }
// (ou via query string ?type=...&id=...). Consultamos a preapproval na API para
// obter o status real e então atualizamos o banco com a service role (ignora RLS).
//
// Mapa de status do Mercado Pago -> subscriptions.status:
//   authorized -> active     (libera o acesso; is_premium = true)
//   paused     -> paused     (bloqueia)
//   cancelled  -> cancelled  (bloqueia)
//   pending    -> pending
//
// Esta função NÃO exige JWT: configure-a como pública (--no-verify-jwt) e
// cadastre a URL no painel de notificações do Mercado Pago.
//
// Secrets necessários:
//   MP_ACCESS_TOKEN -> Access Token do Mercado Pago
// ============================================================================
import { createClient } from "jsr:@supabase/supabase-js@2";

const MP_ACCESS_TOKEN = Deno.env.get("MP_ACCESS_TOKEN") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const STATUS_MAP: Record<string, string> = {
  authorized: "active",
  paused: "paused",
  cancelled: "cancelled",
  pending: "pending",
};

Deno.serve(async (req) => {
  // Sempre respondemos 200 rápido para o Mercado Pago não reenviar em loop;
  // erros internos são apenas logados.
  try {
    const url = new URL(req.url);
    let preapprovalId = url.searchParams.get("id") ??
      url.searchParams.get("data.id");
    let topic = url.searchParams.get("type") ?? url.searchParams.get("topic");

    if (req.method === "POST") {
      try {
        const body = await req.json();
        topic = body.type ?? body.topic ?? topic;
        preapprovalId = body?.data?.id ?? body?.id ?? preapprovalId;
      } catch {
        /* corpo vazio: usamos a query string */
      }
    }

    // Só nos interessa o ciclo de vida da assinatura (preapproval).
    if (topic && !String(topic).includes("preapproval")) {
      return new Response("ignored", { status: 200 });
    }
    if (!preapprovalId) {
      return new Response("no id", { status: 200 });
    }

    // Consulta o status real da preapproval no Mercado Pago.
    const mpResp = await fetch(
      `https://api.mercadopago.com/preapproval/${preapprovalId}`,
      { headers: { Authorization: `Bearer ${MP_ACCESS_TOKEN}` } },
    );
    if (!mpResp.ok) {
      console.error("Falha ao consultar preapproval", await mpResp.text());
      return new Response("lookup failed", { status: 200 });
    }
    const pre = await mpResp.json();
    const newStatus = STATUS_MAP[pre.status] ?? "pending";
    const userId = pre.external_reference as string | undefined;

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    // Calcula o fim do período corrente (próxima cobrança), se disponível.
    const periodEnd = pre?.auto_recurring?.end_date ??
      pre?.next_payment_date ?? null;

    const update: Record<string, unknown> = {
      status: newStatus,
      updated_at: new Date().toISOString(),
    };
    if (periodEnd) update.current_period_end = periodEnd;

    const { data: updated } = await admin
      .from("subscriptions")
      .update(update)
      .eq("mp_preapproval_id", preapprovalId)
      .select("user_id, group_id")
      .maybeSingle();

    const targetUser = updated?.user_id ?? userId;
    if (targetUser) {
      await admin
        .from("profiles")
        .update({ is_premium: newStatus === "active" })
        .eq("id", targetUser);
    }

    return new Response("ok", { status: 200 });
  } catch (err) {
    console.error("Erro no webhook", err);
    return new Response("error", { status: 200 });
  }
});

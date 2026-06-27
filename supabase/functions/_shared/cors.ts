// Cabeçalhos CORS compartilhados pelas Edge Functions do Vida Rica.
// Configure ALLOWED_ORIGIN nos secrets do Supabase com a URL exata do frontend
// (ex: https://seudominio.com). Sem isso, qualquer origem é aceita (*).
const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

export const corsHeaders = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

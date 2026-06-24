// Cabeçalhos CORS compartilhados pelas Edge Functions do Vida Rica.
// O front-end (index.html) é servido de outra origem (Supabase Storage, Pages,
// localhost, etc.), então liberamos as chamadas com os cabeçalhos abaixo.
export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Edge Function: create-user
// Crea un utente Auth + la riga corrispondente in "profili", solo se il chiamante è ADMIN.
// Va incollata nel dashboard Supabase (Edge Functions → New function → nome "create-user").

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Metodo non permesso" }, 405);
  }

  try {
    const authHeader = req.headers.get("Authorization") || "";
    const token = authHeader.replace("Bearer ", "");
    if (!token) return jsonResponse({ error: "Token mancante" }, 401);

    // Verifica chi è il chiamante passando il token direttamente (evita blocchi legati allo storage lato server)
    const supabaseAuth = createClient(SUPABASE_URL, ANON_KEY);
    const { data: { user }, error: userError } = await supabaseAuth.auth.getUser(token);
    if (userError || !user) return jsonResponse({ error: "Utente non valido" }, 401);

    // Client con privilegi di servizio (solo lato server, mai nel browser)
    const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

    const { data: profiloChiamante } = await supabaseAdmin
      .from("profili")
      .select("ruolo")
      .eq("id", user.id)
      .single();

    if (!profiloChiamante || profiloChiamante.ruolo !== "ADMIN") {
      return jsonResponse({ error: "Solo l'Admin può creare accessi." }, 403);
    }

    const body = await req.json();
    const azione = body.action || "create";

    if (azione === "reset_password") {
      const { email, newPassword } = body;
      if (!email || !newPassword) {
        return jsonResponse({ error: "Email e nuova password sono obbligatorie." }, 400);
      }
      if (newPassword.length < 6) {
        return jsonResponse({ error: "La password deve avere almeno 6 caratteri." }, 400);
      }
      const { data: elenco, error: listError } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 1000 });
      if (listError) return jsonResponse({ error: listError.message }, 500);
      const utenteTrovato = elenco.users.find((u) => u.email === email);
      if (!utenteTrovato) return jsonResponse({ error: "Nessun utente trovato con questa email." }, 404);

      const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(utenteTrovato.id, { password: newPassword });
      if (updateError) return jsonResponse({ error: updateError.message }, 400);

      return jsonResponse({ ok: true });
    }

    const { email, password, ruolo, laboratorio_id, studio_id, medico_id } = body;

    if (!email || !password || !ruolo) {
      return jsonResponse({ error: "Email, password e ruolo sono obbligatori." }, 400);
    }
    if (password.length < 6) {
      return jsonResponse({ error: "La password deve avere almeno 6 caratteri." }, 400);
    }

    const { data: nuovoUtente, error: createError } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
    });
    if (createError) return jsonResponse({ error: createError.message }, 400);

    const { error: profiloError } = await supabaseAdmin.from("profili").insert({
      id: nuovoUtente.user.id,
      ruolo,
      laboratorio_id: laboratorio_id || null,
      studio_id: studio_id || null,
      medico_id: medico_id || null,
      attivo: true,
    });
    if (profiloError) {
      return jsonResponse({ error: "Utente creato ma profilo non salvato: " + profiloError.message }, 500);
    }

    return jsonResponse({ ok: true, id: nuovoUtente.user.id });
  } catch (e) {
    return jsonResponse({ error: String(e) }, 500);
  }
});

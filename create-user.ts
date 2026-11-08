// Edge Function: create-user (pubblicata come "hyper-worker")
// Crea accessi (utente Auth + profilo) e reimposta password.
//  - Admin Nuovalab: come prima (crea accesso per laboratorio/studio/medico, reimposta password).
//  - Gestore (/admin, solo il titolare): crea un laboratorio cliente con il suo accesso, reimposta le password dei clienti.
//  - Laboratorio cliente (abbonamento attivo): crea e gestisce gli accessi dei SUOI studi e medici, e solo quelli.

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
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}
const emailOk = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);
const pulisci = (v: unknown, max = 200) => String(v ?? "").trim().slice(0, max);

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "Metodo non permesso" }, 405);

  try {
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    if (!token) return jsonResponse({ error: "Token mancante" }, 401);
    const supabaseAuth = createClient(SUPABASE_URL, ANON_KEY);
    const { data: { user }, error: userError } = await supabaseAuth.auth.getUser(token);
    if (userError || !user) return jsonResponse({ error: "Utente non valido" }, 401);

    const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: chiamante } = await supabaseAdmin.from("profili").select("ruolo, laboratorio_id, cliente_id").eq("id", user.id).single();
    const { data: gestore } = await supabaseAdmin.from("gestori").select("user_id").eq("user_id", user.id).maybeSingle();

    const body = await req.json();
    const azione = body.action || "create";

    // utente Auth + profilo (la password iniziale va cambiata al primo accesso)
    async function creaAccesso(email: string, password: string, profilo: Record<string, unknown>, cambio: boolean) {
      if (!emailOk(email)) return { error: "Email non valida." };
      if (!password || password.length < 8) return { error: "La password deve avere almeno 8 caratteri." };
      const { data: nuovo, error: e1 } = await supabaseAdmin.auth.admin.createUser({ email, password, email_confirm: true });
      if (e1 || !nuovo?.user) return { error: /registered|exists/i.test(e1?.message || "") ? "Questa email ha già un accesso." : (e1?.message || "Accesso non creato") };
      const { error: e2 } = await supabaseAdmin.from("profili").insert({ id: nuovo.user.id, attivo: true, deve_cambiare_password: cambio, ...profilo });
      if (e2) { await supabaseAdmin.auth.admin.deleteUser(nuovo.user.id); return { error: "Profilo non salvato: " + e2.message }; }
      return { id: nuovo.user.id };
    }
    async function utentePerEmail(email: string) {
      const { data: id } = await supabaseAdmin.rpc("sso_user_id", { p_email: email });
      return (id as string) || null;
    }
    async function reimposta(uid: string, nuova: string) {
      if (!nuova || nuova.length < 8) return "La password deve avere almeno 8 caratteri.";
      const { error } = await supabaseAdmin.auth.admin.updateUserById(uid, { password: nuova, ban_duration: "none" });
      if (error) return error.message;
      await supabaseAdmin.from("profili").update({ deve_cambiare_password: true }).eq("id", uid);
      return null;
    }

    /* ---------- gestore (/admin) ---------- */
    if (azione === "crea_cliente" || azione === "reset_cliente" || azione === "utenti_cliente_gestore") {
      if (!gestore) return jsonResponse({ error: "Solo il gestore della piattaforma." }, 403);
      if (azione === "crea_cliente") {
        const nome = pulisci(body.nome, 120), email = pulisci(body.email, 200).toLowerCase();
        if (!nome || !email) return jsonResponse({ error: "Nome del laboratorio ed email sono obbligatori." }, 400);
        const maxStudi = Math.max(1, Math.min(500, parseInt(body.max_studi) || 3));
        const scadenza = /^\d{4}-\d{2}-\d{2}$/.test(body.scadenza || "") ? body.scadenza : null;
        const { data: c, error: e1 } = await supabaseAdmin.from("clienti").insert({ nome, email, referente: pulisci(body.referente, 120),
          telefono: pulisci(body.telefono, 40), note: pulisci(body.note, 1000), max_studi: maxStudi, scadenza }).select("id").single();
        if (e1 || !c) return jsonResponse({ error: e1?.message || "Cliente non creato" }, 400);
        const { data: lab, error: e2 } = await supabaseAdmin.from("laboratori").insert({ nome, email, cliente_id: c.id, licenze_studio: maxStudi, attivo: true }).select("id").single();
        if (e2 || !lab) { await supabaseAdmin.from("clienti").delete().eq("id", c.id); return jsonResponse({ error: /unique|duplicate/i.test(e2?.message || "") ? "Questa email è già usata da un altro laboratorio." : (e2?.message || "Laboratorio non creato") }, 400); }
        const r = await creaAccesso(email, String(body.password || ""), { ruolo: "LABORATORIO", laboratorio_id: lab.id }, true);
        if (r.error) {
          await supabaseAdmin.from("laboratori").delete().eq("id", lab.id);
          await supabaseAdmin.from("clienti").delete().eq("id", c.id);
          return jsonResponse({ error: r.error }, 400);
        }
        return jsonResponse({ ok: true, cliente: c.id });
      }
      if (azione === "reset_cliente") {
        const email = pulisci(body.email, 200).toLowerCase();
        const uid = await utentePerEmail(email);
        if (!uid) return jsonResponse({ error: "Nessun accesso con questa email." }, 404);
        const { data: p } = await supabaseAdmin.from("profili").select("cliente_id").eq("id", uid).single();
        if (!p?.cliente_id) return jsonResponse({ error: "Questa email non è di un cliente: usa la gestione utenti To Smile." }, 400);
        const err = await reimposta(uid, String(body.newPassword || ""));
        if (err) return jsonResponse({ error: err }, 400);
        await supabaseAdmin.from("richieste_reset").update({ evasa: true }).ilike("email", email);
        return jsonResponse({ ok: true });
      }
      if (azione === "utenti_cliente_gestore") {
        const { data: pp } = await supabaseAdmin.from("profili").select("id, ruolo, attivo, studio_id, medico_id").eq("cliente_id", body.cliente);
        const out = [];
        for (const p of pp || []) { const { data: u } = await supabaseAdmin.auth.admin.getUserById(p.id); out.push({ email: u?.user?.email, ruolo: p.ruolo, attivo: p.attivo, ultimo: u?.user?.last_sign_in_at }); }
        return jsonResponse({ utenti: out });
      }
    }

    /* ---------- laboratorio cliente: accessi dei suoi studi e medici ---------- */
    if (azione === "accesso_studio" || azione === "utenti_mio_cliente" || azione === "reset_mio_utente" || azione === "attiva_utente") {
      if (!chiamante || chiamante.ruolo !== "LABORATORIO" || !chiamante.cliente_id) return jsonResponse({ error: "Non autorizzato." }, 403);
      const { data: cl } = await supabaseAdmin.from("clienti").select("sospeso, scadenza").eq("id", chiamante.cliente_id).single();
      const oggi = new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Rome" });
      if (!cl || cl.sospeso || (cl.scadenza && cl.scadenza < oggi)) return jsonResponse({ error: "Abbonamento non attivo." }, 403);
      const cliente = chiamante.cliente_id;
      if (azione === "accesso_studio") {
        const ruolo = body.ruolo === "MEDICO" ? "MEDICO" : "STUDIO";
        let profilo: Record<string, unknown>;
        if (ruolo === "STUDIO") {
          const { data: s } = await supabaseAdmin.from("studi").select("id").eq("id", body.studio_id).eq("cliente_id", cliente).maybeSingle();
          if (!s) return jsonResponse({ error: "Studio non trovato." }, 400);
          profilo = { ruolo, studio_id: s.id };
        } else {
          const { data: m } = await supabaseAdmin.from("medici").select("id, studio_id, studi!inner(cliente_id)").eq("id", body.medico_id).eq("studi.cliente_id", cliente).maybeSingle();
          if (!m) return jsonResponse({ error: "Medico non trovato." }, 400);
          profilo = { ruolo, medico_id: m.id };
        }
        const r = await creaAccesso(pulisci(body.email, 200).toLowerCase(), String(body.password || ""), profilo, true);
        if (r.error) return jsonResponse({ error: r.error }, 400);
        if (ruolo === "STUDIO") await supabaseAdmin.from("profili_studi").insert({ profilo_id: r.id, studio_id: profilo.studio_id, medico_id: null });
        return jsonResponse({ ok: true });
      }
      // elenco degli accessi del cliente
      const { data: pp } = await supabaseAdmin.from("profili").select("id, ruolo, attivo, studio_id, medico_id, deve_cambiare_password").eq("cliente_id", cliente);
      if (azione === "utenti_mio_cliente") {
        const out = [];
        for (const p of pp || []) {
          const { data: u } = await supabaseAdmin.auth.admin.getUserById(p.id);
          out.push({ id: p.id, email: u?.user?.email, ruolo: p.ruolo, attivo: p.attivo, studio_id: p.studio_id, medico_id: p.medico_id,
            primo_accesso: p.deve_cambiare_password, ultimo: u?.user?.last_sign_in_at, io: p.id === user.id });
        }
        return jsonResponse({ utenti: out });
      }
      const p = (pp || []).find((x) => x.id === body.id);
      if (!p) return jsonResponse({ error: "Accesso non trovato." }, 404);
      if (azione === "reset_mio_utente") {
        const err = await reimposta(p.id, String(body.newPassword || ""));
        if (err) return jsonResponse({ error: err }, 400);
        return jsonResponse({ ok: true });
      }
      if (azione === "attiva_utente") {
        if (p.id === user.id) return jsonResponse({ error: "Non puoi disattivare il tuo accesso." }, 400);
        const attivo = !!body.attivo;
        await supabaseAdmin.from("profili").update({ attivo }).eq("id", p.id);
        await supabaseAdmin.auth.admin.updateUserById(p.id, { ban_duration: attivo ? "none" : "876000h" });
        return jsonResponse({ ok: true });
      }
    }

    /* ---------- Admin Nuovalab (come prima) ---------- */
    if (!chiamante || chiamante.ruolo !== "ADMIN") return jsonResponse({ error: "Solo l'Admin può creare accessi." }, 403);

    if (azione === "reset_password") {
      const { email, newPassword } = body;
      if (!email || !newPassword) return jsonResponse({ error: "Email e nuova password sono obbligatorie." }, 400);
      if (newPassword.length < 6) return jsonResponse({ error: "La password deve avere almeno 6 caratteri." }, 400);
      const { data: elenco, error: listError } = await supabaseAdmin.auth.admin.listUsers({ page: 1, perPage: 1000 });
      if (listError) return jsonResponse({ error: listError.message }, 500);
      const utenteTrovato = elenco.users.find((u) => u.email === email);
      if (!utenteTrovato) return jsonResponse({ error: "Nessun utente trovato con questa email." }, 404);
      const { error: updateError } = await supabaseAdmin.auth.admin.updateUserById(utenteTrovato.id, { password: newPassword });
      if (updateError) return jsonResponse({ error: updateError.message }, 400);
      return jsonResponse({ ok: true });
    }

    const { email, password, ruolo, laboratorio_id, studio_id, medico_id } = body;
    if (!email || !password || !ruolo) return jsonResponse({ error: "Email, password e ruolo sono obbligatori." }, 400);
    if (password.length < 6) return jsonResponse({ error: "La password deve avere almeno 6 caratteri." }, 400);
    const { data: nuovoUtente, error: createError } = await supabaseAdmin.auth.admin.createUser({ email, password, email_confirm: true });
    if (createError) return jsonResponse({ error: createError.message }, 400);
    const { error: profiloError } = await supabaseAdmin.from("profili").insert({
      id: nuovoUtente.user.id, ruolo, laboratorio_id: laboratorio_id || null, studio_id: studio_id || null, medico_id: medico_id || null, attivo: true,
    });
    if (profiloError) return jsonResponse({ error: "Utente creato ma profilo non salvato: " + profiloError.message }, 500);
    return jsonResponse({ ok: true, id: nuovoUtente.user.id });
  } catch (e) {
    return jsonResponse({ error: String(e) }, 500);
  }
});

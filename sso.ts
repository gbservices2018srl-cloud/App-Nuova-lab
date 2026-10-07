// Funzione "sso": ingresso dall'accesso unico To Smile (appgestione.it).
// 1) appgestione.it manda qui il browser con un biglietto monouso (?ticket=...)
// 2) la funzione lo fa verificare ad appgestione.it, che risponde chi è la persona e che ruolo ha
// 3) prepara l'accesso Supabase per quella email e rimanda all'app con un codice monouso (#sso=...),
//    che l'app scambia con la sessione (verifyOtp). Nessuna email viene inviata.
// Con un biglietto "revoke" (persona disattivata o senza più accesso) blocca l'utente.
import { createClient } from "npm:@supabase/supabase-js@2";

const CENTRAL = "https://appgestione.it";
const APP = "laboratorio";
const APP_URL = "https://laboratorio.appgestione.it/";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const back = (hash: string) => new Response(null, { status: 302, headers: { Location: APP_URL + "#" + hash, "Cache-Control": "no-store" } });
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Ticket = { purpose: "login" | "revoke"; email: string; firstName?: string; lastName?: string; role?: "user" | "admin" };

// Nuovalab: chi è amministratore nell'accesso unico diventa ADMIN se non ha già un profilo.
// Gli altri devono avere un profilo creato dall'Admin Nuovalab (laboratorio, studio o medico).
async function ensureProfile(id: string, t: Ticket, _email: string): Promise<boolean> {
  const { data: p } = await admin.from("profili").select("id, attivo").eq("id", id).maybeSingle();
  if (p) return p.attivo !== false;
  if (t.role !== "admin") return false;
  const { error } = await admin.from("profili").insert({ id, ruolo: "ADMIN", attivo: true });
  return !error;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  let ticket = url.searchParams.get("ticket") || "";
  const isPost = req.method === "POST";
  if (!ticket && isPost) { try { ticket = (await req.json()).ticket || ""; } catch { /* corpo vuoto */ } }
  if (!ticket) return isPost ? json({ error: "biglietto mancante" }, 400) : back("sso_errore=biglietto");

  const r = await fetch(CENTRAL + "/api/sso/ticket", {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ticket, app: APP }),
  });
  if (!r.ok) return isPost ? json({ error: "biglietto non valido" }, 401) : back("sso_errore=scaduto");
  const t: Ticket = await r.json();
  const email = String(t.email || "").trim().toLowerCase();
  if (!email) return isPost ? json({ error: "email mancante" }, 400) : back("sso_errore=email");

  const { data: uid } = await admin.rpc("sso_user_id", { p_email: email });

  if (t.purpose === "revoke") {
    if (uid) await admin.auth.admin.updateUserById(uid as string, { ban_duration: "876000h" });
    return json({ ok: true, blocked: !!uid });
  }

  let id = uid as string | null;
  if (!id) {
    // Nessun accesso in questa app: lo creiamo solo per chi qui deve essere amministratore.
    if (t.role !== "admin") return back("sso_noprofilo=" + encodeURIComponent(email));
    const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true });
    if (error || !data.user) return back("sso_errore=utente");
    id = data.user.id;
  } else {
    await admin.auth.admin.updateUserById(id, { ban_duration: "none" }); // eventuale blocco precedente
  }
  const ok = await ensureProfile(id, t, email);
  if (!ok) return back("sso_noprofilo=" + encodeURIComponent(email));

  const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (linkError || !link?.properties?.hashed_token) return back("sso_errore=link");
  return back("sso=" + encodeURIComponent(link.properties.hashed_token));
});

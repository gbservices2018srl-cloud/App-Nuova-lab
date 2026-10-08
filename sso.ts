// Funzione "sso": ingresso dall'accesso unico To Smile (appgestione.it).
// 1) appgestione.it manda qui il browser con un biglietto monouso (?ticket=...)
// 2) la funzione lo fa verificare ad appgestione.it, che risponde chi è la persona e che ruolo ha
// 3) prepara l'accesso Supabase per quella email e rimanda all'app con un codice monouso (#sso=...),
//    che l'app scambia con la sessione (verifyOtp). Nessuna email viene inviata.
// Con un biglietto "revoke" (persona disattivata o senza più accesso) blocca l'utente.
// Con "catalog" restituisce laboratori, studi e medici (per scegliere il livello nel pannello accessi).
// Con "sync" aggiorna subito il profilo di chi è già entrato, dopo un cambio di livello.
// Il livello (ADMIN, LABORATORIO, STUDIO, MEDICO + quale) lo decide il pannello accessi: il profilo qui viene creato
// o aggiornato da solo, quindi nessuno deve avere una password di Nuovalab.
import { createClient } from "npm:@supabase/supabase-js@2";

const CENTRAL = "https://appgestione.it";
const APP = "laboratorio";
const APP_URL = "https://laboratorio.appgestione.it/";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const back = (hash: string) => new Response(null, { status: 302, headers: { Location: APP_URL + "#" + hash, "Cache-Control": "no-store" } });
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

type Ticket = { purpose: "login" | "revoke" | "catalog" | "sync"; email: string; firstName?: string; lastName?: string;
  role?: "user" | "admin"; livello?: string | null; ente?: string | null };
const LIVELLI = ["ADMIN", "LABORATORIO", "STUDIO", "MEDICO"];

// Profilo secondo il livello scelto nel pannello accessi (crea o aggiorna)
async function applicaLivello(id: string, t: Ticket, login: boolean): Promise<boolean> {
  const L = String(t.livello || "");
  if (!LIVELLI.includes(L)) return false;
  const row: Record<string, unknown> = { ruolo: L, laboratorio_id: null, studio_id: null, medico_id: null, attivo: true };
  const tab = { LABORATORIO: "laboratori", STUDIO: "studi", MEDICO: "medici" }[L as "LABORATORIO" | "STUDIO" | "MEDICO"];
  if (tab) {
    if (!t.ente) return false;
    const { data } = await admin.from(tab).select("id").eq("id", t.ente).maybeSingle();
    if (!data) return false;
    row[{ laboratori: "laboratorio_id", studi: "studio_id", medici: "medico_id" }[tab]!] = t.ente;
  }
  if (login) row.deve_cambiare_password = false; // entra con l'accesso To Smile: nessuna password da cambiare qui
  const { data: p } = await admin.from("profili").select("id").eq("id", id).maybeSingle();
  const { error } = p ? await admin.from("profili").update(row).eq("id", id)
    : await admin.from("profili").insert({ id, ...row, deve_cambiare_password: false });
  if (error) console.error("profilo", error.message);
  return !error;
}

async function catalogo() {
  const [l, s, m] = await Promise.all([
    admin.from("laboratori").select("id, nome").eq("attivo", true).order("nome"),
    admin.from("studi").select("id, nome").eq("attivo", true).order("nome"),
    admin.from("medici").select("id, nome, studi(nome)").eq("attivo", true).order("nome"),
  ]);
  return {
    laboratori: (l.data || []).map((x) => ({ id: x.id, nome: x.nome })),
    studi: (s.data || []).map((x) => ({ id: x.id, nome: x.nome })),
    // deno-lint-ignore no-explicit-any
    medici: (m.data || []).map((x: any) => ({ id: x.id, nome: x.nome, info: x.studi?.nome || "" })),
  };
}

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

  if (t.purpose === "catalog") return json({ enti: await catalogo() });

  const { data: uid } = await admin.rpc("sso_user_id", { p_email: email });

  if (t.purpose === "sync") { // cambio di livello: aggiorna il profilo solo se la persona esiste già qui
    if (uid && t.livello) await applicaLivello(uid as string, t, false);
    return json({ ok: true });
  }

  if (t.purpose === "revoke") {
    if (uid) await admin.auth.admin.updateUserById(uid as string, { ban_duration: "876000h" });
    return json({ ok: true, blocked: !!uid });
  }

  let id = uid as string | null;
  if (!id) {
    // Nessun accesso in questa app: lo creiamo se il pannello ha scelto il livello, o per chi è amministratore.
    if (t.role !== "admin" && !t.livello) return back("sso_noprofilo=" + encodeURIComponent(email));
    const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true });
    if (error || !data.user) return back("sso_errore=utente");
    id = data.user.id;
  } else {
    await admin.auth.admin.updateUserById(id, { ban_duration: "none" }); // eventuale blocco precedente
  }
  const ok = t.livello ? await applicaLivello(id, t, true) : await ensureProfile(id, t, email);
  if (!ok) return back("sso_noprofilo=" + encodeURIComponent(email));

  const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email });
  if (linkError || !link?.properties?.hashed_token) return back("sso_errore=link");
  return back("sso=" + encodeURIComponent(link.properties.hashed_token));
});

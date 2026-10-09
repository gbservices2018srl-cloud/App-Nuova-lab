// Funzione "sso": ingresso dall'accesso unico To Smile (appgestione.it).
// 1) appgestione.it manda qui il browser con un biglietto monouso (?ticket=...)
// 2) la funzione lo fa verificare ad appgestione.it, che risponde chi è la persona e che ruolo ha
// 3) prepara l'accesso Supabase per quella email e rimanda all'app con un codice monouso (#sso=...),
//    che l'app scambia con la sessione (verifyOtp). Nessuna email viene inviata.
// Con un biglietto "revoke" (persona disattivata o senza più accesso) blocca l'utente.
// Con "catalog" restituisce laboratori, studi e medici (per scegliere il livello nel pannello accessi).
// Con "sync" (persona appena approvata, o permessi/dati cambiati) crea o aggiorna subito utente e profilo,
// senza aspettare il primo ingresso. "Nuovo medico" crea anche il medico nello studio scelto, con i dati dell'albo.
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

type Ticket = { purpose: "login" | "revoke" | "catalog" | "sync" | "sedi"; sedi?: Sede[]; email: string; firstName?: string; lastName?: string;
  role?: "user" | "admin"; livello?: string | null; ente?: string | null; oldEmail?: string | null; ssoId?: string | null;
  cf?: string | null; alboProvincia?: string | null; alboNumero?: string | null };
type Sede = { id: string; nome: string; sigla: string; email: string; indirizzo: string; societa: string; riuniti: number; attiva: boolean };
const normSede = (s: unknown) => String(s || "").toLowerCase().replace(/to\s*smile|studio|sede|ambulatorio/g, "").replace(/[^a-z0-9]/g, "");
const spiega = (m: string) => /duplicate|unique/i.test(m) ? "sigla o email già usate da un altro studio" : m;
// Sedi del gruppo dal pannello accessi → studi di Nuovalab (nome, sigla, email, attivo). Gli studi esterni restano come sono.
async function copiaSedi(sedi: Sede[]): Promise<string[]> {
  const avvisi: string[] = [];
  const { data } = await admin.from("studi").select("id, nome, sigla, email, central_id");
  // deno-lint-ignore no-explicit-any
  const lista: any[] = data || [];
  for (const x of sedi) {
    const s = lista.find((r) => r.central_id === x.id) || lista.find((r) => !r.central_id && (
      String(r.sigla || "").trim().toUpperCase() === x.sigla.toUpperCase() ||
      (x.email && String(r.email || "").toLowerCase() === x.email.toLowerCase()) || normSede(r.nome) === normSede(x.nome)));
    if (!s && !x.attiva) continue;
    const row: Record<string, unknown> = { nome: x.nome, sigla: x.sigla, attivo: x.attiva, central_id: x.id };
    if (x.email) row.email = x.email;
    if (s) {
      const { error } = await admin.from("studi").update(row).eq("id", s.id);
      if (error) avvisi.push(`${x.nome}: ${spiega(error.message)}`); else s.central_id = x.id;
    } else if (!x.email) avvisi.push(`${x.nome}: manca l'email della sede, in Nuovalab non è stata creata.`);
    else {
      const { error } = await admin.from("studi").insert(row);
      if (error) avvisi.push(`${x.nome}: ${spiega(error.message)}`);
    }
  }
  return avvisi;
}
type Esito = { ok: boolean; ente?: string; enteNome?: string; motivo?: string };
const LIVELLI = ["ADMIN", "LABORATORIO", "STUDIO", "MEDICO"];

// "Nuovo medico" nello studio scelto: lo crea con nome, email e albo della persona (o riusa quello con la stessa email)
async function medicoNuovo(studioId: string, t: Ticket, email: string): Promise<{ id?: string; nome?: string; motivo?: string }> {
  const { data: st } = await admin.from("studi").select("id, nome").eq("id", studioId).maybeSingle();
  if (!st) return { motivo: "studio non trovato" };
  const { data: c } = await admin.from("medici").select("id, nome").eq("studio_id", studioId).ilike("email", email).maybeSingle();
  if (c) return { id: c.id, nome: c.nome };
  const prov = String(t.alboProvincia || "").toUpperCase(), num = String(t.alboNumero || "");
  if (!/^[A-Z]{2}$/.test(prov) || !num) return { motivo: "mancano provincia e numero d'albo" };
  const nome = `${t.firstName || ""} ${t.lastName || ""}`.trim() || email;
  const { data, error } = await admin.from("medici").insert({ studio_id: studioId, nome, email, provincia_albo: prov, numero_albo: num, attivo: true })
    .select("id, nome").single();
  if (error || !data) return { motivo: error?.message || "medico non creato" };
  return { id: data.id, nome: `${data.nome} · ${st.nome}` };
}

// Profilo secondo il livello scelto nel pannello accessi (crea o aggiorna)
async function applicaLivello(id: string, t: Ticket, login: boolean, email: string): Promise<Esito> {
  const L = String(t.livello || "");
  if (!LIVELLI.includes(L)) return { ok: false, motivo: "livello sconosciuto" };
  const row: Record<string, unknown> = { ruolo: L, laboratorio_id: null, studio_id: null, medico_id: null, attivo: true };
  const tab = { LABORATORIO: "laboratori", STUDIO: "studi", MEDICO: "medici" }[L as "LABORATORIO" | "STUDIO" | "MEDICO"];
  const esito: Esito = { ok: true };
  if (tab) {
    let ente = String(t.ente || "");
    if (!ente) return { ok: false, motivo: "manca la scelta" };
    if (L === "MEDICO" && ente.startsWith("nuovo:")) {
      const m = await medicoNuovo(ente.slice(6), t, email);
      if (!m.id) return { ok: false, motivo: m.motivo };
      ente = m.id; esito.ente = m.id; esito.enteNome = m.nome;
    } else {
      const { data } = await admin.from(tab).select("id").eq("id", ente).maybeSingle();
      if (!data) return { ok: false, motivo: "non trovato in Nuovalab" };
    }
    row[{ laboratori: "laboratorio_id", studi: "studio_id", medici: "medico_id" }[tab]!] = ente;
  }
  if (login) row.deve_cambiare_password = false; // entra con l'accesso To Smile: nessuna password da cambiare qui
  const { data: p } = await admin.from("profili").select("id").eq("id", id).maybeSingle();
  const { error } = p ? await admin.from("profili").update(row).eq("id", id)
    : await admin.from("profili").insert({ id, ...row, deve_cambiare_password: false });
  if (error) { console.error("profilo", error.message); return { ok: false, motivo: error.message }; }
  return esito;
}

// Utente Supabase della persona (lo crea se non c'è), sbloccato, con l'email attuale e collegato al suo id dell'accesso unico
async function utente(email: string, uid: string | null, ssoId?: string | null): Promise<string | null> {
  const meta = ssoId ? { app_metadata: { central_id: ssoId } } : {};
  if (uid) {
    const { error } = await admin.auth.admin.updateUserById(uid, { ban_duration: "none", email, email_confirm: true, ...meta });
    if (error) await admin.auth.admin.updateUserById(uid, { ban_duration: "none", ...meta }); // email già usata da un altro utente: resta la vecchia
    return uid;
  }
  const { data, error } = await admin.auth.admin.createUser({ email, email_confirm: true, ...meta });
  return error || !data.user ? null : data.user.id;
}

async function catalogo() {
  const [l, s, m] = await Promise.all([
    admin.from("laboratori").select("id, nome").eq("attivo", true).order("nome"),
    admin.from("studi").select("id, nome, sigla, email").eq("attivo", true).order("nome"),
    admin.from("medici").select("id, nome, studi(nome)").eq("attivo", true).order("nome"),
  ]);
  return {
    laboratori: (l.data || []).map((x) => ({ id: x.id, nome: x.nome })),
    studi: (s.data || []).map((x) => ({ id: x.id, nome: x.nome, sigla: String(x.sigla || "").trim(), email: x.email })),
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
  if (t.purpose === "sedi") return json({ ok: true, avvisi: await copiaSedi(t.sedi || []) });

  // Chi è: prima per id dell'accesso unico (non cambia mai, nemmeno se cambia l'email), poi per email, poi per la vecchia email
  let uid: string | null = null;
  if (t.ssoId) uid = ((await admin.rpc("sso_user_by_central", { p_id: String(t.ssoId) })).data as string) || null;
  if (!uid) uid = ((await admin.rpc("sso_user_id", { p_email: email })).data as string) || null;
  if (!uid && t.oldEmail) uid = ((await admin.rpc("sso_user_id", { p_email: String(t.oldEmail).toLowerCase() })).data as string) || null;

  if (t.purpose === "sync") { // persona approvata o cambiata nel pannello: utente e profilo pronti subito
    if (!t.livello) return json({ ok: true }); // vecchio permesso senza livello: il profilo si gestisce dentro Nuovalab
    const id = await utente(email, uid, t.ssoId);
    if (!id) return json({ ok: false, motivo: "utente non creato" });
    return json(await applicaLivello(id, t, false, email));
  }

  if (t.purpose === "revoke") {
    if (uid) await admin.auth.admin.updateUserById(uid as string, { ban_duration: "876000h" });
    return json({ ok: true, blocked: !!uid });
  }

  // Nessun accesso in questa app: lo creiamo se il pannello ha scelto il livello, o per chi è amministratore.
  if (!uid && t.role !== "admin" && !t.livello) return back("sso_noprofilo=" + encodeURIComponent(email));
  const id = await utente(email, uid, t.ssoId);
  if (!id) return back("sso_errore=utente");
  const ok = t.livello ? (await applicaLivello(id, t, true, email)).ok : await ensureProfile(id, t, email);
  if (!ok) return back("sso_noprofilo=" + encodeURIComponent(email));

  // il link d'accesso va all'email che l'utente ha davvero qui (se la nuova email era già di un altro utente, resta la vecchia)
  const { data: au } = await admin.auth.admin.getUserById(id);
  const { data: link, error: linkError } = await admin.auth.admin.generateLink({ type: "magiclink", email: au?.user?.email || email });
  if (linkError || !link?.properties?.hashed_token) return back("sso_errore=link");
  return back("sso=" + encodeURIComponent(link.properties.hashed_token));
});

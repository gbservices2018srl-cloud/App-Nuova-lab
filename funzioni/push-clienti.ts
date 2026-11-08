// Edge Function "push-clienti": notifiche sul telefono per gli utenti dei laboratori clienti.
// La chiama solo il database (tosmile_notifica) con la sua chiave; chiavi e segreti stanno nel vault di Supabase.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
let segreti: Record<string, string> | null = null;

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("no", { status: 405 });
  if (!segreti) { const { data } = await admin.rpc("segreti_push"); segreti = data as Record<string, string>; }
  const chiave = (req.headers.get("Authorization") || "").replace("Bearer ", "");
  if (!segreti?.nuovalab_push_key || chiave !== segreti.nuovalab_push_key) return new Response("non autorizzato", { status: 401 });
  webpush.setVapidDetails("mailto:nuovalabsrl@gmail.com", segreti.nuovalab_vapid_public, segreti.nuovalab_vapid_private);
  const b = await req.json();
  const profili: string[] = Array.isArray(b.profili) ? b.profili : [];
  if (!profili.length) return Response.json({ inviate: 0 });
  const { data: iscr } = await admin.from("push_iscrizioni").select("id, endpoint, p256dh, auth").in("profilo_id", profili);
  const payload = JSON.stringify({ title: String(b.title || "Nuovalab"), body: String(b.body || ""), url: String(b.url || "/"), tag: b.tag || undefined });
  let inviate = 0;
  for (const s of iscr || []) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      inviate++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await admin.from("push_iscrizioni").delete().eq("id", s.id); // dispositivo non più valido
      else console.error("push", code, (e as Error).message);
    }
  }
  return Response.json({ inviate });
});

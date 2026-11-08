-- Notifiche sul telefono per i laboratori clienti (non passano dal centro notifiche To Smile).
-- Le chiavi (VAPID e chiave interna) sono nel vault di Supabase: nuovalab_vapid_private, nuovalab_vapid_public, nuovalab_push_key.
create table if not exists push_iscrizioni (
  id uuid primary key default uuid_generate_v4(),
  profilo_id uuid not null default auth.uid() references profili(id) on delete cascade,
  endpoint text not null unique, p256dh text not null, auth text not null,
  creato timestamptz not null default now()
);
alter table push_iscrizioni enable row level security;
create policy push_proprie on push_iscrizioni for all using (profilo_id = auth.uid()) with check (profilo_id = auth.uid());
-- segreti_push(): solo service_role; tosmile_notifica(): personale To Smile -> appgestione.it, clienti -> funzione push-clienti

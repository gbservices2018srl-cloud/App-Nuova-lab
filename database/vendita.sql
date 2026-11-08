-- ============================================================
-- NUOVALAB · vendita ai laboratori clienti (migrazione additiva)
-- I dati To Smile non cambiano: tutto ciò che è già nel database ha cliente_id vuoto
-- e per chi non è cliente ogni regola funziona esattamente come prima.
--  - clienti: i laboratori a cui vendi l'app (scadenza, sospeso, numero di studi, testi accettati)
--  - laboratori.cliente_id / studi.cliente_id / profili.cliente_id: a quale cliente appartengono (vuoto = To Smile)
--  - un cliente vede solo il suo gruppo (il suo laboratorio, i suoi studi e medici), mai gli altri
--  - cliente scaduto o sospeso: mio_ruolo() diventa vuoto, quindi non legge e non scrive più nulla
--  - gestori: chi governa /admin (solo il titolare)
-- ============================================================

create table if not exists clienti (
  id uuid primary key default uuid_generate_v4(),
  nome text not null,
  referente text not null default '',
  email text not null,
  telefono text not null default '',
  scadenza date,
  sospeso boolean not null default false,
  max_studi int not null default 3,
  note text not null default '',
  testi_accettati int,
  testi_accettati_il timestamptz,
  created_at timestamptz not null default now()
);
alter table clienti enable row level security; -- nessuna regola: si legge solo con le funzioni qui sotto

alter table laboratori add column if not exists cliente_id uuid references clienti(id);
alter table laboratori add column if not exists logo text;
alter table studi add column if not exists cliente_id uuid references clienti(id);
alter table profili add column if not exists cliente_id uuid references clienti(id);
create index if not exists idx_laboratori_cliente on laboratori(cliente_id);
create index if not exists idx_studi_cliente on studi(cliente_id);

create table if not exists gestori (user_id uuid primary key references auth.users(id) on delete cascade);
alter table gestori enable row level security;
insert into gestori (user_id) select id from auth.users where lower(email) = 'giancarlobogo@tosmile.it' on conflict do nothing;

create table if not exists testi_legali (
  tipo text primary key check (tipo in ('privacy', 'condizioni')),
  testo text not null default '',
  versione int not null default 1,
  aggiornato timestamptz not null default now()
);
alter table testi_legali enable row level security;
drop policy if exists testi_select on testi_legali;
create policy testi_select on testi_legali for select using (auth.role() = 'authenticated');
insert into testi_legali (tipo) values ('privacy'), ('condizioni') on conflict do nothing;

-- ---------- chi sono ----------
create or replace function sono_gestore() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from gestori where user_id = auth.uid())
$$;
create or replace function mio_cliente_id() returns uuid language sql stable security definer set search_path = public as $$
  select cliente_id from profili where id = auth.uid()
$$;
-- il ruolo vale solo se il cliente (se c'è) non è sospeso né scaduto
create or replace function mio_ruolo() returns ruolo_utente language sql stable security definer set search_path = public as $$
  select p.ruolo from profili p left join clienti c on c.id = p.cliente_id
  where p.id = auth.uid()
    and (c.id is null or not (c.sospeso or (c.scadenza is not null and c.scadenza < (now() at time zone 'Europe/Rome')::date)))
$$;
-- laboratorio e studio dello stesso gruppo (To Smile con To Smile, cliente con sé stesso)
create or replace function stesso_gruppo(p_studio uuid, p_lab uuid) returns boolean language sql stable security definer set search_path = public as $$
  select (select cliente_id from studi where id = p_studio) is not distinct from (select cliente_id from laboratori where id = p_lab)
$$;
create or replace function lab_del_mio_gruppo(p_lab uuid) returns boolean language sql stable security definer set search_path = public as $$
  select mio_ruolo() = 'ADMIN' or exists (select 1 from laboratori l where l.id = p_lab and l.cliente_id is not distinct from mio_cliente_id())
$$;

-- il profilo prende il cliente dal suo laboratorio, studio o medico
create or replace function profili_cliente() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.cliente_id := coalesce(
    (select cliente_id from laboratori where id = new.laboratorio_id),
    (select cliente_id from studi where id = new.studio_id),
    (select s.cliente_id from medici m join studi s on s.id = m.studio_id where m.id = new.medico_id));
  return new;
end $$;
drop trigger if exists trg_profili_cliente on profili;
create trigger trg_profili_cliente before insert or update of laboratorio_id, studio_id, medico_id on profili
  for each row execute function profili_cliente();

-- studio creato da un laboratorio cliente: appartiene al cliente e si collega da solo a quel laboratorio
create or replace function studi_cliente_prima() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.cliente_id is null and mio_ruolo() = 'LABORATORIO' then new.cliente_id := mio_cliente_id(); end if;
  return new;
end $$;
drop trigger if exists trg_studi_cliente_prima on studi;
create trigger trg_studi_cliente_prima before insert on studi for each row execute function studi_cliente_prima();
create or replace function studi_cliente_dopo() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.cliente_id is not null and mio_ruolo() = 'LABORATORIO' and mio_cliente_id() = new.cliente_id then
    insert into collegamenti (studio_id, laboratorio_id, stato, iniziato_da, attivato_at)
    values (new.id, mio_laboratorio_id(), 'attivo', 'LABORATORIO', now()) on conflict (studio_id, laboratorio_id) do nothing;
  end if;
  return new;
end $$;
drop trigger if exists trg_studi_cliente_dopo on studi;
create trigger trg_studi_cliente_dopo after insert on studi for each row execute function studi_cliente_dopo();

-- ---------- regole di sicurezza: stesso gruppo ----------
drop policy if exists laboratori_select on laboratori;
create policy laboratori_select on laboratori for select using (
  mio_ruolo() = 'ADMIN' or id = mio_laboratorio_id()
  or (mio_ruolo() = 'STUDIO' and cliente_id is not distinct from mio_cliente_id()));

drop policy if exists studi_select on studi;
create policy studi_select on studi for select using (
  mio_ruolo() = 'ADMIN'
  or (mio_ruolo() = 'LABORATORIO' and cliente_id is not distinct from mio_cliente_id())
  or (mio_ruolo() = 'STUDIO' and id = mio_studio_id())
  or (mio_ruolo() = 'MEDICO' and id = (select medici.studio_id from medici where medici.id = mio_medico_id())));
drop policy if exists studi_write on studi;
create policy studi_write on studi for insert with check (
  mio_ruolo() = 'ADMIN' or (mio_ruolo() = 'LABORATORIO' and cliente_id is not distinct from mio_cliente_id()));
drop policy if exists studi_update on studi;
create policy studi_update on studi for update using (
  mio_ruolo() = 'ADMIN' or (mio_ruolo() = 'LABORATORIO' and mio_cliente_id() is not null and cliente_id = mio_cliente_id()));

drop policy if exists medici_write on medici;
create policy medici_write on medici for insert with check (
  mio_ruolo() = 'STUDIO'
  or (mio_ruolo() = 'LABORATORIO' and mio_cliente_id() is not null and studio_id in (select id from studi where cliente_id = mio_cliente_id())));
drop policy if exists medici_update on medici;
create policy medici_update on medici for update using (
  (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id())
  or (mio_ruolo() = 'LABORATORIO' and mio_cliente_id() is not null and studio_id in (select id from studi where cliente_id = mio_cliente_id())));

drop policy if exists collegamenti_write on collegamenti;
create policy collegamenti_write on collegamenti for insert with check (
  mio_ruolo() = any (array['LABORATORIO'::ruolo_utente, 'STUDIO'::ruolo_utente, 'ADMIN'::ruolo_utente]) and stesso_gruppo(studio_id, laboratorio_id));
drop policy if exists collegamenti_update on collegamenti;
create policy collegamenti_update on collegamenti for update using (
  mio_ruolo() = 'ADMIN'
  or (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id())
  or (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id()));

drop policy if exists lavorazioni_insert on lavorazioni;
create policy lavorazioni_insert on lavorazioni for insert with check (
  mio_ruolo() = any (array['STUDIO'::ruolo_utente, 'LABORATORIO'::ruolo_utente]) and stesso_gruppo(studio_id, laboratorio_id));

-- elenchi del laboratorio (colori, materiali, ...): si vedono solo quelli del proprio gruppo
drop policy if exists colori_select on colori;
create policy colori_select on colori for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
drop policy if exists df_select on dati_fabbricante;
create policy df_select on dati_fabbricante for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
drop policy if exists materiali_cat_select on materiali_catalogo;
create policy materiali_cat_select on materiali_catalogo for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
drop policy if exists odt_select on odontotecnici;
create policy odt_select on odontotecnici for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
drop policy if exists tlm_select on tipi_lavoro_macro;
create policy tlm_select on tipi_lavoro_macro for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
drop policy if exists tp_select on tipi_problema;
create policy tp_select on tipi_problema for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
drop policy if exists tlmi_select on tipi_lavoro_micro;
create policy tlmi_select on tipi_lavoro_micro for select using (
  auth.role() = 'authenticated' and exists (select 1 from tipi_lavoro_macro m where m.id = tipi_lavoro_micro.macro_id and lab_del_mio_gruppo(m.laboratorio_id)));

-- file allegati: si leggono e si cancellano solo se si vede la lavorazione a cui appartengono
drop policy if exists allegati_storage_select on storage.objects;
create policy allegati_storage_select on storage.objects for select using (
  bucket_id = 'allegati' and auth.role() = 'authenticated'
  and (exists (select 1 from public.allegati a where a.storage_path = storage.objects.name) or owner = auth.uid()));
drop policy if exists allegati_storage_delete on storage.objects;
create policy allegati_storage_delete on storage.objects for delete using (
  bucket_id = 'allegati' and auth.role() = 'authenticated'
  and (exists (select 1 from public.allegati a where a.storage_path = storage.objects.name) or owner = auth.uid()));

-- ---------- elenchi dell'Admin To Smile: senza i dati dei clienti ----------
create or replace function public.admin_elenco_utenti()
 returns table(email text, ruolo text, entita text, attivo boolean) language plpgsql security definer set search_path to 'public' as $function$
begin
  if mio_ruolo() <> 'ADMIN' then raise exception 'Non autorizzato'; end if;
  return query
    select u.email::text, p.ruolo::text, coalesce(l.nome, s.nome, m.nome, '—')::text, p.attivo
    from profili p
    join auth.users u on u.id = p.id
    left join laboratori l on l.id = p.laboratorio_id
    left join studi s on s.id = p.studio_id
    left join medici m on m.id = p.medico_id
    where p.cliente_id is null
    order by p.ruolo::text, u.email;
end $function$;
create or replace function public.admin_elenco_pazienti()
 returns table(id uuid, cognome text, nome text, data_nascita date, studio text, lavorazioni bigint) language plpgsql security definer set search_path to 'public' as $function$
begin
  if mio_ruolo() is distinct from 'ADMIN' then raise exception 'Non autorizzato'; end if;
  return query
    select p.id, p.cognome::text, p.nome::text, p.data_nascita, s.nome::text,
           (select count(*) from lavorazioni l where l.paziente_id = p.id)
    from pazienti p left join studi s on s.id = p.studio_id
    where s.cliente_id is null
    order by s.nome, p.cognome, p.nome;
end $function$;

-- ---------- laboratorio cliente ----------
create or replace function stato_cliente() returns jsonb language sql stable security definer set search_path = public as $$
  select case when c.id is null then jsonb_build_object('cliente', false) else jsonb_build_object(
    'cliente', true, 'nome', c.nome, 'scadenza', c.scadenza, 'sospeso', c.sospeso, 'max_studi', c.max_studi,
    'scaduto', c.scadenza is not null and c.scadenza < (now() at time zone 'Europe/Rome')::date,
    'studi', (select count(*) from studi s where s.cliente_id = c.id and s.attivo),
    'versione_testi', (select max(versione) from testi_legali),
    'testi_da_accettare', p.ruolo = 'LABORATORIO' and coalesce(c.testi_accettati, 0) < (select max(versione) from testi_legali)
      and exists (select 1 from testi_legali where length(trim(testo)) > 0)) end
  from profili p left join clienti c on c.id = p.cliente_id where p.id = auth.uid()
$$;
create or replace function accetta_testi() returns void language plpgsql security definer set search_path = public as $$
declare c uuid := mio_cliente_id();
begin
  if c is null or mio_ruolo() is distinct from 'LABORATORIO' then raise exception 'Non autorizzato'; end if;
  update clienti set testi_accettati = (select max(versione) from testi_legali), testi_accettati_il = now() where id = c;
end $$;
create or replace function imposta_logo(p_logo text) returns void language plpgsql security definer set search_path = public as $$
begin
  if mio_ruolo() is distinct from 'LABORATORIO' then raise exception 'Non autorizzato'; end if;
  if p_logo is not null and (length(p_logo) > 700000 or p_logo !~ '^data:image/(png|jpeg|webp);base64,') then raise exception 'Logo non valido (immagine PNG o JPG, massimo 500 KB)'; end if;
  update laboratori set logo = p_logo where id = mio_laboratorio_id();
end $$;

-- ---------- /admin: solo il gestore ----------
create or replace function gestore_clienti() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sono_gestore() then raise exception 'Non autorizzato'; end if;
  return coalesce((select jsonb_agg(x order by x->>'nome') from (
    select jsonb_build_object('id', c.id, 'nome', c.nome, 'referente', c.referente, 'email', c.email, 'telefono', c.telefono,
      'scadenza', c.scadenza, 'sospeso', c.sospeso, 'max_studi', c.max_studi, 'note', c.note, 'creato', c.created_at,
      'testi_accettati', c.testi_accettati, 'testi_accettati_il', c.testi_accettati_il,
      'laboratorio', (select jsonb_build_object('id', l.id, 'nome', l.nome) from laboratori l where l.cliente_id = c.id order by l.created_at limit 1),
      'studi', (select count(*) from studi s where s.cliente_id = c.id and s.attivo),
      'utenti', (select count(*) from profili p where p.cliente_id = c.id),
      'lavori', (select count(*) from lavorazioni w join laboratori l on l.id = w.laboratorio_id where l.cliente_id = c.id),
      'ultimo_lavoro', (select max(w.created_at) from lavorazioni w join laboratori l on l.id = w.laboratorio_id where l.cliente_id = c.id)) x
    from clienti c) t), '[]'::jsonb);
end $$;
create or replace function gestore_aggiorna_cliente(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  if not sono_gestore() then raise exception 'Non autorizzato'; end if;
  update clienti set
    nome = coalesce(nullif(trim(p->>'nome'), ''), nome),
    referente = coalesce(p->>'referente', referente),
    telefono = coalesce(p->>'telefono', telefono),
    note = coalesce(p->>'note', note),
    scadenza = case when p ? 'scadenza' then nullif(p->>'scadenza', '')::date else scadenza end,
    sospeso = coalesce((p->>'sospeso')::boolean, sospeso),
    max_studi = coalesce((p->>'max_studi')::int, max_studi)
  where id = p_id;
  -- il numero di studi venduto è il limite di studi collegabili del suo laboratorio
  if p ? 'max_studi' then update laboratori set licenze_studio = (p->>'max_studi')::int where cliente_id = p_id; end if;
  if p ? 'nome' and nullif(trim(p->>'nome'), '') is not null then update laboratori set nome = trim(p->>'nome') where cliente_id = p_id; end if;
end $$;
create or replace function gestore_testi() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not sono_gestore() then raise exception 'Non autorizzato'; end if;
  return (select jsonb_object_agg(tipo, jsonb_build_object('testo', testo, 'versione', versione, 'aggiornato', aggiornato)) from testi_legali);
end $$;
create or replace function gestore_salva_testo(p_tipo text, p_testo text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not sono_gestore() then raise exception 'Non autorizzato'; end if;
  -- nuova versione: i clienti la dovranno riaccettare
  update testi_legali set testo = coalesce(p_testo, ''), versione = (select max(versione) from testi_legali) + 1, aggiornato = now() where tipo = p_tipo;
end $$;
create or replace function gestore_richieste_reset() returns table(id uuid, email text, creata timestamptz, cliente text) language plpgsql security definer set search_path = public as $$
begin
  if not sono_gestore() then raise exception 'Non autorizzato'; end if;
  return query select r.id, r.email::text, r.created_at, c.nome::text
    from richieste_reset r
    join auth.users u on lower(u.email) = lower(r.email)
    join profili p on p.id = u.id
    join clienti c on c.id = p.cliente_id
    where not r.evasa order by r.created_at;
end $$;

-- avvisi To Smile: mai ai clienti (le loro email non passano dal centro notifiche To Smile)
create or replace function public.tosmile_notifica(p_profili uuid[], p_titolo text, p_corpo text, p_url text default '/'::text, p_tag text default null::text)
 returns void language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare k text; ids text[]; mails text[]; dest uuid[];
begin
  select array_agg(x) into dest from unnest(p_profili) x
    where x is not null and x is distinct from auth.uid()
      and not exists (select 1 from profili pp where pp.id = x and pp.cliente_id is not null);
  if dest is null then return; end if;
  select decrypted_secret into k from vault.decrypted_secrets where name = 'tosmile_notify_key';
  if k is null then return; end if;
  select array_agg(distinct u.raw_app_meta_data->>'central_id') filter (where coalesce(u.raw_app_meta_data->>'central_id','') <> ''),
         array_agg(distinct lower(u.email)) filter (where coalesce(u.raw_app_meta_data->>'central_id','') = '')
    into ids, mails from auth.users u where u.id = any(dest);
  perform net.http_post(url := 'https://appgestione.it/api/notifiche/invia',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||k),
    body := jsonb_build_object('app','laboratorio','utenti',coalesce(to_jsonb(ids),'[]'::jsonb),'email',coalesce(to_jsonb(mails),'[]'::jsonb),
      'title',p_titolo,'body',left(coalesce(p_corpo,''),280),'url',coalesce(p_url,'/'),'tag',p_tag));
exception when others then raise warning 'tosmile_notifica: %', sqlerrm;
end $function$;

revoke all on function gestore_clienti, gestore_aggiorna_cliente, gestore_testi, gestore_salva_testo, gestore_richieste_reset from anon;
revoke all on function stato_cliente, accetta_testi, imposta_logo from anon;

-- sigla di 3 lettere libera per un nuovo studio (le sigle sono uniche in tutta la piattaforma)
create or replace function sigla_libera(p_nome text) returns text language plpgsql stable security definer set search_path = public as $$
declare base text; prova text; i int; lettere text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
begin
  if mio_ruolo() is null then raise exception 'Non autorizzato'; end if;
  base := upper(regexp_replace(coalesce(p_nome, ''), '[^A-Za-z]', '', 'g'));
  base := rpad(base, 3, 'X');
  prova := substr(base, 1, 3);
  if not exists (select 1 from studi where sigla = prova) then return prova; end if;
  for i in 1..26 loop
    prova := substr(base, 1, 2) || substr(lettere, i, 1);
    if not exists (select 1 from studi where sigla = prova) then return prova; end if;
  end loop;
  for i in 1..676 loop
    prova := substr(base, 1, 1) || substr(lettere, ((i - 1) / 26) + 1, 1) || substr(lettere, ((i - 1) % 26) + 1, 1);
    if not exists (select 1 from studi where sigla = prova) then return prova; end if;
  end loop;
  return null;
end $$;
revoke all on function sigla_libera from anon;

-- ============================================================
-- NUOVALAB — Schema Database v3 (Supabase / PostgreSQL)
-- Versione definitiva, allineata al prototipo completo:
-- laboratori e studi indipendenti collegati a molti-a-molti
-- (con richiesta/conferma e licenze), pazienti, medici,
-- lavorazioni con materiali multipli, riprogrammazione consegne,
-- firma prescrizione, chat isolata per coppia lab-studio/medico,
-- listino base + per studio, validazione documenti.
-- ============================================================

create extension if not exists "uuid-ossp";

-- ============================================================
-- 1. RUOLI & PROFILI UTENTE
-- ============================================================
create type ruolo_utente as enum ('ADMIN', 'LABORATORIO', 'STUDIO', 'MEDICO');

create table profili (
  id uuid primary key references auth.users(id) on delete cascade,
  ruolo ruolo_utente not null,
  laboratorio_id uuid,   -- se ruolo = LABORATORIO
  studio_id uuid,        -- se ruolo = STUDIO
  medico_id uuid,        -- se ruolo = MEDICO
  attivo boolean not null default true,
  created_at timestamptz not null default now()
);

-- ============================================================
-- 2. LABORATORI (indipendenti, con licenze studio)
-- ============================================================
create table laboratori (
  id uuid primary key default uuid_generate_v4(),
  nome text not null,
  email text not null unique,
  licenze_studio int not null default 3,
  attivo boolean not null default true,
  created_at timestamptz not null default now()
);

alter table profili add constraint fk_profili_laboratorio foreign key (laboratorio_id) references laboratori(id);

-- ============================================================
-- 3. STUDI (indipendenti, con licenze laboratorio)
-- ============================================================
create table studi (
  id uuid primary key default uuid_generate_v4(),
  nome text not null,
  sigla char(3) not null unique,
  email text not null unique,
  licenze_laboratorio int not null default 3,
  attivo boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table profili add constraint fk_profili_studio foreign key (studio_id) references studi(id);

-- ============================================================
-- 4. COLLEGAMENTI STUDIO ↔ LABORATORIO (molti a molti, con richiesta/conferma)
-- ============================================================
create type collegamento_stato as enum ('in_attesa_lab', 'in_attesa_studio', 'attivo', 'rimosso');
create type iniziato_da as enum ('LABORATORIO', 'STUDIO');

create table collegamenti (
  id uuid primary key default uuid_generate_v4(),
  studio_id uuid not null references studi(id),
  laboratorio_id uuid not null references laboratori(id),
  stato collegamento_stato not null default 'attivo',
  iniziato_da iniziato_da not null,
  created_at timestamptz not null default now(),
  attivato_at timestamptz,
  unique(studio_id, laboratorio_id)
);

create index idx_collegamenti_studio on collegamenti(studio_id);
create index idx_collegamenti_laboratorio on collegamenti(laboratorio_id);

-- Verifica licenza disponibile lato laboratorio prima di attivare un collegamento
create or replace function verifica_licenza_laboratorio() returns trigger as $$
declare
  attivi int;
  licenze int;
begin
  if NEW.stato = 'attivo' and (OLD is null or OLD.stato <> 'attivo') then
    select count(*) into attivi from collegamenti where laboratorio_id = NEW.laboratorio_id and stato = 'attivo';
    select licenze_studio into licenze from laboratori where id = NEW.laboratorio_id;
    if attivi >= licenze then
      raise exception 'Numero massimo di studi collegati raggiunto per questo laboratorio';
    end if;
  end if;
  return NEW;
end;
$$ language plpgsql;

create trigger trg_verifica_licenza_laboratorio
  before insert or update on collegamenti
  for each row execute function verifica_licenza_laboratorio();

-- Stesso controllo lato studio (licenze_laboratorio)
create or replace function verifica_licenza_studio() returns trigger as $$
declare
  attivi int;
  licenze int;
begin
  if NEW.stato = 'attivo' and (OLD is null or OLD.stato <> 'attivo') then
    select count(*) into attivi from collegamenti where studio_id = NEW.studio_id and stato = 'attivo';
    select licenze_laboratorio into licenze from studi where id = NEW.studio_id;
    if attivi >= licenze then
      raise exception 'Numero massimo di laboratori collegati raggiunto per questo studio';
    end if;
  end if;
  return NEW;
end;
$$ language plpgsql;

create trigger trg_verifica_licenza_studio
  before insert or update on collegamenti
  for each row execute function verifica_licenza_studio();

-- ============================================================
-- 5. MEDICI (professionisti collegati a uno studio)
-- ============================================================
create table medici (
  id uuid primary key default uuid_generate_v4(),
  studio_id uuid not null references studi(id),
  nome text not null,
  email text not null unique,
  provincia_albo char(2) not null,
  numero_albo text not null,
  numero_iscrizione_completo text generated always as (provincia_albo || '-' || numero_albo) stored,
  attivo boolean not null default true,
  created_at timestamptz not null default now()
);

alter table profili add constraint fk_profili_medico foreign key (medico_id) references medici(id);
create index idx_medici_studio on medici(studio_id);

-- ============================================================
-- 6. PAZIENTI (anagrafica stabile, solo Studio)
-- ============================================================
create table pazienti (
  id uuid primary key default uuid_generate_v4(),
  studio_id uuid not null references studi(id),
  cognome text not null,
  nome text not null,
  data_nascita date,
  riferimento_cartella text,
  created_at timestamptz not null default now()
);

create index idx_pazienti_studio on pazienti(studio_id);
create index idx_pazienti_nome on pazienti(studio_id, cognome, nome);

-- ============================================================
-- 7. IMPOSTAZIONI (per laboratorio)
-- ============================================================
create table tipi_lavoro_macro (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  nome text not null,
  ordine int not null default 0,
  unique(laboratorio_id, nome)
);

create table tipi_lavoro_micro (
  id uuid primary key default uuid_generate_v4(),
  macro_id uuid not null references tipi_lavoro_macro(id) on delete cascade,
  nome text not null,
  ordine int not null default 0,
  unique(macro_id, nome)
);

create table colori (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  nome text not null,
  unique(laboratorio_id, nome)
);

create table materiali_catalogo (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  nome text not null,
  unique(laboratorio_id, nome)
);

create table odontotecnici (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  nome text not null,
  unique(laboratorio_id, nome)
);

create table tipi_problema (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  nome text not null,
  unique(laboratorio_id, nome)
);

create table dati_fabbricante (
  laboratorio_id uuid primary key references laboratori(id),
  ragione_sociale text not null,
  indirizzo text not null,
  piva text not null
);

-- ============================================================
-- 8. LISTINO PREZZI: base per laboratorio + specifico per studio
-- ============================================================
create table listino_base (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  tipo_macro text not null,
  tipo_micro text not null,
  prezzo numeric(10,2) not null,
  unique(laboratorio_id, tipo_macro, tipo_micro)
);

create table listino_prezzi (
  id uuid primary key default uuid_generate_v4(),
  laboratorio_id uuid not null references laboratori(id),
  studio_id uuid not null references studi(id),
  tipo_macro text not null,
  tipo_micro text not null,
  prezzo numeric(10,2) not null,
  updated_at timestamptz not null default now(),
  unique(laboratorio_id, studio_id, tipo_macro, tipo_micro)
);

-- Alla prima attivazione di un collegamento, copia il listino base nel listino dello studio
create or replace function copia_listino_base() returns trigger as $$
begin
  if NEW.stato = 'attivo' and (OLD is null or OLD.stato <> 'attivo') then
    insert into listino_prezzi (laboratorio_id, studio_id, tipo_macro, tipo_micro, prezzo)
    select laboratorio_id, NEW.studio_id, tipo_macro, tipo_micro, prezzo
    from listino_base where laboratorio_id = NEW.laboratorio_id
    on conflict (laboratorio_id, studio_id, tipo_macro, tipo_micro) do nothing;
  end if;
  return NEW;
end;
$$ language plpgsql;

create trigger trg_copia_listino_base
  after insert or update on collegamenti
  for each row execute function copia_listino_base();

-- ============================================================
-- 9. LAVORAZIONI (PRACTICE) — entità centrale
-- ============================================================
create type stato_lab as enum ('', 'in_lavorazione', 'in_ritardo', 'da_rifare', 'in_consegna');
create type stato_studio as enum ('consegnato', 'problematico');
create type consegna_stato as enum ('in_attesa', 'accettata', 'riprogrammata');

create table lavorazioni (
  id text primary key,                 -- es. TSM-2026-0001
  studio_id uuid not null references studi(id),
  laboratorio_id uuid not null references laboratori(id),
  medico_id uuid not null references medici(id),
  paziente_id uuid references pazienti(id),
  cognome_paziente text not null,
  nome_paziente text not null,
  tipo_macro text not null,
  tipo_micro text not null,
  colore text not null,
  note text,

  data_consegna_richiesta date not null,
  consegna_stato consegna_stato not null default 'in_attesa',
  data_consegna_confermata date,
  riprogrammazione_vista boolean not null default true,
  motivo_riprogrammazione text,

  stato_lab stato_lab not null default '',
  data_in_consegna date,
  odontotecnico text,

  stato_studio stato_studio,
  data_chiusura date,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_lavorazioni_studio on lavorazioni(studio_id);
create index idx_lavorazioni_laboratorio on lavorazioni(laboratorio_id);
create index idx_lavorazioni_medico on lavorazioni(medico_id);
create index idx_lavorazioni_paziente on lavorazioni(paziente_id);
create index idx_lavorazioni_stato on lavorazioni(stato_lab);

-- ============================================================
-- 10. MATERIALI PER LAVORAZIONE (multipli per pratica)
-- ============================================================
create table materiali_lavorazione (
  id uuid primary key default uuid_generate_v4(),
  lavorazione_id text not null references lavorazioni(id) on delete cascade,
  materiale text not null,
  lotto text not null,
  created_at timestamptz not null default now()
);

create index idx_materiali_lavorazione on materiali_lavorazione(lavorazione_id);

-- ============================================================
-- 11. ALLEGATI (rimossi dallo storage al primo download, riferimento conservato)
-- ============================================================
create table allegati (
  id uuid primary key default uuid_generate_v4(),
  lavorazione_id text not null references lavorazioni(id) on delete cascade,
  nome_file text not null,
  storage_path text,          -- null dopo il primo download
  scaricato_il date,
  caricato_da uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- ============================================================
-- 12. SEGNALAZIONI
-- ============================================================
create table segnalazioni (
  id uuid primary key default uuid_generate_v4(),
  lavorazione_id text not null references lavorazioni(id) on delete cascade,
  tipo text not null,
  dettaglio text not null,
  created_at timestamptz not null default now()
);

-- ============================================================
-- 13. FIRME (Prescrizione, firma elettronica semplice)
-- ============================================================
create table firme (
  id uuid primary key default uuid_generate_v4(),
  lavorazione_id text not null references lavorazioni(id) on delete cascade,
  firmatario_id uuid not null references auth.users(id),
  firmatario_nome text not null,
  ruolo text not null,
  documento text not null default 'Prescrizione',
  hash text not null,
  firmato_at timestamptz not null default now()
);

-- Una pratica è "archiviata" quando consegnata E firmata
create view lavorazioni_archiviate as
  select l.* from lavorazioni l
  where l.stato_studio = 'consegnato'
    and exists (select 1 from firme f where f.lavorazione_id = l.id);

-- ============================================================
-- 14. CHAT — canale generale studio + canale diretto medico, isolati per laboratorio
-- ============================================================
create type canale_tipo as enum ('studio', 'medico');

create table canali_chat (
  id uuid primary key default uuid_generate_v4(),
  tipo canale_tipo not null,
  laboratorio_id uuid not null references laboratori(id),
  studio_id uuid references studi(id),
  medico_id uuid references medici(id),
  unique(tipo, laboratorio_id, studio_id, medico_id)
);

create table messaggi (
  id uuid primary key default uuid_generate_v4(),
  canale_id uuid not null references canali_chat(id) on delete cascade,
  mittente_id uuid not null references auth.users(id),
  mittente_ruolo ruolo_utente not null,
  testo text not null,
  letto_da_lab boolean not null default false,
  letto_da_controparte boolean not null default false,
  created_at timestamptz not null default now()
);

create index idx_messaggi_canale on messaggi(canale_id, created_at);

-- ============================================================
-- 15. AUDIT LOG
-- ============================================================
create table audit_log (
  id uuid primary key default uuid_generate_v4(),
  utente_id uuid references auth.users(id),
  lavorazione_id text references lavorazioni(id),
  azione text not null,
  campo text,
  valore_precedente text,
  valore_nuovo text,
  created_at timestamptz not null default now()
);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table lavorazioni enable row level security;
alter table materiali_lavorazione enable row level security;
alter table allegati enable row level security;
alter table segnalazioni enable row level security;
alter table firme enable row level security;
alter table listino_prezzi enable row level security;
alter table listino_base enable row level security;
alter table messaggi enable row level security;
alter table canali_chat enable row level security;
alter table medici enable row level security;
alter table pazienti enable row level security;
alter table studi enable row level security;
alter table laboratori enable row level security;
alter table collegamenti enable row level security;

create or replace function mio_ruolo() returns ruolo_utente as $$
  select ruolo from profili where id = auth.uid();
$$ language sql stable security definer;

create or replace function mio_laboratorio_id() returns uuid as $$
  select laboratorio_id from profili where id = auth.uid();
$$ language sql stable security definer;

create or replace function mio_studio_id() returns uuid as $$
  select studio_id from profili where id = auth.uid();
$$ language sql stable security definer;

create or replace function mio_medico_id() returns uuid as $$
  select medico_id from profili where id = auth.uid();
$$ language sql stable security definer;

-- COLLEGAMENTI: visibili alle due parti coinvolte + Admin
create policy collegamenti_select on collegamenti for select using (
  mio_ruolo() = 'ADMIN'
  or (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id())
  or (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id())
);
create policy collegamenti_write on collegamenti for insert with check (mio_ruolo() in ('LABORATORIO','STUDIO'));
create policy collegamenti_update on collegamenti for update using (
  (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id())
  or (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id())
);

-- STUDI: Admin vede tutti; laboratorio vede i propri collegati; studio/medico vedono il proprio
create policy studi_select on studi for select using (
  mio_ruolo() = 'ADMIN'
  or mio_ruolo() = 'LABORATORIO'
  or (mio_ruolo() = 'STUDIO' and id = mio_studio_id())
  or (mio_ruolo() = 'MEDICO' and id = (select studio_id from medici where id = mio_medico_id()))
);
create policy studi_write on studi for insert with check (mio_ruolo() in ('ADMIN','LABORATORIO'));
create policy studi_update on studi for update using (mio_ruolo() = 'ADMIN');

-- LABORATORI: Admin vede tutti; qualsiasi studio può cercarli per proporre un collegamento; laboratorio vede sé stesso
create policy laboratori_select on laboratori for select using (
  mio_ruolo() = 'ADMIN'
  or id = mio_laboratorio_id()
  or mio_ruolo() = 'STUDIO'
);
create policy laboratori_write on laboratori for all using (mio_ruolo() = 'ADMIN');

-- MEDICI
create policy medici_select on medici for select using (
  mio_ruolo() = 'ADMIN'
  or (mio_ruolo() = 'LABORATORIO' and studio_id in (select studio_id from collegamenti where laboratorio_id = mio_laboratorio_id() and stato = 'attivo'))
  or (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id())
  or (mio_ruolo() = 'MEDICO' and id = mio_medico_id())
);
create policy medici_write on medici for insert with check (mio_ruolo() = 'STUDIO');
create policy medici_update on medici for update using (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id());

-- PAZIENTI: solo lo studio proprietario
create policy pazienti_solo_studio on pazienti for all using (
  mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id()
);

-- LAVORAZIONI
create policy lavorazioni_select on lavorazioni for select using (
  mio_ruolo() = 'ADMIN'
  or (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id())
  or (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id())
  or (mio_ruolo() = 'MEDICO' and medico_id = mio_medico_id())
);
create policy lavorazioni_insert on lavorazioni for insert with check (mio_ruolo() in ('STUDIO','LABORATORIO'));
create policy lavorazioni_update on lavorazioni for update using (
  (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id())
  or (mio_ruolo() = 'STUDIO' and studio_id = mio_studio_id())
);

-- MATERIALI/ALLEGATI/SEGNALAZIONI/FIRME: seguono la lavorazione collegata
create policy materiali_via_lavorazione on materiali_lavorazione for all using (
  exists (select 1 from lavorazioni l where l.id = lavorazione_id
    and (mio_ruolo()='ADMIN'
      or (mio_ruolo()='LABORATORIO' and l.laboratorio_id = mio_laboratorio_id())
      or (mio_ruolo()='STUDIO' and l.studio_id = mio_studio_id())
      or (mio_ruolo()='MEDICO' and l.medico_id = mio_medico_id())))
);

-- LISTINO: mai visibile a studio/medico
create policy listino_solo_lab on listino_prezzi for all using (
  mio_ruolo() in ('ADMIN','LABORATORIO') and laboratorio_id = mio_laboratorio_id()
);
create policy listino_base_solo_lab on listino_base for all using (
  mio_ruolo() in ('ADMIN','LABORATORIO') and laboratorio_id = mio_laboratorio_id()
);

-- ============================================================
-- POLICY AGGIUNTE DURANTE LO SVILUPPO (consolidate qui per tenere
-- il file allineato al database reale — erano state eseguite come
-- query separate nel tempo)
-- ============================================================

-- IMPOSTAZIONI (tipi lavoro, colori, materiali, odontotecnici, tipi problema, dati fabbricante)
alter table tipi_lavoro_macro enable row level security;
alter table tipi_lavoro_micro enable row level security;
alter table colori enable row level security;
alter table materiali_catalogo enable row level security;
alter table odontotecnici enable row level security;
alter table tipi_problema enable row level security;
alter table dati_fabbricante enable row level security;

create policy tlm_select on tipi_lavoro_macro for select using (auth.role() = 'authenticated');
create policy tlm_write on tipi_lavoro_macro for all using (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id());

create policy tlmi_select on tipi_lavoro_micro for select using (auth.role() = 'authenticated');
create policy tlmi_write on tipi_lavoro_micro for all using (
  exists (select 1 from tipi_lavoro_macro m where m.id = macro_id and m.laboratorio_id = mio_laboratorio_id())
);

create policy colori_select on colori for select using (auth.role() = 'authenticated');
create policy colori_write on colori for all using (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id());

create policy materiali_cat_select on materiali_catalogo for select using (auth.role() = 'authenticated');
create policy materiali_cat_write on materiali_catalogo for all using (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id());

create policy odt_select on odontotecnici for select using (auth.role() = 'authenticated');
create policy odt_write on odontotecnici for all using (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id());

create policy tp_select on tipi_problema for select using (auth.role() = 'authenticated');
create policy tp_write on tipi_problema for all using (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id());

create policy df_select on dati_fabbricante for select using (auth.role() = 'authenticated');
create policy df_write on dati_fabbricante for all using (mio_ruolo() = 'LABORATORIO' and laboratorio_id = mio_laboratorio_id());

-- SEGNALAZIONI
create policy segnalazioni_via_lavorazione on segnalazioni for all using (
  exists (select 1 from lavorazioni l where l.id = lavorazione_id
    and (mio_ruolo()='ADMIN'
      or (mio_ruolo()='LABORATORIO' and l.laboratorio_id = mio_laboratorio_id())
      or (mio_ruolo()='STUDIO' and l.studio_id = mio_studio_id())))
);

-- FIRME
create policy firme_select on firme for select using (
  exists (select 1 from lavorazioni l where l.id = lavorazione_id
    and (mio_ruolo()='ADMIN'
      or (mio_ruolo()='LABORATORIO' and l.laboratorio_id = mio_laboratorio_id())
      or (mio_ruolo()='STUDIO' and l.studio_id = mio_studio_id())
      or (mio_ruolo()='MEDICO' and l.medico_id = mio_medico_id())))
);
create policy firme_insert on firme for insert with check (
  mio_ruolo() = 'MEDICO' and firmatario_id = auth.uid()
  and exists (select 1 from lavorazioni l where l.id = lavorazione_id and l.medico_id = mio_medico_id())
);

-- CHAT (canali + messaggi)
create policy canali_select on canali_chat for select using (
  mio_ruolo()='ADMIN'
  or (mio_ruolo()='LABORATORIO' and laboratorio_id = mio_laboratorio_id())
  or (mio_ruolo()='STUDIO' and studio_id = mio_studio_id())
  or (mio_ruolo()='MEDICO' and medico_id = mio_medico_id())
);
create policy canali_insert on canali_chat for insert with check (
  mio_ruolo() in ('LABORATORIO','STUDIO','MEDICO')
);

create policy messaggi_select on messaggi for select using (
  exists (select 1 from canali_chat c where c.id = canale_id
    and (mio_ruolo()='ADMIN'
      or (mio_ruolo()='LABORATORIO' and c.laboratorio_id = mio_laboratorio_id())
      or (mio_ruolo()='STUDIO' and c.studio_id = mio_studio_id())
      or (mio_ruolo()='MEDICO' and c.medico_id = mio_medico_id())))
);
create policy messaggi_insert on messaggi for insert with check (
  mittente_id = auth.uid()
  and exists (select 1 from canali_chat c where c.id = canale_id
    and ((mio_ruolo()='LABORATORIO' and c.laboratorio_id = mio_laboratorio_id())
      or (mio_ruolo()='STUDIO' and c.studio_id = mio_studio_id())
      or (mio_ruolo()='MEDICO' and c.medico_id = mio_medico_id())))
);
create policy messaggi_update on messaggi for update using (
  exists (select 1 from canali_chat c where c.id = canale_id
    and (mio_ruolo()='ADMIN'
      or (mio_ruolo()='LABORATORIO' and c.laboratorio_id = mio_laboratorio_id())
      or (mio_ruolo()='STUDIO' and c.studio_id = mio_studio_id())
      or (mio_ruolo()='MEDICO' and c.medico_id = mio_medico_id())))
);

-- PROFILI (necessaria per il login: ogni utente deve poter leggere/creare la propria riga)
alter table profili enable row level security;
create policy profili_select_own on profili for select using (id = auth.uid());
create policy profili_insert_self on profili for insert with check (id = auth.uid());

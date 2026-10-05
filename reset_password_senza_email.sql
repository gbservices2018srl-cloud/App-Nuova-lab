-- Recupero password SENZA email: l'utente invia una richiesta, l'Admin imposta una password temporanea,
-- al primo accesso l'utente è obbligato a sceglierne una nuova.

alter table profili add column if not exists deve_cambiare_password boolean not null default false;

create table if not exists richieste_reset (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  created_at timestamptz not null default now(),
  evasa boolean not null default false
);
alter table richieste_reset enable row level security;

drop policy if exists richieste_reset_admin on richieste_reset;
create policy richieste_reset_admin on richieste_reset for all
  using (mio_ruolo() = 'ADMIN') with check (mio_ruolo() = 'ADMIN');

-- Chiunque (anche non loggato) può inviare una richiesta, ma solo tramite questa funzione (non rivela se l'email esiste)
create or replace function richiedi_reset_password(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(p_email));
begin
  if e is null or length(e) < 5 or length(e) > 200 or position('@' in e) = 0 then return; end if;
  if exists (select 1 from auth.users where lower(email) = e)
     and not exists (select 1 from richieste_reset where lower(email) = e and not evasa) then
    insert into richieste_reset(email) values (e);
  end if;
end $$;
revoke all on function richiedi_reset_password(text) from public;
grant execute on function richiedi_reset_password(text) to anon, authenticated;

-- L'Admin, dopo aver impostato la password temporanea, obbliga il cambio al primo accesso e chiude la richiesta
create or replace function admin_segna_reset(p_email text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if mio_ruolo() <> 'ADMIN' then raise exception 'Non autorizzato'; end if;
  update profili set deve_cambiare_password = true
    where id in (select id from auth.users where lower(email) = lower(trim(p_email)));
  update richieste_reset set evasa = true where lower(email) = lower(trim(p_email));
end $$;
revoke all on function admin_segna_reset(text) from public;
grant execute on function admin_segna_reset(text) to authenticated;

-- L'utente conferma di aver cambiato la password
create or replace function password_cambiata() returns void
language sql security definer set search_path = public as $$
  update profili set deve_cambiare_password = false where id = auth.uid();
$$;
revoke all on function password_cambiata() from public;
grant execute on function password_cambiata() to authenticated;

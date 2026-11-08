-- Medici che NON lavorano con un certo laboratorio (di base tutti i medici di uno studio collegato lavorano con quel laboratorio).
create table if not exists medici_esclusi (
  laboratorio_id uuid not null references laboratori(id),
  medico_id uuid not null references medici(id),
  creato timestamptz not null default now(),
  primary key (laboratorio_id, medico_id)
);
alter table medici_esclusi enable row level security;
create policy medici_esclusi_select on medici_esclusi for select using (auth.role() = 'authenticated' and lab_del_mio_gruppo(laboratorio_id));
create policy medici_esclusi_write on medici_esclusi for all
  using (mio_ruolo() = 'ADMIN' or (mio_ruolo() = 'LABORATORIO' and mio_cliente_id() is not null and laboratorio_id = mio_laboratorio_id()))
  with check (mio_ruolo() = 'ADMIN' or (mio_ruolo() = 'LABORATORIO' and mio_cliente_id() is not null and laboratorio_id = mio_laboratorio_id()));

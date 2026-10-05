-- Già applicato al database: elenco utenti per l'Admin senza passare dalla Edge Function
create or replace function admin_elenco_utenti()
returns table(email text, ruolo text, entita text, attivo boolean)
language plpgsql security definer set search_path = public as $$
begin
  if mio_ruolo() <> 'ADMIN' then raise exception 'Non autorizzato'; end if;
  return query
    select u.email::text, p.ruolo::text, coalesce(l.nome, s.nome, m.nome, '—')::text, p.attivo
    from profili p join auth.users u on u.id = p.id
    left join laboratori l on l.id = p.laboratorio_id
    left join studi s on s.id = p.studio_id
    left join medici m on m.id = p.medico_id
    order by p.ruolo::text, u.email;
end $$;
revoke all on function admin_elenco_utenti() from public;
grant execute on function admin_elenco_utenti() to authenticated;

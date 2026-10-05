-- Già applicato al database: le richieste di reset vengono registrate sempre (anche se l'email non è registrata)
alter table richieste_reset add column if not exists registrata boolean not null default true;
create or replace function richiedi_reset_password(p_email text) returns void
language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(p_email));
begin
  if e is null or length(e) < 5 or length(e) > 200 or position('@' in e) = 0 then return; end if;
  if not exists (select 1 from richieste_reset where lower(email) = e and not evasa) then
    insert into richieste_reset(email, registrata)
    values (e, exists (select 1 from auth.users where lower(email) = e));
  end if;
end $$;
revoke all on function richiedi_reset_password(text) from public;
grant execute on function richiedi_reset_password(text) to anon, authenticated;

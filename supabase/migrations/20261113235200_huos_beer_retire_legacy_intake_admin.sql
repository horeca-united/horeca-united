-- HUOS 2.0 — stap 5: oude beheertoegang via huos_beer_intake_admins afsluiten (akkoord eigenaar 14-11-2026).
-- Toegang tot inzendingen loopt voortaan uitsluitend via huos_staff (policy huos_beer_intake_staff_select).
-- Rollback:
--   insert into public.huos_beer_intake_admins (user_id, created_at) values ('97bbe279-9346-4a0c-94e8-44969da58124','2026-11-11 21:44:21.603109+00');
--   create policy huos_beer_intake_admin_select ... / huos_beer_intake_admin_update ... (zie definitie in 20261111 migraties)
drop policy huos_beer_intake_admin_select on public.huos_beer_intake_submissions;
drop policy huos_beer_intake_admin_update on public.huos_beer_intake_submissions;
delete from public.huos_beer_intake_admins where user_id = '97bbe279-9346-4a0c-94e8-44969da58124';
comment on table public.huos_beer_intake_admins is 'NIET MEER IN GEBRUIK sinds 14-11-2026 — interne rollen staan in huos_staff. Verwijderen alleen na apart akkoord.';

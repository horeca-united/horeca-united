-- HUOS 2.0 — bedrijfsprofiel uitbreiden (additief, alle velden optioneel). Toegepast 14-11-2026.
-- Rollback: alter table public.huos_pilot_organizations drop column kvk_number, drop column contact_role,
--   drop column location_count, drop column seats, drop column open_days_per_week, drop column profile_updated_at;
--   grant truncate, references, trigger on public.huos_pilot_organizations, public.huos_pilot_documents,
--   public.huos_pilot_entries, public.huos_pilot_beer_scans to authenticated;
alter table public.huos_pilot_organizations
  add column kvk_number text check (kvk_number is null or kvk_number ~ '^[0-9]{8}$'),
  add column contact_role text check (contact_role is null or contact_role in ('owner','manager','administration','other')),
  add column location_count smallint check (location_count is null or location_count between 1 and 500),
  add column seats smallint check (seats is null or seats between 0 and 5000),
  add column open_days_per_week smallint check (open_days_per_week is null or open_days_per_week between 0 and 7),
  add column profile_updated_at timestamptz;
comment on column public.huos_pilot_organizations.kvk_number is 'KvK-nummer (8 cijfers), door de ondernemer zelf opgegeven; nog niet geverifieerd.';
comment on column public.huos_pilot_organizations.contact_role is 'Rol van de ingelogde contactpersoon: owner, manager, administration, other.';
revoke truncate, references, trigger on public.huos_pilot_organizations, public.huos_pilot_documents,
  public.huos_pilot_entries, public.huos_pilot_beer_scans from authenticated;

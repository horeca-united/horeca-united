-- Bier Quick Scan (in de app): één knop "Scan afronden", verplichte velden, melding voor Horeca United.
--
-- Wat verandert:
--  * huos_pilot_beer_scan_versions: elke afgeronde versie wordt vastgelegd (append-only).
--  * huos_pilot_beer_scan_alerts: één openstaande melding per klant; alleen te wijzigen via RPC.
--  * huos_my_beer_scan_complete(answers): controleert verplichte velden, slaat op als 'completed',
--    legt een nieuwe versie vast en zet een melding alleen als de antwoorden echt gewijzigd zijn.
--  * huos_beer_scan_seen(org): medewerker markeert de melding als gezien (gelogd in de melding zelf).
--  * Medewerkers met toegang tot de klant kunnen versies en meldingen lezen; klanten niet.
-- Geen wijziging aan huos_pilot_beer_scans zelf of aan de bestaande policies.
--
-- Rollback: drop function huos_my_beer_scan_complete(jsonb), huos_beer_scan_seen(uuid);
--           drop table huos_pilot_beer_scan_alerts, huos_pilot_beer_scan_versions.

create table public.huos_pilot_beer_scan_versions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  answers jsonb not null check (jsonb_typeof(answers) = 'object' and pg_column_size(answers) < 12000),
  completed_by uuid references auth.users(id) on delete set null,
  completed_at timestamptz not null default now()
);
create index huos_pilot_beer_scan_versions_org_idx on public.huos_pilot_beer_scan_versions (organization_id, completed_at desc);
alter table public.huos_pilot_beer_scan_versions enable row level security;
revoke all on public.huos_pilot_beer_scan_versions from anon, authenticated;
grant select on public.huos_pilot_beer_scan_versions to authenticated;
create policy huos_beer_scan_versions_staff_read on public.huos_pilot_beer_scan_versions for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create trigger huos_pilot_beer_scan_versions_append_only before update or delete on public.huos_pilot_beer_scan_versions
  for each row execute function public.huos_cost_audit_guard();

create table public.huos_pilot_beer_scan_alerts (
  organization_id uuid primary key references public.huos_pilot_organizations(id) on delete cascade,
  pending boolean not null default true,
  version_id uuid not null references public.huos_pilot_beer_scan_versions(id),
  changed_at timestamptz not null default now(),
  seen_by uuid references auth.users(id) on delete set null,
  seen_at timestamptz
);
alter table public.huos_pilot_beer_scan_alerts enable row level security;
revoke all on public.huos_pilot_beer_scan_alerts from anon, authenticated;
grant select on public.huos_pilot_beer_scan_alerts to authenticated;
create policy huos_beer_scan_alerts_staff_read on public.huos_pilot_beer_scan_alerts for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));

create or replace function public.huos_my_beer_scan_complete(p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); a jsonb := '{}'; k text; v text; v_last jsonb; v_ver uuid; n numeric;
  keys text[] := array['brewery_supplier','brewery_supplier_other','tap_beer_brand','tap_beer_brand_other','distributor','distributor_other',
    'keg_size_l','keg_size_l_other','keg_price_ex_vat','annual_volume_hl','annual_volume_source','bonus_status','contract_end_status',
    'contract_end_date','purchase_obligation','installation_status','brewery_loan_status','proposal_interest','willingness_to_switch','data_route'];
  req text[] := array['brewery_supplier','tap_beer_brand','distributor','keg_size_l','annual_volume_source','bonus_status','contract_end_status',
    'purchase_obligation','installation_status','brewery_loan_status','proposal_interest','willingness_to_switch','data_route'];
begin
  if v_org is null then raise exception 'Maak eerst jouw bedrijfsprofiel aan'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then raise exception 'Ongeldige antwoorden'; end if;
  -- alleen bekende velden, tekst ingekort
  foreach k in array keys loop
    v := nullif(btrim(coalesce(p_answers->>k, '')), '');
    if v is not null then
      if k in ('keg_price_ex_vat','annual_volume_hl') then
        begin n := v::numeric; exception when others then raise exception 'Controleer het getal bij %', k; end;
        if n < 0 or n > (case when k = 'keg_price_ex_vat' then 5000 else 100000 end) then raise exception 'Controleer het getal bij %', k; end if;
        a := a || jsonb_build_object(k, n);
      else
        a := a || jsonb_build_object(k, left(v, 160));
      end if;
    end if;
  end loop;
  foreach k in array req loop
    if not a ? k then raise exception 'VERPLICHT:%', k; end if;
  end loop;
  if a->>'brewery_supplier' = 'other' and not a ? 'brewery_supplier_other' then raise exception 'VERPLICHT:brewery_supplier_other'; end if;
  if a->>'tap_beer_brand' = 'other' and not a ? 'tap_beer_brand_other' then raise exception 'VERPLICHT:tap_beer_brand_other'; end if;
  if a->>'distributor' = 'other' and not a ? 'distributor_other' then raise exception 'VERPLICHT:distributor_other'; end if;
  if a->>'keg_size_l' = 'other' and not a ? 'keg_size_l_other' then raise exception 'VERPLICHT:keg_size_l_other'; end if;
  if a->>'contract_end_status' = 'date_known' and not a ? 'contract_end_date' then raise exception 'VERPLICHT:contract_end_date'; end if;

  insert into public.huos_pilot_beer_scans (organization_id, owner_id, answers, status, updated_at)
  values (v_org, (select auth.uid()), a, 'completed', now())
  on conflict (organization_id) do update set answers = excluded.answers, status = 'completed', updated_at = now();

  select answers into v_last from public.huos_pilot_beer_scan_versions where organization_id = v_org order by completed_at desc limit 1;
  if v_last is not null and v_last = a then return jsonb_build_object('changed', false); end if;

  insert into public.huos_pilot_beer_scan_versions (organization_id, answers, completed_by) values (v_org, a, (select auth.uid()))
  returning id into v_ver;
  insert into public.huos_pilot_beer_scan_alerts (organization_id, pending, version_id, changed_at, seen_by, seen_at)
  values (v_org, true, v_ver, now(), null, null)
  on conflict (organization_id) do update set pending = true, version_id = excluded.version_id, changed_at = now(), seen_by = null, seen_at = null;
  return jsonb_build_object('changed', true);
end $$;

create or replace function public.huos_beer_scan_seen(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.huos_staff_has('reviewer') or not public.huos_staff_can_access_org(p_org) then raise exception 'Niet bevoegd'; end if;
  update public.huos_pilot_beer_scan_alerts set pending = false, seen_by = (select auth.uid()), seen_at = now()
  where organization_id = p_org and pending;
end $$;

revoke all on function public.huos_my_beer_scan_complete(jsonb) from public, anon;
revoke all on function public.huos_beer_scan_seen(uuid) from public, anon;
grant execute on function public.huos_my_beer_scan_complete(jsonb) to authenticated;
grant execute on function public.huos_beer_scan_seen(uuid) to authenticated;

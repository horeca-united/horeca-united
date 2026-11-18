-- Bier Quick Scan: vraag 5 (prijs per fust) en 6 (jaarafname) verplicht, met 'Weet ik niet' (opgeslagen als 'unknown').
-- Alleen de functie huos_my_beer_scan_complete wordt vervangen; geen tabel- of datawijziging.
-- Rollback: functie uit 20261118050000_huos_beer_scan_complete.sql opnieuw uitvoeren.

create or replace function public.huos_my_beer_scan_complete(p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); a jsonb := '{}'; k text; v text; v_last jsonb; v_ver uuid; n numeric;
  keys text[] := array['brewery_supplier','brewery_supplier_other','tap_beer_brand','tap_beer_brand_other','distributor','distributor_other',
    'keg_size_l','keg_size_l_other','keg_price_ex_vat','annual_volume_hl','annual_volume_source','bonus_status','contract_end_status',
    'contract_end_date','purchase_obligation','installation_status','brewery_loan_status','proposal_interest','willingness_to_switch','data_route'];
  req text[] := array['brewery_supplier','tap_beer_brand','distributor','keg_size_l','keg_price_ex_vat','annual_volume_hl','annual_volume_source','bonus_status','contract_end_status',
    'purchase_obligation','installation_status','brewery_loan_status','proposal_interest','willingness_to_switch','data_route'];
begin
  if v_org is null then raise exception 'Maak eerst jouw bedrijfsprofiel aan'; end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then raise exception 'Ongeldige antwoorden'; end if;
  -- alleen bekende velden, tekst ingekort
  foreach k in array keys loop
    v := nullif(btrim(coalesce(p_answers->>k, '')), '');
    if v is not null then
      if k in ('keg_price_ex_vat','annual_volume_hl') and lower(v) = 'unknown' then
        a := a || jsonb_build_object(k, 'unknown');
      elsif k in ('keg_price_ex_vat','annual_volume_hl') then
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

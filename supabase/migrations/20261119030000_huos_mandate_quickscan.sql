-- HUOS — machtiging (v3) direct afronden aan het eind van de Bier Quick Scan.
-- 1. huos_beer_ensure_lead: bij een v3-machtiging uit de scan geen automatische leveranciers meer
--    (die kiest de ondernemer zelf); oudere versies werken zoals voorheen.
-- 2. huos_intake_mandate_public_config(): tekst + boekjaaropties voor de openbare scan (alleen service_role).
-- 3. huos_intake_mandate_sign_v3(...): legt de ondertekening uit de openbare scan vast (alleen service_role).
-- 4. huos_my_mandate_enable_from_scan(): zet de machtiging aan voor de eigen organisatie wanneer de
--    klant in de scan voor machtiging kiest.
-- Geen tabellen of kolommen gewijzigd of verwijderd.

create or replace function public.huos_beer_ensure_lead(p_submission uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_lead uuid; v_sub record; v_mand uuid;
begin
 select id into v_lead from public.huos_beer_leads where submission_id = p_submission;
 if v_lead is not null then return v_lead; end if;
 select id, data_route, mandate_consent_version, mandate_consent_at, mandate_authority_asserted
 into v_sub from public.huos_beer_intake_submissions where id = p_submission;
 if not found then raise exception 'Onbekende inzending'; end if;
 insert into public.huos_beer_leads (submission_id, stage)
 values (p_submission, case when v_sub.data_route = 'mandate' then 'mandate_pending' else 'new' end)
 on conflict (submission_id) do nothing
 returning id into v_lead;
 if v_lead is null then
 select id into v_lead from public.huos_beer_leads where submission_id = p_submission;
 return v_lead;
 end if;
 if v_sub.data_route = 'mandate' then
 insert into public.huos_beer_mandates (lead_id, consent_text_version, consent_at, authority_asserted)
 values (v_lead, v_sub.mandate_consent_version, v_sub.mandate_consent_at, v_sub.mandate_authority_asserted)
 returning id into v_mand;
 -- v3: leveranciers worden door de ondernemer gekozen bij het ondertekenen
 if coalesce(v_sub.mandate_consent_version, '') not like 'huos-mandate-v3%' then
 perform public.huos_mandate_suppliers_from_beer(v_mand);
 end if;
 end if;
 perform public.huos_beer_log(v_lead, 'lead_created', 'submission', p_submission::text,
 jsonb_build_object('data_route', v_sub.data_route));
 return v_lead;
end $function$;

create or replace function public.huos_intake_mandate_public_config()
 returns jsonb
 language sql
 stable
 security definer
 set search_path to ''
as $function$
  select jsonb_build_object(
    'text', (select jsonb_build_object('version', version, 'title', title, 'body', body)
             from public.huos_mandate_texts where version like 'huos-mandate-v3%' order by created_at desc limit 1),
    'fiscal', (select jsonb_object_agg(m::text, public.huos_fiscal_period_options(m::smallint, current_date))
               from generate_series(1, 12) m));
$function$;
revoke all on function public.huos_intake_mandate_public_config() from public, anon, authenticated;
grant execute on function public.huos_intake_mandate_public_config() to service_role;

create or replace function public.huos_intake_mandate_sign_v3(
  p_submission uuid, p_kvk text, p_function text, p_fiscal_month int, p_period_choice text, p_suppliers jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare s record; v_lead uuid; m record; t record; opts jsonb; per jsonb := '[]'; sups jsonb := '[]'; x jsonb;
  v_kvk text := regexp_replace(coalesce(p_kvk, ''), '\s', '', 'g'); v_role text; v_txt text;
begin
  select * into s from public.huos_beer_intake_submissions where id = p_submission;
  if s.id is null or s.data_route <> 'mandate' then raise exception 'Geen machtiging bij deze aanvraag'; end if;
  select id into v_lead from public.huos_beer_leads where submission_id = p_submission;
  select * into m from public.huos_beer_mandates where lead_id = v_lead;
  if m.id is null then raise exception 'Machtiging niet gevonden'; end if;
  if exists (select 1 from public.huos_mandate_signatures where mandate_id = m.id) then
    raise exception 'Deze machtiging is al ondertekend'; end if;
  select * into t from public.huos_mandate_texts where version like 'huos-mandate-v3%' order by created_at desc limit 1;
  if t.version is null or m.consent_text_version is distinct from t.version then
    raise exception 'De machtigingstekst is gewijzigd. Vernieuw de pagina.'; end if;
  if v_kvk !~ '^\d{8}$' then raise exception 'Vul een geldig KvK-nummer in (8 cijfers)'; end if;
  if length(btrim(coalesce(p_function, ''))) not between 2 and 80 then raise exception 'Vul je functie in'; end if;
  if length(btrim(coalesce(s.contact_name, ''))) < 2 then raise exception 'Vul je naam in'; end if;
  if p_fiscal_month is null or p_fiscal_month not between 1 and 12 then raise exception 'Kies de maand waarin je boekjaar begint'; end if;
  if p_suppliers is null or jsonb_typeof(p_suppliers) <> 'array' or jsonb_array_length(p_suppliers) = 0
     or jsonb_array_length(p_suppliers) > 15 then raise exception 'Kies minstens één leverancier'; end if;
  for x in select * from jsonb_array_elements(p_suppliers) loop
    if length(btrim(coalesce(x->>'name', ''))) not between 2 and 120 then raise exception 'Ongeldige leverancier'; end if;
    v_role := coalesce(x->>'role', 'overig');
    if v_role not in ('brouwerij','drankleverancier','groothandel','vers','energie','verzekering','overig') then v_role := 'overig'; end if;
    if not exists (select 1 from jsonb_array_elements(sups) y where lower(y->>'name') = lower(btrim(x->>'name'))) then
      sups := sups || jsonb_build_array(jsonb_build_object('name', btrim(x->>'name'), 'role', v_role));
    end if;
  end loop;
  opts := public.huos_fiscal_period_options(p_fiscal_month::smallint, current_date);
  if p_period_choice = 'closed' then per := jsonb_build_array(opts->'closed');
  elsif p_period_choice = 'current' then per := jsonb_build_array(opts->'current');
  elsif p_period_choice = 'both' then per := jsonb_build_array(opts->'closed', opts->'current');
  else raise exception 'Kies een periode'; end if;

  update public.huos_beer_mandates
     set signer_name = btrim(s.contact_name), signer_function = btrim(p_function), kind = 'basis',
         valid_until = now() + interval '24 months', data_categories = array['volume','prices'], authority_asserted = true
   where id = m.id;
  insert into public.huos_mandate_periods (mandate_id, period_start, period_end, kind, label)
  select m.id, (pp->>'start')::date, (pp->>'end')::date, pp->>'kind', pp->>'label' from jsonb_array_elements(per) pp;
  insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, name_check, confirmed_via)
  select m.id, ss->>'name', ss->>'role', array['volume','prices'], 'bierscan', 'ok', 'bierscan' from jsonb_array_elements(sups) ss;
  v_txt := public.huos_mandate_render(t.body, s.company_name, v_kvk, sups, per);
  insert into public.huos_mandate_signatures (mandate_id, kind, signer_id, signer_name, signer_function, org_name, org_kvk,
     suppliers, periods, data_categories, text_version, text_rendered, text_sha256, method)
  values (m.id, 'initial', null, btrim(s.contact_name), btrim(p_function), s.company_name, v_kvk, sups, per,
     array['volume','prices'], t.version, v_txt, encode(sha256(convert_to(v_txt, 'UTF8')), 'hex'), 'huos_quickscan_checkbox');
  perform public.huos_mandate_log(m.id, 'mandate_signed', null,
    jsonb_build_object('signer', btrim(s.contact_name), 'function', btrim(p_function), 'version', t.version,
                       'suppliers', jsonb_array_length(sups), 'periods', per, 'kvk', v_kvk, 'via', 'quickscan'));
  return m.id;
end $function$;
revoke all on function public.huos_intake_mandate_sign_v3(uuid, text, text, int, text, jsonb) from public, anon, authenticated;
grant execute on function public.huos_intake_mandate_sign_v3(uuid, text, text, int, text, jsonb) to service_role;

create or replace function public.huos_my_mandate_enable_from_scan()
 returns boolean
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare v_org uuid := public.huos_my_org_id();
begin
  if v_org is null then raise exception 'Maak eerst je bedrijfsprofiel aan'; end if;
  insert into public.huos_org_features (organization_id, feature) values (v_org, 'mandate')
  on conflict do nothing;
  return true;
end $function$;
revoke all on function public.huos_my_mandate_enable_from_scan() from public, anon;
grant execute on function public.huos_my_mandate_enable_from_scan() to authenticated, service_role;

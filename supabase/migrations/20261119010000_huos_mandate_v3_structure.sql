-- Machtiging versie 3, stap 1: structuur (perioden, ondertekeningen, boekjaar, geldigheid).
--
-- Wat verandert (alles aanvullend, niets verwijderd):
--  * huos_pilot_organizations.fiscal_year_start_month (1–12, standaard 1 = kalenderjaar).
--  * huos_beer_mandates: kind (basis/aanvullend), valid_until, data_categories.
--  * huos_mandate_periods: exacte perioden per machtiging.
--  * huos_mandate_signatures: onveranderlijke ondertekeningen met momentopname en tekst-hash;
--    alleen pdf_document_id / pdf_sha256 mogen éénmalig worden ingevuld.
--  * huos_beer_mandate_requests: period_start, period_end, signature_id, needs_revoke_notice; status 'declined'.
--  * huos_pilot_documents: documentsoort 'mandate' (voor de PDF).
--  * Functies: huos_fiscal_period_options (voorstellen), huos_my_mandate_sign_v3, huos_my_mandate_supplier_add_v3;
--    huos_my_mandate, request_create/set en de intrekfuncties houden rekening met perioden, geldigheid en verstuurde verzoeken.
-- Rollback: nieuwe functies/tabellen droppen, kolommen droppen, checks en vorige functieversies terugzetten
--           (vorige versies staan in 20261118030000, 20261118040000).

alter table public.huos_pilot_organizations
  add column if not exists fiscal_year_start_month smallint not null default 1 check (fiscal_year_start_month between 1 and 12);

alter table public.huos_beer_mandates
  add column if not exists kind text not null default 'basis' check (kind in ('basis','aanvullend')),
  add column if not exists valid_until timestamptz,
  add column if not exists data_categories text[] check (data_categories is null or data_categories <@ array['volume','prices','discounts','bonuses','contract_terms']);

create table public.huos_mandate_periods (
  id uuid primary key default gen_random_uuid(),
  mandate_id uuid not null references public.huos_beer_mandates(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  kind text not null check (kind in ('closed','current','custom')),
  label text not null check (length(label) between 2 and 80),
  created_at timestamptz not null default now(),
  check (period_end >= period_start and period_end - period_start <= 731)
);
create index huos_mandate_periods_m_idx on public.huos_mandate_periods (mandate_id);
alter table public.huos_mandate_periods enable row level security;
revoke all on public.huos_mandate_periods from anon, authenticated;
grant select on public.huos_mandate_periods to authenticated;
create policy huos_mandate_periods_staff_read on public.huos_mandate_periods for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_mandate_can_access(mandate_id));
create trigger huos_mandate_periods_append_only before update or delete on public.huos_mandate_periods
  for each row execute function public.huos_cost_audit_guard();

create table public.huos_mandate_signatures (
  id uuid primary key default gen_random_uuid(),
  mandate_id uuid not null references public.huos_beer_mandates(id) on delete restrict,
  kind text not null check (kind in ('initial','addendum')),
  signer_id uuid references auth.users(id) on delete set null,
  signer_name text not null,
  signer_function text not null,
  org_name text not null,
  org_kvk text,
  suppliers jsonb not null check (jsonb_typeof(suppliers) = 'array'),
  periods jsonb not null check (jsonb_typeof(periods) = 'array'),
  data_categories text[] not null,
  text_version text not null references public.huos_mandate_texts(version),
  text_rendered text not null,
  text_sha256 text not null check (text_sha256 ~ '^[0-9a-f]{64}$'),
  method text not null default 'huos_account_checkbox',
  signed_at timestamptz not null default now(),
  pdf_document_id uuid references public.huos_pilot_documents(id) on delete restrict,
  pdf_sha256 text check (pdf_sha256 is null or pdf_sha256 ~ '^[0-9a-f]{64}$')
);
create index huos_mandate_signatures_m_idx on public.huos_mandate_signatures (mandate_id, signed_at);
alter table public.huos_mandate_signatures enable row level security;
revoke all on public.huos_mandate_signatures from anon, authenticated;
grant select on public.huos_mandate_signatures to authenticated;
create policy huos_mandate_signatures_staff_read on public.huos_mandate_signatures for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_mandate_can_access(mandate_id));

-- Onveranderlijk: alleen de PDF mag éénmalig worden gekoppeld
create or replace function public.huos_mandate_signature_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'Ondertekeningen kunnen niet worden verwijderd'; end if;
  if (to_jsonb(new) - 'pdf_document_id' - 'pdf_sha256') is distinct from (to_jsonb(old) - 'pdf_document_id' - 'pdf_sha256')
     or (old.pdf_document_id is not null and new.pdf_document_id is distinct from old.pdf_document_id)
     or (old.pdf_sha256 is not null and new.pdf_sha256 is distinct from old.pdf_sha256) then
    raise exception 'Een ondertekening kan niet worden gewijzigd';
  end if;
  return new;
end $$;
create trigger huos_mandate_signatures_guard before update or delete on public.huos_mandate_signatures
  for each row execute function public.huos_mandate_signature_guard();

alter table public.huos_beer_mandate_requests
  add column if not exists period_start date,
  add column if not exists period_end date,
  add column if not exists signature_id uuid references public.huos_mandate_signatures(id) on delete restrict,
  add column if not exists needs_revoke_notice boolean not null default false;
alter table public.huos_beer_mandate_requests drop constraint huos_beer_mandate_requests_status_check;
alter table public.huos_beer_mandate_requests add constraint huos_beer_mandate_requests_status_check
  check (status in ('draft','approved','sent','answered','declined','cancelled'));

alter table public.huos_pilot_documents drop constraint huos_pilot_documents_category_check;
alter table public.huos_pilot_documents add constraint huos_pilot_documents_category_check
  check (category in ('contract','invoice','overview','other','annual','mandate'));

-- Boekjaar-voorstellen voor een bedrijf (vandaag als referentie)
create or replace function public.huos_fiscal_period_options(p_start_month smallint, p_today date default current_date)
returns jsonb language plpgsql stable set search_path = '' as $$
declare m int := coalesce(p_start_month, 1); cs date; ls date; lab text;
begin
  cs := make_date(extract(year from p_today)::int, m, 1);
  if cs > p_today then cs := (cs - interval '1 year')::date; end if;
  ls := (cs - interval '1 year')::date;
  lab := case when m = 1 then extract(year from ls)::text
              else extract(year from ls)::text || '/' || right(extract(year from cs)::text, 2) end;
  return jsonb_build_object(
    'closed', jsonb_build_object('start', ls, 'end', (cs - 1), 'kind', 'closed', 'label', 'Boekjaar ' || lab),
    'current', jsonb_build_object('start', cs, 'end', ((cs + interval '1 year')::date - 1), 'kind', 'current',
      'label', 'Lopend boekjaar ' || case when m = 1 then extract(year from cs)::text
                                     else extract(year from cs)::text || '/' || right(extract(year from (cs + interval '1 year'))::text, 2) end));
end $$;
grant execute on function public.huos_fiscal_period_options(smallint, date) to authenticated;

-- Machtigingstekst invullen (bedrijf, leveranciers, perioden)
create or replace function public.huos_mandate_render(p_body text, p_org text, p_kvk text, p_suppliers jsonb, p_periods jsonb)
returns text language sql immutable set search_path = '' as $$
  select replace(replace(replace(replace(p_body,
    '{bedrijf}', p_org),
    '{kvk}', coalesce(p_kvk, 'onbekend')),
    '{leveranciers}', coalesce((select string_agg(x->>'name', ', ' order by x->>'name') from jsonb_array_elements(p_suppliers) x), '')),
    '{periode}', coalesce((select string_agg(
        case when x->>'kind' = 'current'
             then 'vanaf ' || to_char((x->>'start')::date, 'DD-MM-YYYY') || ' tot de datum van opvragen, uiterlijk ' || to_char((x->>'end')::date, 'DD-MM-YYYY')
             else to_char((x->>'start')::date, 'DD-MM-YYYY') || ' t/m ' || to_char((x->>'end')::date, 'DD-MM-YYYY') end,
        '; ' order by x->>'start') from jsonb_array_elements(p_periods) x), ''))
$$;
revoke all on function public.huos_mandate_render(text,text,text,jsonb,jsonb) from public, anon, authenticated;

-- Ondertekenen versie 3
create or replace function public.huos_my_mandate_sign_v3(p_name text, p_function text, p_authority boolean, p_version text,
  p_suppliers jsonb, p_period_choice text, p_custom jsonb default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); o record; t record; opts jsonb; per jsonb := '[]'; x jsonb; sups jsonb := '[]';
  v_id uuid; v_txt text; s date; e date;
begin
  if v_org is null or not exists (select 1 from public.huos_org_features where organization_id = v_org and feature = 'mandate') then
    raise exception 'Machtiging is (nog) niet beschikbaar voor jouw bedrijf'; end if;
  if coalesce(p_authority, false) is not true then raise exception 'Bevestig dat je bevoegd bent om namens het bedrijf te tekenen'; end if;
  if length(btrim(coalesce(p_name,''))) < 2 or length(btrim(coalesce(p_function,''))) < 2 then raise exception 'Vul je naam en functie in'; end if;
  select * into t from public.huos_mandate_texts where version = p_version and version like 'huos-mandate-v3%';
  if t.version is null or t.version <> (select version from public.huos_mandate_texts where version like 'huos-mandate-v3%' order by created_at desc limit 1) then
    raise exception 'De machtigingstekst is gewijzigd. Vernieuw de pagina.'; end if;
  if exists (select 1 from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified')) then
    raise exception 'Er is al een lopende machtiging'; end if;
  select * into o from public.huos_pilot_organizations where id = v_org;

  -- leveranciers
  if p_suppliers is null or jsonb_typeof(p_suppliers) <> 'array' or jsonb_array_length(p_suppliers) = 0 or jsonb_array_length(p_suppliers) > 40 then
    raise exception 'Kies minstens één leverancier'; end if;
  for x in select * from jsonb_array_elements(p_suppliers) loop
    if length(btrim(coalesce(x->>'name',''))) < 2 then raise exception 'Ongeldige leverancier'; end if;
    if not exists (select 1 from jsonb_array_elements(sups) y where lower(y->>'name') = lower(btrim(x->>'name'))) then
      sups := sups || jsonb_build_array(jsonb_build_object('name', btrim(x->>'name'), 'role', coalesce(x->>'role','overig')));
    end if;
  end loop;

  -- perioden (server berekent zelf de boekjaren)
  opts := public.huos_fiscal_period_options(o.fiscal_year_start_month, current_date);
  if p_period_choice = 'closed' then per := jsonb_build_array(opts->'closed');
  elsif p_period_choice = 'current' then per := jsonb_build_array(opts->'current');
  elsif p_period_choice = 'both' then per := jsonb_build_array(opts->'closed', opts->'current');
  elsif p_period_choice = 'custom' then
    if p_custom is null or jsonb_typeof(p_custom) <> 'array' or jsonb_array_length(p_custom) = 0 or jsonb_array_length(p_custom) > 4 then
      raise exception 'Kies een periode'; end if;
    for x in select * from jsonb_array_elements(p_custom) loop
      begin s := (x->>'start')::date; e := (x->>'end')::date; exception when others then raise exception 'Ongeldige datum'; end;
      if s is null or e is null or e < s then raise exception 'De einddatum ligt voor de begindatum'; end if;
      if e - s > 731 then raise exception 'Een periode mag maximaal twee jaar zijn'; end if;
      if s < (current_date - interval '3 years')::date then raise exception 'Een periode mag maximaal drie jaar terug beginnen'; end if;
      if e > (current_date + interval '1 year')::date then raise exception 'Een periode mag niet verder dan een jaar vooruit lopen'; end if;
      per := per || jsonb_build_array(jsonb_build_object('start', s, 'end', e, 'kind', 'custom',
        'label', to_char(s,'DD-MM-YYYY') || ' t/m ' || to_char(e,'DD-MM-YYYY')));
    end loop;
  else raise exception 'Kies een periode'; end if;

  insert into public.huos_beer_mandates (organization_id, consent_text_version, consent_at, authority_asserted, signer_name, signer_function,
     signed_by, kind, valid_until, data_categories)
  values (v_org, t.version, now(), true, btrim(p_name), btrim(p_function), (select auth.uid()), 'basis', now() + interval '24 months', array['volume','prices'])
  returning id into v_id;
  insert into public.huos_mandate_periods (mandate_id, period_start, period_end, kind, label)
  select v_id, (pp->>'start')::date, (pp->>'end')::date, pp->>'kind', pp->>'label' from jsonb_array_elements(per) pp;
  insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, confirmed_via, created_by)
  select v_id, ss->>'name', ss->>'role', array['volume','prices'], 'klant', 'portal', (select auth.uid()) from jsonb_array_elements(sups) ss;

  v_txt := public.huos_mandate_render(t.body, o.name, o.kvk_number, sups, per);
  insert into public.huos_mandate_signatures (mandate_id, kind, signer_id, signer_name, signer_function, org_name, org_kvk,
     suppliers, periods, data_categories, text_version, text_rendered, text_sha256)
  values (v_id, 'initial', (select auth.uid()), btrim(p_name), btrim(p_function), o.name, o.kvk_number, sups, per,
     array['volume','prices'], t.version, v_txt, encode(sha256(convert_to(v_txt, 'UTF8')), 'hex'));
  perform public.huos_mandate_log(v_id, 'mandate_signed', null,
    jsonb_build_object('signer', btrim(p_name), 'function', btrim(p_function), 'version', t.version,
                       'suppliers', jsonb_array_length(sups), 'periods', per));
  return v_id;
end $$;

-- Leverancier toevoegen aan een v3-machtiging = korte aanvullende ondertekening
create or replace function public.huos_my_mandate_supplier_add_v3(p_name text, p_role text, p_signer_name text, p_signer_function text, p_authority boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); m record; o record; t record; v_id uuid; per jsonb; sup jsonb; v_txt text;
begin
  select * into m from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified');
  if v_org is null or m.id is null then raise exception 'Er is geen lopende machtiging'; end if;
  if m.consent_text_version not like 'huos-mandate-v3%' then raise exception 'Deze machtiging gebruikt een oudere tekst'; end if;
  if m.valid_until is not null and m.valid_until < now() then raise exception 'De machtiging is verlopen; teken opnieuw'; end if;
  if coalesce(p_authority, false) is not true then raise exception 'Bevestig dat je bevoegd bent om namens het bedrijf te tekenen'; end if;
  if length(btrim(coalesce(p_signer_name,''))) < 2 or length(btrim(coalesce(p_signer_function,''))) < 2 then raise exception 'Vul je naam en functie in'; end if;
  if length(btrim(coalesce(p_name,''))) < 2 then raise exception 'Vul de naam van de leverancier in'; end if;
  select * into o from public.huos_pilot_organizations where id = v_org;
  select * into t from public.huos_mandate_texts where version = m.consent_text_version;
  update public.huos_beer_mandate_suppliers set status = 'active', revoked_at = null, revoked_reason = null, scope = array['volume','prices'], updated_at = now()
  where mandate_id = m.id and lower(btrim(supplier_name)) = lower(btrim(p_name)) and status = 'revoked' returning id into v_id;
  if v_id is null then
    insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, confirmed_via, created_by)
    values (m.id, btrim(p_name), coalesce(p_role,'overig'), array['volume','prices'], 'klant', 'portal', (select auth.uid()))
    returning id into v_id;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('start', period_start, 'end', period_end, 'kind', kind, 'label', label) order by period_start), '[]')
    into per from public.huos_mandate_periods where mandate_id = m.id;
  sup := jsonb_build_array(jsonb_build_object('name', btrim(p_name), 'role', coalesce(p_role,'overig')));
  v_txt := public.huos_mandate_render(t.body, o.name, o.kvk_number, sup, per);
  insert into public.huos_mandate_signatures (mandate_id, kind, signer_id, signer_name, signer_function, org_name, org_kvk,
     suppliers, periods, data_categories, text_version, text_rendered, text_sha256)
  values (m.id, 'addendum', (select auth.uid()), btrim(p_signer_name), btrim(p_signer_function), o.name, o.kvk_number, sup, per,
     coalesce(m.data_categories, array['volume','prices']), t.version, v_txt, encode(sha256(convert_to(v_txt, 'UTF8')), 'hex'));
  perform public.huos_mandate_log(m.id, 'mandate_supplier_added', v_id::text,
    jsonb_build_object('supplier', btrim(p_name), 'role', p_role, 'confirmed_via', 'portal', 'addendum', true));
  return v_id;
end $$;

-- Verzoek opstellen: ook geldigheid en periode controleren
create or replace function public.huos_mandate_request_create(p_supplier uuid, p_channel text, p_scope text[], p_note text,
  p_period_start date, p_period_end date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare s record; m record; v_id uuid; v_sig uuid; v_scope text[];
begin
  select * into s from public.huos_beer_mandate_suppliers where id = p_supplier;
  if s.id is null or not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(s.mandate_id) then raise exception 'Niet bevoegd'; end if;
  select * into m from public.huos_beer_mandates where id = s.mandate_id;
  if m.status <> 'verified' then raise exception 'Machtiging is nog niet gecontroleerd (bevoegdheid klant)'; end if;
  if m.valid_until is not null and m.valid_until < now() then raise exception 'Machtiging is verlopen'; end if;
  if s.status <> 'active' then raise exception 'Leverancier is niet actief in de machtiging'; end if;
  if s.name_check <> 'ok' then raise exception 'Controleer eerst de naam van de leverancier'; end if;
  v_scope := coalesce(p_scope, s.scope);
  if not (v_scope <@ s.scope) then raise exception 'Verzoek vraagt meer dan de machtiging toestaat'; end if;
  if exists (select 1 from public.huos_mandate_periods where mandate_id = m.id) then
    if p_period_start is null or p_period_end is null then raise exception 'Kies de periode van het verzoek'; end if;
    if not exists (select 1 from public.huos_mandate_periods where mandate_id = m.id
                   and p_period_start >= period_start and p_period_end <= period_end) then
      raise exception 'De gevraagde periode valt buiten de getekende periode'; end if;
    select id into v_sig from public.huos_mandate_signatures where mandate_id = m.id
      and suppliers @> jsonb_build_array(jsonb_build_object('name', s.supplier_name))
      order by signed_at desc limit 1;
    if v_sig is null then raise exception 'Geen ondertekening gevonden voor deze leverancier'; end if;
  end if;
  if exists (select 1 from public.huos_beer_mandate_requests where supplier_id = p_supplier and status in ('draft','approved','sent')) then
    raise exception 'Er loopt al een verzoek bij deze leverancier'; end if;
  insert into public.huos_beer_mandate_requests (mandate_id, supplier_id, supplier_name, channel, scope, status, drafted_by, note, period_start, period_end, signature_id)
  values (s.mandate_id, p_supplier, s.supplier_name, p_channel, v_scope, 'draft', (select auth.uid()), nullif(left(btrim(coalesce(p_note,'')),2000),''),
          p_period_start, p_period_end, v_sig)
  returning id into v_id;
  perform public.huos_mandate_log(s.mandate_id, 'mandate_request_drafted', v_id::text,
    jsonb_build_object('supplier', s.supplier_name, 'channel', p_channel, 'scope', v_scope, 'period', jsonb_build_array(p_period_start, p_period_end)));
  return v_id;
end $$;
-- De oude variant (zonder periode) blijft bestaan en loopt nu via dezelfde controles.
create or replace function public.huos_mandate_request_create(p_supplier uuid, p_channel text, p_scope text[], p_note text)
returns uuid language sql security definer set search_path = '' as $$
  select public.huos_mandate_request_create(p_supplier, p_channel, p_scope, p_note, null::date, null::date)
$$;
revoke all on function public.huos_mandate_request_create(uuid,text,text[],text,date,date) from public, anon;
grant execute on function public.huos_mandate_request_create(uuid,text,text[],text,date,date) to authenticated;

-- Verzoek bijwerken: geweigerd erbij; goedkeuren/versturen alleen bij geldige machtiging
create or replace function public.huos_mandate_request_set(p_request uuid, p_status text, p_note text, p_document uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r record; m record; v_uid uuid := (select auth.uid()); v_self boolean := false; v_org uuid;
begin
  select * into r from public.huos_beer_mandate_requests where id = p_request for update;
  if r.id is null or not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(r.mandate_id) then raise exception 'Niet bevoegd'; end if;
  if not ((r.status = 'draft' and p_status in ('approved','cancelled'))
       or (r.status = 'approved' and p_status in ('sent','cancelled'))
       or (r.status = 'sent' and p_status in ('answered','declined','cancelled'))) then
    raise exception 'Stap % → % is niet toegestaan', r.status, p_status;
  end if;
  select * into m from public.huos_beer_mandates where id = r.mandate_id;
  if p_status in ('approved','sent') then
    if m.status <> 'verified' then raise exception 'Machtiging is niet (meer) geldig'; end if;
    if m.valid_until is not null and m.valid_until < now() then raise exception 'Machtiging is verlopen'; end if;
    if (select status from public.huos_beer_mandate_suppliers where id = r.supplier_id) <> 'active' then raise exception 'Leverancier is ingetrokken'; end if;
  end if;
  if p_status = 'approved' and r.drafted_by = v_uid then
    if not public.huos_staff_has('admin') then raise exception 'Een andere bevoegde medewerker moet dit verzoek goedkeuren'; end if;
    v_self := true;
  end if;
  if p_document is not null then
    select coalesce(m2.organization_id, l.organization_id) into v_org
    from public.huos_beer_mandates m2 left join public.huos_beer_leads l on l.id = m2.lead_id where m2.id = r.mandate_id;
    if not exists (select 1 from public.huos_pilot_documents d where d.id = p_document and d.organization_id = v_org) then
      raise exception 'Document hoort niet bij deze klant'; end if;
  end if;
  update public.huos_beer_mandate_requests set
    status = p_status,
    approved_by = case when p_status = 'approved' then v_uid else approved_by end,
    approved_at = case when p_status = 'approved' then now() else approved_at end,
    self_approved = case when p_status = 'approved' then v_self else self_approved end,
    sent_at = case when p_status = 'sent' then now() else sent_at end,
    answered_at = case when p_status in ('answered','declined') then now() else answered_at end,
    response_pilot_document_id = coalesce(p_document, response_pilot_document_id),
    note = coalesce(nullif(left(btrim(coalesce(p_note,'')),2000),''), note)
  where id = p_request;
  perform public.huos_mandate_log(r.mandate_id, 'mandate_request_' || p_status, p_request::text,
    jsonb_build_object('supplier', r.supplier_name, 'from', r.status, 'self_approved', v_self, 'document', p_document));
end $$;

-- Intrekken: verstuurde verzoeken markeren zodat de leverancier wordt geïnformeerd
create or replace function public.huos_mandate_mark_sent_revoked()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'revoked' and old.status <> 'revoked' then
    if tg_table_name = 'huos_beer_mandate_suppliers' then
      update public.huos_beer_mandate_requests set needs_revoke_notice = true where supplier_id = new.id and status = 'sent';
    else
      update public.huos_beer_mandate_requests set needs_revoke_notice = true where mandate_id = new.id and status = 'sent';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.huos_mandate_mark_sent_revoked() from public, anon, authenticated;
create trigger huos_mandate_sup_revoke_notice after update of status on public.huos_beer_mandate_suppliers
  for each row execute function public.huos_mandate_mark_sent_revoked();
create trigger huos_mandate_revoke_notice after update of status on public.huos_beer_mandates
  for each row execute function public.huos_mandate_mark_sent_revoked();

revoke all on function public.huos_my_mandate_sign_v3(text,text,boolean,text,jsonb,text,jsonb) from public, anon;
revoke all on function public.huos_my_mandate_supplier_add_v3(text,text,text,text,boolean) from public, anon;
grant execute on function public.huos_my_mandate_sign_v3(text,text,boolean,text,jsonb,text,jsonb) to authenticated;
grant execute on function public.huos_my_mandate_supplier_add_v3(text,text,text,text,boolean) to authenticated;

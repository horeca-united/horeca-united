-- Machtiging per leverancier (stap A: database + afleiding uit de bierscan)
--
-- Wat verandert:
--  * huos_beer_mandates: kan nu ook aan een pilotklant (organisatie) hangen i.p.v. alleen een bierscan-lead
--    (voor stap B: machtiging vanuit "Mijn bedrijf"). Extra kolom followup voor open navraagpunten.
--  * Nieuwe tabel huos_beer_mandate_suppliers: per leverancier wat we mogen opvragen.
--  * huos_beer_mandate_requests: koppeling naar leverancier, notitie, antwoord als pilotdocument,
--    en zelf-goedkeuring alleen voor admin (vastgelegd met self_approved).
--  * RPC's voor beheer (reviewer+), alles gelogd in huos_beer_lead_events (append-only).
--  * Bierscan leidt automatisch leveranciers af uit de gekozen brouwerij/drankleverancier.
--
-- Rollback (handmatig, alleen als er nog geen echte verzoeken zijn):
--   drop function public.huos_mandate_link_org(uuid,uuid), public.huos_mandate_request_set(uuid,text,text,uuid),
--     public.huos_mandate_request_create(uuid,text,text[],text), public.huos_mandate_supplier_revoke(uuid,text),
--     public.huos_mandate_supplier_update(uuid,text,text[],text,text), public.huos_mandate_supplier_add(uuid,text,text,text[],text,text),
--     public.huos_mandate_suppliers_from_beer(uuid), public.huos_mandate_can_access(uuid), public.huos_mandate_log(uuid,text,text,jsonb);
--   drop table public.huos_beer_mandate_suppliers (na verwijderen supplier_id-kolom);
--   oude versies van huos_beer_mandate_decide / huos_beer_ensure_lead en policies terugzetten (staan in eerdere migraties).

-- 1. Machtiging: lead óf organisatie --------------------------------------------------------------
alter table public.huos_beer_mandates
  add column if not exists organization_id uuid references public.huos_pilot_organizations(id) on delete set null,
  add column if not exists followup text[] not null default '{}';
alter table public.huos_beer_mandates alter column lead_id drop not null;
alter table public.huos_beer_mandates
  add constraint huos_beer_mandates_subject_chk check (lead_id is not null or organization_id is not null);
create index if not exists huos_beer_mandates_org_idx on public.huos_beer_mandates(organization_id);

-- Toegang tot een machtiging: via de lead of via de organisatie (ook de organisatie van de lead)
create or replace function public.huos_mandate_can_access(p_mandate uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select (m.lead_id is not null and public.huos_staff_can_access_lead(m.lead_id))
        or (m.organization_id is not null and public.huos_staff_can_access_org(m.organization_id))
    from public.huos_beer_mandates m where m.id = p_mandate), false)
$$;
revoke all on function public.huos_mandate_can_access(uuid) from public, anon;
grant execute on function public.huos_mandate_can_access(uuid) to authenticated;

drop policy if exists huos_beer_mandates_staff_read on public.huos_beer_mandates;
create policy huos_beer_mandates_staff_read on public.huos_beer_mandates for select to authenticated
  using ((lead_id is not null and public.huos_staff_can_access_lead(lead_id))
      or (organization_id is not null and public.huos_staff_can_access_org(organization_id)));

-- Logregel (lead mag leeg zijn bij machtiging op organisatie)
create or replace function public.huos_mandate_log(p_mandate uuid, p_event text, p_entity_id text, p_details jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.huos_beer_lead_events (lead_id, actor_id, actor_role, event_type, entity, entity_id, details)
  select m.lead_id, (select auth.uid()), public.huos_staff_role(), p_event, 'mandate', coalesce(p_entity_id, m.id::text),
         coalesce(p_details, '{}'::jsonb) || jsonb_build_object('mandate_id', m.id, 'organization_id', m.organization_id)
  from public.huos_beer_mandates m where m.id = p_mandate;
$$;
revoke all on function public.huos_mandate_log(uuid,text,text,jsonb) from public, anon, authenticated;

-- 2. Leveranciers per machtiging -------------------------------------------------------------------
create table public.huos_beer_mandate_suppliers (
  id uuid primary key default gen_random_uuid(),
  mandate_id uuid not null references public.huos_beer_mandates(id) on delete restrict,
  supplier_name text not null check (length(btrim(supplier_name)) between 2 and 120),
  role text not null check (role in ('brouwerij','drankleverancier','groothandel','vers','energie','verzekering','overig')),
  scope text[] not null check (scope <@ array['volume','prices','discounts','bonuses','contract_terms'] and cardinality(scope) > 0),
  source text not null check (source in ('bierscan','klant','medewerker')),
  status text not null default 'active' check (status in ('active','proposed','revoked')),
  name_check text not null default 'ok' check (name_check in ('ok','to_verify')),
  confirmed_via text check (confirmed_via in ('bierscan','email','phone','in_person','portal')),
  confirmed_note text check (confirmed_note is null or length(confirmed_note) <= 1000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_reason text check (revoked_reason is null or length(revoked_reason) <= 1000),
  constraint huos_mandate_sup_revoked_chk check ((status = 'revoked') = (revoked_at is not null))
);
create unique index huos_mandate_sup_name_uidx on public.huos_beer_mandate_suppliers (mandate_id, lower(btrim(supplier_name)));
alter table public.huos_beer_mandate_suppliers enable row level security;
revoke all on public.huos_beer_mandate_suppliers from anon, authenticated;
grant select on public.huos_beer_mandate_suppliers to authenticated;
create policy huos_mandate_sup_staff_read on public.huos_beer_mandate_suppliers for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_mandate_can_access(mandate_id));

-- 3. Verzoeken: koppeling leverancier, zelf-goedkeuring admin, antwoord als pilotdocument -----------
alter table public.huos_beer_mandate_requests
  add column if not exists supplier_id uuid references public.huos_beer_mandate_suppliers(id) on delete restrict,
  add column if not exists self_approved boolean not null default false,
  add column if not exists note text check (note is null or length(note) <= 2000),
  add column if not exists approved_at timestamptz,
  add column if not exists response_pilot_document_id uuid references public.huos_pilot_documents(id) on delete set null;
alter table public.huos_beer_mandate_requests drop constraint if exists huos_beer_mreq_four_eyes_chk;
alter table public.huos_beer_mandate_requests add constraint huos_beer_mreq_four_eyes_chk
  check (approved_by is null or approved_by is distinct from drafted_by or self_approved);

drop policy if exists huos_beer_mreq_staff_read on public.huos_beer_mandate_requests;
create policy huos_beer_mreq_staff_read on public.huos_beer_mandate_requests for select to authenticated
  using (public.huos_staff_has('reviewer') and public.huos_mandate_can_access(mandate_id));

-- 4. Afleiden uit bierscan-antwoorden (idempotent) -------------------------------------------------
create or replace function public.huos_mandate_suppliers_from_beer(p_mandate uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a jsonb; v_brew text; v_brew_chk text := 'ok'; v_dist text; v_dist_chk text := 'ok';
        v_direct text; v_follow text[] := '{}'; v_role text;
begin
  select s.answers into a
  from public.huos_beer_mandates m
  join public.huos_beer_leads l on l.id = m.lead_id
  join public.huos_beer_intake_submissions s on s.id = l.submission_id
  where m.id = p_mandate;
  if a is null then return; end if;

  v_brew := nullif(btrim(coalesce(a->>'brewery_supplier','')), '');
  if lower(coalesce(v_brew,'')) in ('other','anders') then
    v_brew := nullif(btrim(coalesce(a->>'brewery_supplier_other','')), ''); v_brew_chk := 'to_verify';
  elsif lower(coalesce(v_brew,'')) in ('unknown','onbekend','weet niet') then v_brew := null;
  end if;

  v_dist := nullif(btrim(coalesce(a->>'distributor','')), '');
  if lower(coalesce(v_dist,'')) in ('other','anders') then
    v_dist := nullif(btrim(coalesce(a->>'distributor_other','')), ''); v_dist_chk := 'to_verify';
    if v_dist is null then v_follow := v_follow || 'leverancier navragen'; end if;
  elsif lower(coalesce(v_dist,'')) in ('unknown','onbekend','weet niet') then
    v_dist := null; v_follow := v_follow || 'leverancier navragen';
  elsif lower(coalesce(v_dist,'')) = 'direct' then
    v_dist := 'direct';
  end if;

  if v_brew is null then v_follow := v_follow || 'brouwerij navragen'; end if;

  if v_dist = 'direct' then
    if v_brew is not null then
      insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, name_check, confirmed_via)
      values (p_mandate, v_brew, 'brouwerij', array['volume','prices','discounts','bonuses','contract_terms'], 'bierscan', v_brew_chk, 'bierscan')
      on conflict do nothing;
    end if;
  else
    if v_brew is not null then
      insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, name_check, confirmed_via)
      values (p_mandate, v_brew, 'brouwerij', array['volume','discounts','bonuses','contract_terms'], 'bierscan', v_brew_chk, 'bierscan')
      on conflict do nothing;
    end if;
    if v_dist is not null then
      v_role := case when lower(v_dist) ~ '(sligro|hanos|bidfood|makro|metro|horesca|van hoeckel)' then 'groothandel' else 'drankleverancier' end;
      insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, name_check, confirmed_via)
      values (p_mandate, v_dist, v_role, array['volume','prices','discounts'], 'bierscan', v_dist_chk, 'bierscan')
      on conflict do nothing;
    end if;
  end if;

  v_direct := nullif(btrim(coalesce(a->>'direct_delivery_brewery','')), '');
  if v_direct is not null and lower(v_direct) not in ('no','nee','yes','ja','unknown','onbekend')
     and lower(v_direct) <> lower(coalesce(v_brew,'')) then
    insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, name_check, confirmed_via)
    values (p_mandate, v_direct, 'brouwerij', array['volume','prices','discounts','bonuses','contract_terms'], 'bierscan', 'to_verify', 'bierscan')
    on conflict do nothing;
  end if;

  update public.huos_beer_mandates set followup = (select coalesce(array_agg(distinct f), '{}') from unnest(followup || v_follow) f)
  where id = p_mandate;
end $$;
revoke all on function public.huos_mandate_suppliers_from_beer(uuid) from public, anon, authenticated;

-- Nieuwe bierscan-leads: leveranciers direct afleiden
create or replace function public.huos_beer_ensure_lead(p_submission uuid)
 returns uuid language plpgsql security definer set search_path to '' as $function$
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
 perform public.huos_mandate_suppliers_from_beer(v_mand);
 end if;
 perform public.huos_beer_log(v_lead, 'lead_created', 'submission', p_submission::text,
 jsonb_build_object('data_route', v_sub.data_route));
 return v_lead;
end $function$;

-- Beslissen over machtiging: nieuwe toegangscheck, bij intrekken/afwijzen ook leveranciers intrekken
create or replace function public.huos_beer_mandate_decide(p_mandate uuid, p_status text, p_method text default null, p_note text default null, p_revoked_via text default null)
 returns void language plpgsql security definer set search_path to '' as $function$
declare v_old text;
begin
 if not public.huos_staff_has('reviewer') then raise exception 'Niet bevoegd'; end if;
 select status into v_old from public.huos_beer_mandates where id = p_mandate for update;
 if v_old is null or not public.huos_mandate_can_access(p_mandate) then raise exception 'Onbekende machtiging'; end if;
 if v_old = 'revoked' then raise exception 'Een ingetrokken machtiging kan niet worden heropend'; end if;
 if p_status not in ('verified','rejected','revoked') then raise exception 'Ongeldige status'; end if;
 if p_status = 'verified' and (p_method is null or length(trim(coalesce(p_note,''))) < 5) then
 raise exception 'Leg vast hoe de bevoegdheid is gecontroleerd (methode + notitie)'; end if;
 if p_status = 'revoked' and p_revoked_via is null then raise exception 'Leg vast hoe is ingetrokken'; end if;
 update public.huos_beer_mandates set
 status = p_status,
 authority_check_method = case when p_status in ('verified','rejected') then p_method else authority_check_method end,
 authority_checked_by   = case when p_status in ('verified','rejected') then (select auth.uid()) else authority_checked_by end,
 authority_checked_at   = case when p_status in ('verified','rejected') then now() else authority_checked_at end,
 authority_note         = case when p_status in ('verified','rejected') then trim(p_note) else authority_note end,
 revoked_at     = case when p_status = 'revoked' then now() else revoked_at end,
 revoked_via    = case when p_status = 'revoked' then p_revoked_via else revoked_via end,
 revoked_reason = case when p_status = 'revoked' then left(trim(p_note), 1000) else revoked_reason end
 where id = p_mandate;
 if p_status in ('revoked','rejected') then
 update public.huos_beer_mandate_requests set status = 'cancelled'
 where mandate_id = p_mandate and status in ('draft','approved');
 update public.huos_beer_mandate_suppliers set status = 'revoked', revoked_at = now(), updated_at = now(),
   revoked_reason = 'Machtiging ' || case when p_status = 'revoked' then 'ingetrokken' else 'afgewezen' end
 where mandate_id = p_mandate and status <> 'revoked';
 end if;
 perform public.huos_mandate_log(p_mandate, 'mandate_' || p_status, null,
 jsonb_build_object('from', v_old, 'to', p_status, 'method', p_method));
end $function$;

-- 5. Beheer-RPC's ----------------------------------------------------------------------------------
create or replace function public.huos_mandate_supplier_add(p_mandate uuid, p_name text, p_role text, p_scope text[], p_confirmed_via text, p_note text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_status text;
begin
  if not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(p_mandate) then raise exception 'Niet bevoegd'; end if;
  select status into v_status from public.huos_beer_mandates where id = p_mandate;
  if v_status in ('revoked','rejected') then raise exception 'Machtiging is niet (meer) geldig'; end if;
  if p_confirmed_via not in ('email','phone','in_person','portal') or length(btrim(coalesce(p_note,''))) < 5 then
    raise exception 'Leg vast hoe de klant deze leverancier heeft bevestigd (kanaal + notitie)';
  end if;
  insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, confirmed_via, confirmed_note, created_by)
  values (p_mandate, btrim(p_name), p_role, p_scope, 'medewerker', p_confirmed_via, btrim(p_note), (select auth.uid()))
  returning id into v_id;
  perform public.huos_mandate_log(p_mandate, 'mandate_supplier_added', v_id::text,
    jsonb_build_object('supplier', btrim(p_name), 'role', p_role, 'scope', p_scope, 'confirmed_via', p_confirmed_via));
  return v_id;
end $$;

create or replace function public.huos_mandate_supplier_update(p_supplier uuid, p_name text, p_scope text[], p_name_check text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select * into s from public.huos_beer_mandate_suppliers where id = p_supplier for update;
  if s.id is null or not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(s.mandate_id) then raise exception 'Niet bevoegd'; end if;
  if s.status = 'revoked' then raise exception 'Ingetrokken leverancier kan niet worden gewijzigd'; end if;
  if length(btrim(coalesce(p_note,''))) < 5 then raise exception 'Geef kort aan waarom (notitie)'; end if;
  update public.huos_beer_mandate_suppliers set
    supplier_name = coalesce(nullif(btrim(p_name),''), supplier_name),
    scope = coalesce(p_scope, scope),
    name_check = coalesce(p_name_check, name_check),
    confirmed_note = left(btrim(p_note), 1000),
    updated_at = now()
  where id = p_supplier;
  perform public.huos_mandate_log(s.mandate_id, 'mandate_supplier_updated', p_supplier::text,
    jsonb_build_object('from', jsonb_build_object('name', s.supplier_name, 'scope', s.scope, 'name_check', s.name_check),
                       'to', jsonb_build_object('name', coalesce(nullif(btrim(p_name),''), s.supplier_name), 'scope', coalesce(p_scope, s.scope), 'name_check', coalesce(p_name_check, s.name_check)),
                       'note', btrim(p_note)));
end $$;

create or replace function public.huos_mandate_supplier_revoke(p_supplier uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select * into s from public.huos_beer_mandate_suppliers where id = p_supplier for update;
  if s.id is null or not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(s.mandate_id) then raise exception 'Niet bevoegd'; end if;
  if s.status = 'revoked' then return; end if;
  if length(btrim(coalesce(p_reason,''))) < 5 then raise exception 'Geef een reden'; end if;
  update public.huos_beer_mandate_suppliers set status = 'revoked', revoked_at = now(), revoked_reason = left(btrim(p_reason),1000), updated_at = now()
  where id = p_supplier;
  update public.huos_beer_mandate_requests set status = 'cancelled' where supplier_id = p_supplier and status in ('draft','approved');
  perform public.huos_mandate_log(s.mandate_id, 'mandate_supplier_revoked', p_supplier::text, jsonb_build_object('supplier', s.supplier_name, 'reason', btrim(p_reason)));
end $$;

create or replace function public.huos_mandate_request_create(p_supplier uuid, p_channel text, p_scope text[], p_note text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare s record; v_mstatus text; v_id uuid;
begin
  select * into s from public.huos_beer_mandate_suppliers where id = p_supplier;
  if s.id is null or not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(s.mandate_id) then raise exception 'Niet bevoegd'; end if;
  select status into v_mstatus from public.huos_beer_mandates where id = s.mandate_id;
  if v_mstatus <> 'verified' then raise exception 'Machtiging is nog niet gecontroleerd (bevoegdheid klant)'; end if;
  if s.status <> 'active' then raise exception 'Leverancier is niet actief in de machtiging'; end if;
  if s.name_check <> 'ok' then raise exception 'Controleer eerst de naam van de leverancier'; end if;
  if not (coalesce(p_scope, s.scope) <@ s.scope) then raise exception 'Verzoek vraagt meer dan de machtiging toestaat'; end if;
  if exists (select 1 from public.huos_beer_mandate_requests where supplier_id = p_supplier and status in ('draft','approved','sent')) then
    raise exception 'Er loopt al een verzoek bij deze leverancier';
  end if;
  insert into public.huos_beer_mandate_requests (mandate_id, supplier_id, supplier_name, channel, scope, status, drafted_by, note)
  values (s.mandate_id, p_supplier, s.supplier_name, p_channel, coalesce(p_scope, s.scope), 'draft', (select auth.uid()), nullif(left(btrim(coalesce(p_note,'')),2000),''))
  returning id into v_id;
  perform public.huos_mandate_log(s.mandate_id, 'mandate_request_drafted', v_id::text,
    jsonb_build_object('supplier', s.supplier_name, 'channel', p_channel, 'scope', coalesce(p_scope, s.scope)));
  return v_id;
end $$;

create or replace function public.huos_mandate_request_set(p_request uuid, p_status text, p_note text, p_document uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_uid uuid := (select auth.uid()); v_self boolean := false; v_org uuid;
begin
  select * into r from public.huos_beer_mandate_requests where id = p_request for update;
  if r.id is null or not public.huos_staff_has('reviewer') or not public.huos_mandate_can_access(r.mandate_id) then raise exception 'Niet bevoegd'; end if;
  if not ((r.status = 'draft' and p_status in ('approved','cancelled'))
       or (r.status = 'approved' and p_status in ('sent','cancelled'))
       or (r.status = 'sent' and p_status in ('answered','cancelled'))) then
    raise exception 'Stap % → % is niet toegestaan', r.status, p_status;
  end if;
  if p_status = 'approved' then
    if r.drafted_by = v_uid then
      if not public.huos_staff_has('admin') then raise exception 'Een andere bevoegde medewerker moet dit verzoek goedkeuren'; end if;
      v_self := true;
    end if;
    if (select status from public.huos_beer_mandates where id = r.mandate_id) <> 'verified' then raise exception 'Machtiging is niet (meer) geldig'; end if;
  end if;
  if p_document is not null then
    select coalesce(m.organization_id, l.organization_id) into v_org
    from public.huos_beer_mandates m left join public.huos_beer_leads l on l.id = m.lead_id where m.id = r.mandate_id;
    if not exists (select 1 from public.huos_pilot_documents d where d.id = p_document and d.organization_id = v_org) then
      raise exception 'Document hoort niet bij deze klant';
    end if;
  end if;
  update public.huos_beer_mandate_requests set
    status = p_status,
    approved_by = case when p_status = 'approved' then v_uid else approved_by end,
    approved_at = case when p_status = 'approved' then now() else approved_at end,
    self_approved = case when p_status = 'approved' then v_self else self_approved end,
    sent_at = case when p_status = 'sent' then now() else sent_at end,
    answered_at = case when p_status = 'answered' then now() else answered_at end,
    response_pilot_document_id = coalesce(p_document, response_pilot_document_id),
    note = coalesce(nullif(left(btrim(coalesce(p_note,'')),2000),''), note)
  where id = p_request;
  perform public.huos_mandate_log(r.mandate_id, 'mandate_request_' || p_status, p_request::text,
    jsonb_build_object('supplier', r.supplier_name, 'from', r.status, 'self_approved', v_self, 'document', p_document));
end $$;

create or replace function public.huos_mandate_link_org(p_mandate uuid, p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old uuid;
begin
  if not public.huos_staff_has('admin') or not public.huos_mandate_can_access(p_mandate) or not public.huos_staff_can_access_org(p_org) then
    raise exception 'Niet bevoegd';
  end if;
  select organization_id into v_old from public.huos_beer_mandates where id = p_mandate for update;
  update public.huos_beer_mandates set organization_id = p_org where id = p_mandate;
  perform public.huos_mandate_log(p_mandate, 'mandate_linked_org', null, jsonb_build_object('from', v_old, 'to', p_org));
end $$;

revoke all on function public.huos_mandate_supplier_add(uuid,text,text,text[],text,text) from public, anon;
revoke all on function public.huos_mandate_supplier_update(uuid,text,text[],text,text) from public, anon;
revoke all on function public.huos_mandate_supplier_revoke(uuid,text) from public, anon;
revoke all on function public.huos_mandate_request_create(uuid,text,text[],text) from public, anon;
revoke all on function public.huos_mandate_request_set(uuid,text,text,uuid) from public, anon;
revoke all on function public.huos_mandate_link_org(uuid,uuid) from public, anon;
grant execute on function public.huos_mandate_supplier_add(uuid,text,text,text[],text,text) to authenticated;
grant execute on function public.huos_mandate_supplier_update(uuid,text,text[],text,text) to authenticated;
grant execute on function public.huos_mandate_supplier_revoke(uuid,text) to authenticated;
grant execute on function public.huos_mandate_request_create(uuid,text,text[],text) to authenticated;
grant execute on function public.huos_mandate_request_set(uuid,text,text,uuid) to authenticated;
grant execute on function public.huos_mandate_link_org(uuid,uuid) to authenticated;

-- 6. Bestaande machtigingen: leveranciers afleiden ------------------------------------------------
do $bf$ declare m uuid; begin
  for m in select id from public.huos_beer_mandates where lead_id is not null loop
    perform public.huos_mandate_suppliers_from_beer(m);
  end loop;
end $bf$;

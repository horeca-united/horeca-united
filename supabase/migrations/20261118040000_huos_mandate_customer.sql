-- Machtiging stap B: klant tekent zelf in HUOS (Mijn bedrijf → Machtiging)
--
-- Wat verandert:
--  * huos_mandate_texts: vastgelegde machtigingsteksten (versie 2 = algemeen, nog te toetsen door jurist).
--  * huos_org_features: per klant aanzetten (alleen 't Volk tot de tekst is goedgekeurd).
--  * huos_beer_mandates: ondertekenaar (naam, functie, account), intrekken via 'portal',
--    maximaal één lopende machtiging per pilotklant.
--  * Klant-RPC's (alleen eigen bedrijf, bepaald via het ingelogde account): ophalen, tekenen,
--    leverancier toevoegen / gegevens aanpassen / intrekken, hele machtiging intrekken.
--  * Logregels zonder lead (machtiging op bedrijf) zichtbaar voor medewerkers met toegang tot dat bedrijf.
--  * Koppelen bierscan-machtiging aan pilotklant: alleen als die klant nog geen lopende machtiging heeft.
--
-- Rollback: functies huos_my_mandate*, huos_mandate_guess_role droppen; tabellen huos_mandate_texts en
-- huos_org_features droppen; kolommen signer_* / signed_by droppen; index huos_beer_mandates_org_active_uidx
-- droppen; revoked_via-check en events-policy terugzetten; huos_mandate_link_org uit 20261118030000 terugzetten.

create table public.huos_mandate_texts (
  version text primary key,
  title text not null,
  body text not null,
  created_at timestamptz not null default now()
);
alter table public.huos_mandate_texts enable row level security;
revoke all on public.huos_mandate_texts from anon, authenticated;
create trigger huos_mandate_texts_append_only before update or delete on public.huos_mandate_texts
  for each row execute function public.huos_cost_audit_guard();

insert into public.huos_mandate_texts (version, title, body) values ('huos-mandate-v2', 'Machtiging gegevens opvragen bij leveranciers',
'Ik verklaar dat ik bevoegd ben om namens {bedrijf} te handelen.

Ik geef Horeca United toestemming om bij de leveranciers die ik hieronder heb aangevinkt de gegevens op te vragen die ik per leverancier heb gekozen: afname (volume), prijzen, kortingen, bonussen en/of contractvoorwaarden.

Horeca United gebruikt deze gegevens alleen om de inkoop van mijn onderneming te beoordelen en mij daarover te adviseren. Horeca United geeft de gegevens niet door aan andere leveranciers of andere ondernemers. Voor vergelijkingen met andere ondernemingen worden ze alleen gebruikt zonder dat mijn onderneming herkenbaar is.

Horeca United plaatst geen bestellingen, wijzigt geen contracten en zegt niets op namens mij.

Ik kan deze machtiging op elk moment in HUOS intrekken, voor één leverancier of helemaal. Opgevraagde gegevens komen in mijn eigen HUOS-omgeving te staan.');

create table public.huos_org_features (
  organization_id uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  feature text not null check (feature in ('mandate')),
  created_at timestamptz not null default now(),
  primary key (organization_id, feature)
);
alter table public.huos_org_features enable row level security;
revoke all on public.huos_org_features from anon, authenticated;
insert into public.huos_org_features (organization_id, feature)
select id, 'mandate' from public.huos_pilot_organizations where id = 'aab54fda-a288-4a16-a326-1e9c0f6db7e9';

alter table public.huos_beer_mandates
  add column if not exists signer_name text check (signer_name is null or length(btrim(signer_name)) between 2 and 120),
  add column if not exists signer_function text check (signer_function is null or length(btrim(signer_function)) between 2 and 80),
  add column if not exists signed_by uuid references auth.users(id) on delete set null;
alter table public.huos_beer_mandates drop constraint huos_beer_mandates_revoked_via_check;
alter table public.huos_beer_mandates add constraint huos_beer_mandates_revoked_via_check
  check (revoked_via = any (array['email','phone','in_person','other','portal']));
create unique index huos_beer_mandates_org_active_uidx on public.huos_beer_mandates (organization_id)
  where organization_id is not null and status in ('pending','verified');

-- Logregels op bedrijfsniveau zichtbaar voor medewerkers met toegang tot dat bedrijf
create policy huos_beer_events_staff_read_org on public.huos_beer_lead_events for select to authenticated
  using (lead_id is null and public.huos_staff_has('reviewer')
         and (details->>'organization_id') ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and public.huos_staff_can_access_org((details->>'organization_id')::uuid));

-- Soort leverancier raden (voor voorstellen)
create or replace function public.huos_mandate_guess_role(p_name text, p_cat text)
returns text language sql immutable set search_path = '' as $$
  select case
    when lower(p_name) ~ '(sligro|hanos|bidfood|makro|metro|horesca|van hoeckel)' then 'groothandel'
    when p_cat = 'brouwerij' then 'brouwerij'
    when p_cat in ('wijn','drank','bier','fris','gedistilleerd') then 'drankleverancier'
    when p_cat in ('food','vis','vlees','agf','zuivel','brood') then 'vers'
    else 'overig' end
$$;

-- Eigen bedrijf (nooit vanuit de browser meegestuurd)
create or replace function public.huos_my_org_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select o.id from public.huos_pilot_organizations o where o.owner_id = (select auth.uid()) order by o.created_at limit 1
$$;
revoke all on function public.huos_my_org_id() from public, anon, authenticated;

create or replace function public.huos_my_mandate()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); v_m record; v_sup jsonb := '[]'; v_prop jsonb := '[]'; v_text jsonb;
begin
  if v_org is null or not exists (select 1 from public.huos_org_features where organization_id = v_org and feature = 'mandate') then
    return jsonb_build_object('enabled', false);
  end if;
  select jsonb_build_object('version', version, 'title', title, 'body', body) into v_text
  from public.huos_mandate_texts where version = 'huos-mandate-v2';
  select * into v_m from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified');
  if v_m.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.supplier_name, 'role', s.role, 'scope', s.scope, 'status', s.status,
             'request', (select jsonb_build_object('status', r.status, 'sent_at', r.sent_at, 'answered_at', r.answered_at)
                         from public.huos_beer_mandate_requests r where r.supplier_id = s.id and r.status <> 'cancelled'
                         order by r.created_at desc limit 1)) order by s.status, s.supplier_name), '[]')
      into v_sup from public.huos_beer_mandate_suppliers s where s.mandate_id = v_m.id;
  end if;
  with cand as (
    select btrim(l.supplier) as name, (array_agg(l.category order by l.amount_excl_vat desc nulls last))[1] as cat
    from public.huos_cost_lines l
    where l.organization_id = v_org and l.category in ('groothandel','food','vis','wijn','drank','bier','fris','vlees','agf','zuivel','brood','gedistilleerd')
      and length(btrim(coalesce(l.supplier,''))) >= 2
    group by btrim(l.supplier)
    union
    select btrim(b.answers->>'brewery_supplier'), 'brouwerij' from public.huos_pilot_beer_scans b
    where b.organization_id = v_org and length(btrim(coalesce(b.answers->>'brewery_supplier',''))) >= 2
      and lower(b.answers->>'brewery_supplier') not in ('other','unknown','anders','onbekend')
    union
    select btrim(b.answers->>'distributor'), 'drank' from public.huos_pilot_beer_scans b
    where b.organization_id = v_org and length(btrim(coalesce(b.answers->>'distributor',''))) >= 2
      and lower(b.answers->>'distributor') not in ('other','unknown','direct','anders','onbekend')
  )
  select coalesce(jsonb_agg(jsonb_build_object('name', c.name, 'role', public.huos_mandate_guess_role(c.name, c.cat),
           'scope', case when public.huos_mandate_guess_role(c.name, c.cat) = 'brouwerij'
                         then '["volume","prices","discounts","bonuses","contract_terms"]'::jsonb
                         else '["volume","prices","discounts"]'::jsonb end) order by c.name), '[]')
    into v_prop
  from (select distinct on (lower(name)) name, cat from cand order by lower(name)) c
  where not exists (select 1 from public.huos_beer_mandate_suppliers s
                    where s.mandate_id = v_m.id and s.status <> 'revoked' and lower(btrim(s.supplier_name)) = lower(c.name));
  return jsonb_build_object('enabled', true, 'text', v_text, 'suppliers', v_sup, 'proposals', v_prop,
    'mandate', case when v_m.id is null then null else jsonb_build_object('id', v_m.id, 'status', v_m.status,
      'signer_name', v_m.signer_name, 'signer_function', v_m.signer_function, 'consent_at', v_m.consent_at,
      'text_version', v_m.consent_text_version, 'verified_at', v_m.authority_checked_at) end);
end $$;

create or replace function public.huos_my_mandate_sign(p_name text, p_function text, p_authority boolean, p_version text, p_suppliers jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); v_id uuid; x jsonb; v_n int := 0;
begin
  if v_org is null or not exists (select 1 from public.huos_org_features where organization_id = v_org and feature = 'mandate') then
    raise exception 'Machtiging is (nog) niet beschikbaar voor jouw bedrijf';
  end if;
  if coalesce(p_authority, false) is not true then raise exception 'Bevestig dat je bevoegd bent om namens het bedrijf te tekenen'; end if;
  if length(btrim(coalesce(p_name,''))) < 2 or length(btrim(coalesce(p_function,''))) < 2 then raise exception 'Vul je naam en functie in'; end if;
  if p_version is distinct from 'huos-mandate-v2' then raise exception 'De machtigingstekst is gewijzigd. Vernieuw de pagina.'; end if;
  if p_suppliers is null or jsonb_typeof(p_suppliers) <> 'array' or jsonb_array_length(p_suppliers) = 0 or jsonb_array_length(p_suppliers) > 40 then
    raise exception 'Kies minstens één leverancier';
  end if;
  if exists (select 1 from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified')) then
    raise exception 'Er is al een lopende machtiging';
  end if;
  insert into public.huos_beer_mandates (organization_id, consent_text_version, consent_at, authority_asserted, signer_name, signer_function, signed_by)
  values (v_org, p_version, now(), true, btrim(p_name), btrim(p_function), (select auth.uid()))
  returning id into v_id;
  for x in select * from jsonb_array_elements(p_suppliers) loop
    insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, confirmed_via, created_by)
    values (v_id, btrim(x->>'name'), x->>'role', array(select jsonb_array_elements_text(x->'scope')), 'klant', 'portal', (select auth.uid()))
    on conflict do nothing;
    v_n := v_n + 1;
  end loop;
  perform public.huos_mandate_log(v_id, 'mandate_signed', null,
    jsonb_build_object('signer', btrim(p_name), 'function', btrim(p_function), 'version', p_version, 'suppliers', v_n));
  return v_id;
end $$;

create or replace function public.huos_my_mandate_supplier_add(p_name text, p_role text, p_scope text[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); v_m uuid; v_id uuid;
begin
  select id into v_m from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified');
  if v_org is null or v_m is null then raise exception 'Er is geen lopende machtiging'; end if;
  update public.huos_beer_mandate_suppliers set status = 'active', revoked_at = null, revoked_reason = null, scope = p_scope, updated_at = now()
  where mandate_id = v_m and lower(btrim(supplier_name)) = lower(btrim(p_name)) and status = 'revoked'
  returning id into v_id;
  if v_id is null then
    insert into public.huos_beer_mandate_suppliers (mandate_id, supplier_name, role, scope, source, confirmed_via, created_by)
    values (v_m, btrim(p_name), p_role, p_scope, 'klant', 'portal', (select auth.uid()))
    returning id into v_id;
  end if;
  perform public.huos_mandate_log(v_m, 'mandate_supplier_added', v_id::text,
    jsonb_build_object('supplier', btrim(p_name), 'role', p_role, 'scope', p_scope, 'confirmed_via', 'portal'));
  return v_id;
end $$;

create or replace function public.huos_my_mandate_supplier_scope(p_supplier uuid, p_scope text[])
returns void language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select s0.*, m.organization_id into s from public.huos_beer_mandate_suppliers s0
  join public.huos_beer_mandates m on m.id = s0.mandate_id where s0.id = p_supplier for update of s0;
  if s.id is null or s.organization_id is distinct from public.huos_my_org_id() then raise exception 'Onbekende leverancier'; end if;
  if s.status = 'revoked' then raise exception 'Deze leverancier is ingetrokken'; end if;
  update public.huos_beer_mandate_suppliers set scope = p_scope, updated_at = now() where id = p_supplier;
  update public.huos_beer_mandate_requests set status = 'cancelled'
  where supplier_id = p_supplier and status in ('draft','approved') and not (scope <@ p_scope);
  perform public.huos_mandate_log(s.mandate_id, 'mandate_supplier_updated', p_supplier::text,
    jsonb_build_object('from', jsonb_build_object('scope', s.scope), 'to', jsonb_build_object('scope', p_scope), 'note', 'Aangepast door klant'));
end $$;

create or replace function public.huos_my_mandate_supplier_revoke(p_supplier uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare s record;
begin
  select s0.*, m.organization_id into s from public.huos_beer_mandate_suppliers s0
  join public.huos_beer_mandates m on m.id = s0.mandate_id where s0.id = p_supplier for update of s0;
  if s.id is null or s.organization_id is distinct from public.huos_my_org_id() then raise exception 'Onbekende leverancier'; end if;
  if s.status = 'revoked' then return; end if;
  update public.huos_beer_mandate_suppliers set status = 'revoked', revoked_at = now(), revoked_reason = 'Ingetrokken door klant in HUOS', updated_at = now()
  where id = p_supplier;
  update public.huos_beer_mandate_requests set status = 'cancelled' where supplier_id = p_supplier and status in ('draft','approved');
  perform public.huos_mandate_log(s.mandate_id, 'mandate_supplier_revoked', p_supplier::text,
    jsonb_build_object('supplier', s.supplier_name, 'reason', 'Ingetrokken door klant in HUOS'));
end $$;

create or replace function public.huos_my_mandate_revoke()
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); v_m record;
begin
  select * into v_m from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified') for update;
  if v_org is null or v_m.id is null then raise exception 'Er is geen lopende machtiging'; end if;
  update public.huos_beer_mandates set status = 'revoked', revoked_at = now(), revoked_via = 'portal',
    revoked_reason = 'Ingetrokken door klant in HUOS' where id = v_m.id;
  update public.huos_beer_mandate_requests set status = 'cancelled' where mandate_id = v_m.id and status in ('draft','approved');
  update public.huos_beer_mandate_suppliers set status = 'revoked', revoked_at = now(), updated_at = now(), revoked_reason = 'Machtiging ingetrokken'
  where mandate_id = v_m.id and status <> 'revoked';
  perform public.huos_mandate_log(v_m.id, 'mandate_revoked', null, jsonb_build_object('from', v_m.status, 'to', 'revoked', 'via', 'portal'));
end $$;

-- Bierscan-machtiging koppelen: alleen als de klant nog geen lopende machtiging heeft
create or replace function public.huos_mandate_link_org(p_mandate uuid, p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_old uuid;
begin
  if not public.huos_staff_has('admin') or not public.huos_mandate_can_access(p_mandate) or not public.huos_staff_can_access_org(p_org) then
    raise exception 'Niet bevoegd';
  end if;
  if exists (select 1 from public.huos_beer_mandates where organization_id = p_org and status in ('pending','verified') and id <> p_mandate) then
    raise exception 'Deze klant heeft al een lopende machtiging';
  end if;
  select organization_id into v_old from public.huos_beer_mandates where id = p_mandate for update;
  update public.huos_beer_mandates set organization_id = p_org where id = p_mandate;
  perform public.huos_mandate_log(p_mandate, 'mandate_linked_org', null, jsonb_build_object('from', v_old, 'to', p_org));
end $$;

revoke all on function public.huos_mandate_guess_role(text,text) from public, anon, authenticated;
revoke all on function public.huos_my_mandate() from public, anon;
revoke all on function public.huos_my_mandate_sign(text,text,boolean,text,jsonb) from public, anon;
revoke all on function public.huos_my_mandate_supplier_add(text,text,text[]) from public, anon;
revoke all on function public.huos_my_mandate_supplier_scope(uuid,text[]) from public, anon;
revoke all on function public.huos_my_mandate_supplier_revoke(uuid) from public, anon;
revoke all on function public.huos_my_mandate_revoke() from public, anon;
grant execute on function public.huos_my_mandate() to authenticated;
grant execute on function public.huos_my_mandate_sign(text,text,boolean,text,jsonb) to authenticated;
grant execute on function public.huos_my_mandate_supplier_add(text,text,text[]) to authenticated;
grant execute on function public.huos_my_mandate_supplier_scope(uuid,text[]) to authenticated;
grant execute on function public.huos_my_mandate_supplier_revoke(uuid) to authenticated;
grant execute on function public.huos_my_mandate_revoke() to authenticated;

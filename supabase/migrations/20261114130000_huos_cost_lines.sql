-- HUOS 2.0 — Mijn kosten (fase 1): interne kostenregels + prijsvergelijking
-- Alleen voor Horeca United-medewerkers; de ondernemer heeft GEEN toegang tot deze tabellen.
-- Raakt geen bestaande gegevens. Nieuwe objecten:
--   huos_staff_can_access_org(uuid)          functie: mag deze medewerker dit klantbedrijf zien?
--   huos_cost_lines                           kostenregels per klantbedrijf (factuurregels)
--   huos_cost_line_audit                      logboek van elke wijziging (alleen toevoegen)
--   huos_cost_comparison                      view: nieuwste factuur vs begin jaar / oudste / vorige
-- Extra leesrechten (alleen-lezen) voor medewerkers met toegang tot het bedrijf op:
--   huos_pilot_organizations, huos_pilot_documents, huos_pilot_contracts en de bestanden
--   in bucket huos-pilot-private (bestanden alleen voor beoordelaar en beheerder).
-- Terugdraaien: zie onderaan.

-- 1. Toegang van medewerkers tot een klantbedrijf (zelfde bereikregels als bij leads)
create or replace function public.huos_staff_can_access_org(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case
      when p_org is null then false
      when s.role = 'admin' or s.scope = 'all' then true
      when s.scope = 'organization' then p_org::text = any (s.scope_values)
      when s.scope = 'assigned' then exists (select 1 from public.huos_beer_leads l
                                              where l.organization_id = p_org and l.assigned_to = s.user_id)
      when s.scope = 'region'   then exists (select 1 from public.huos_beer_leads l
                                              where l.organization_id = p_org and l.region = any (s.scope_values))
      else false end
    from public.huos_staff s
    where s.user_id = (select auth.uid()) and s.active), false)
$$;
revoke all on function public.huos_staff_can_access_org(uuid) from public, anon, authenticated;
grant execute on function public.huos_staff_can_access_org(uuid) to authenticated;

-- 2. Kostenregels
create table public.huos_cost_lines (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  category         text not null check (category in ('bier','frisdrank','wijn','gedistilleerd','food','groothandel',
                     'elektra','gas','water','afval','verzekeringen','telecom','muziekrechten','betaalverkeer',
                     'schoonmaak','huur','overig')),
  supplier         text not null check (length(btrim(supplier)) between 2 and 120),
  product          text check (product is null or length(btrim(product)) between 1 and 160),
  invoice_number   text check (invoice_number is null or length(invoice_number) <= 60),
  invoice_date     date,
  period_start     date not null,
  period_end       date not null,
  amount_excl_vat  numeric(12,2) not null check (amount_excl_vat >= 0 and amount_excl_vat < 10000000),
  quantity         numeric(12,3) check (quantity is null or quantity > 0),
  unit             text check (unit is null or length(btrim(unit)) between 1 and 40),
  document_id      uuid references public.huos_pilot_documents(id) on delete set null,
  contract_id      uuid references public.huos_pilot_contracts(id) on delete set null,
  note             text check (note is null or length(note) <= 1000),
  period_days      integer generated always as (period_end - period_start + 1) stored,
  monthly_amount   numeric(12,2) generated always as
                     (round(amount_excl_vat * 30.4375 / (period_end - period_start + 1), 2)) stored,
  unit_price       numeric(14,4) generated always as
                     (case when quantity is not null then round(amount_excl_vat / quantity, 4) end) stored,
  created_by       uuid not null default auth.uid() references auth.users(id),
  updated_by       uuid references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint huos_cost_lines_period_ok check (period_end >= period_start
                     and period_end - period_start <= 731 and period_start >= date '2015-01-01'),
  constraint huos_cost_lines_unit_with_qty check ((quantity is null) = (unit is null))
);
create index huos_cost_lines_org_key on public.huos_cost_lines
  (organization_id, category, lower(btrim(supplier)), lower(btrim(coalesce(product, ''))), period_end);
create index on public.huos_cost_lines (document_id);
create index on public.huos_cost_lines (contract_id);
comment on table public.huos_cost_lines is
  'HUOS Mijn kosten (intern): kostenregels per klantbedrijf, ingevoerd door medewerkers op basis van facturen. Niet zichtbaar voor de ondernemer. Bedragen excl. btw.';

-- 2a. Bewaking: invoerder vastleggen, bedrijf niet verplaatsen, document/contract moet bij hetzelfde bedrijf horen
create or replace function public.huos_cost_lines_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := (select auth.uid());
    new.created_at := now();
    new.updated_by := null;
  else
    if new.organization_id <> old.organization_id then
      raise exception 'Een kostenregel kan niet naar een ander bedrijf worden verplaatst';
    end if;
    new.created_by := old.created_by;
    new.created_at := old.created_at;
    new.updated_by := (select auth.uid());
  end if;
  new.updated_at := now();
  if new.created_by is null then
    raise exception 'Niet ingelogd';
  end if;
  if new.document_id is not null and not exists (
       select 1 from public.huos_pilot_documents d
       where d.id = new.document_id and d.organization_id = new.organization_id) then
    raise exception 'Document hoort niet bij dit bedrijf';
  end if;
  if new.contract_id is not null and not exists (
       select 1 from public.huos_pilot_contracts c
       where c.id = new.contract_id and c.organization_id = new.organization_id) then
    raise exception 'Contract hoort niet bij dit bedrijf';
  end if;
  return new;
end $$;
revoke all on function public.huos_cost_lines_guard() from public, anon, authenticated;
create trigger huos_cost_lines_guard before insert or update on public.huos_cost_lines
  for each row execute function public.huos_cost_lines_guard();

-- 3. Logboek (alleen toevoegen; verdwijnt alleen mee als het hele klantbedrijf wordt verwijderd)
create table public.huos_cost_line_audit (
  id               bigint generated always as identity primary key,
  cost_line_id     uuid not null,
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  action           text not null check (action in ('insert','update','delete')),
  actor_id         uuid,
  actor_role       text,
  old_row          jsonb,
  new_row          jsonb,
  created_at       timestamptz not null default now()
);
create index on public.huos_cost_line_audit (organization_id, created_at desc);
create index on public.huos_cost_line_audit (cost_line_id);

create or replace function public.huos_cost_audit_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- verwijderen mag alleen als gevolg van het verwijderen van het klantbedrijf (cascade)
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then return old; end if;
  raise exception 'Append-only tabel: % is niet toegestaan', tg_op;
end $$;
revoke all on function public.huos_cost_audit_guard() from public, anon, authenticated;
create trigger huos_cost_line_audit_append_only before update or delete on public.huos_cost_line_audit
  for each row execute function public.huos_cost_audit_guard();

create or replace function public.huos_cost_lines_log()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid := coalesce(new.organization_id, old.organization_id);
begin
  -- bij verwijderen van het hele klantbedrijf niets loggen (logboek gaat mee weg)
  if not exists (select 1 from public.huos_pilot_organizations o where o.id = v_org) then
    return null;
  end if;
  insert into public.huos_cost_line_audit (cost_line_id, organization_id, action, actor_id, actor_role, old_row, new_row)
  values (coalesce(new.id, old.id), v_org, lower(tg_op), (select auth.uid()), public.huos_staff_role(),
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return null;
end $$;
revoke all on function public.huos_cost_lines_log() from public, anon, authenticated;
create trigger huos_cost_lines_log after insert or update or delete on public.huos_cost_lines
  for each row execute function public.huos_cost_lines_log();

-- 4. RLS: alleen medewerkers met toegang tot het bedrijf; schrijven vanaf beoordelaar
alter table public.huos_cost_lines enable row level security;
alter table public.huos_cost_line_audit enable row level security;

create policy huos_cost_lines_staff_read on public.huos_cost_lines for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_cost_lines_staff_insert on public.huos_cost_lines for insert to authenticated
  with check (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_cost_lines_staff_update on public.huos_cost_lines for update to authenticated
  using (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id))
  with check (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_cost_lines_staff_delete on public.huos_cost_lines for delete to authenticated
  using (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_cost_line_audit_staff_read on public.huos_cost_line_audit for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));

revoke all on public.huos_cost_lines, public.huos_cost_line_audit from public, anon, authenticated;
grant select, insert, delete on public.huos_cost_lines to authenticated;
grant update (category, supplier, product, invoice_number, invoice_date, period_start, period_end,
              amount_excl_vat, quantity, unit, document_id, contract_id, note) on public.huos_cost_lines to authenticated;
grant select on public.huos_cost_line_audit to authenticated;

-- 5. Leesrechten medewerkers op klantgegevens die nodig zijn voor de invoer (alleen lezen)
create policy huos_pilot_org_staff_read on public.huos_pilot_organizations for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(id));
create policy huos_pilot_documents_staff_read on public.huos_pilot_documents for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_pilot_contracts_staff_read on public.huos_pilot_contracts for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_pilot_files_staff_read on storage.objects for select to authenticated
  using (bucket_id = 'huos-pilot-private'
         and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
         and public.huos_staff_has('reviewer')
         and public.huos_staff_can_access_org(((storage.foldername(name))[2])::uuid));

-- 6. Vergelijking per categorie + leverancier + product
--    Nieuwste factuur t.o.v. (a) eerste factuur van hetzelfde jaar, (b) oudste factuur, (c) vorige factuur.
--    Maatstaf: prijs per eenheid als beide regels dezelfde eenheid hebben, anders bedrag per maand.
--    Signaal: stijging >= 10% én >= € 50 per maand t.o.v. begin jaar (of oudste als er dit jaar geen eerdere is).
create view public.huos_cost_comparison with (security_invoker = true) as
with base as (
  select c.*,
         lower(btrim(c.supplier)) as sk, lower(btrim(coalesce(c.product, ''))) as pk,
         row_number() over w_desc as rn_desc,
         row_number() over w_asc  as rn_asc,
         count(*)     over (partition by c.organization_id, c.category, lower(btrim(c.supplier)), lower(btrim(coalesce(c.product, '')))) as n_lines
  from public.huos_cost_lines c
  window w_desc as (partition by c.organization_id, c.category, lower(btrim(c.supplier)), lower(btrim(coalesce(c.product, '')))
                    order by c.period_end desc, c.period_start desc, c.created_at desc),
         w_asc  as (partition by c.organization_id, c.category, lower(btrim(c.supplier)), lower(btrim(coalesce(c.product, '')))
                    order by c.period_end asc, c.period_start asc, c.created_at asc)
), pairs as (
  select l.organization_id, l.category, l.supplier, l.product, l.n_lines,
         l.id as latest_id, l.period_start as latest_start, l.period_end as latest_end,
         l.amount_excl_vat as latest_amount, l.monthly_amount as latest_monthly, l.unit_price as latest_unit_price, l.unit as latest_unit,
         y.id as ytd_id, y.period_start as ytd_start, y.period_end as ytd_end, y.monthly_amount as ytd_monthly, y.unit_price as ytd_unit_price, y.unit as ytd_unit,
         o.id as oldest_id, o.period_start as oldest_start, o.period_end as oldest_end, o.monthly_amount as oldest_monthly, o.unit_price as oldest_unit_price, o.unit as oldest_unit,
         p.id as prev_id, p.period_start as prev_start, p.period_end as prev_end, p.monthly_amount as prev_monthly, p.unit_price as prev_unit_price, p.unit as prev_unit
  from base l
  left join lateral (select b.* from base b
                     where b.organization_id = l.organization_id and b.category = l.category and b.sk = l.sk and b.pk = l.pk
                       and b.rn_desc > 1 and b.period_start >= date_trunc('year', l.period_end)::date
                     order by b.period_end, b.period_start, b.created_at limit 1) y on true
  left join lateral (select b.* from base b
                     where b.organization_id = l.organization_id and b.category = l.category and b.sk = l.sk and b.pk = l.pk
                       and b.rn_asc = 1 and b.rn_desc > 1) o on true
  left join lateral (select b.* from base b
                     where b.organization_id = l.organization_id and b.category = l.category and b.sk = l.sk and b.pk = l.pk
                       and b.rn_desc = 2) p on true
  where l.rn_desc = 1
), pct as (
  select pairs.*,
    case when ytd_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(ytd_unit) and ytd_unit_price > 0
           then round((latest_unit_price / ytd_unit_price - 1) * 100, 1)
         when ytd_monthly > 0 then round((latest_monthly / ytd_monthly - 1) * 100, 1) end as pct_since_year_start,
    case when ytd_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(ytd_unit) then 'unit_price' else 'monthly' end as basis_year_start,
    case when oldest_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(oldest_unit) and oldest_unit_price > 0
           then round((latest_unit_price / oldest_unit_price - 1) * 100, 1)
         when oldest_monthly > 0 then round((latest_monthly / oldest_monthly - 1) * 100, 1) end as pct_since_oldest,
    case when oldest_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(oldest_unit) then 'unit_price' else 'monthly' end as basis_oldest,
    case when prev_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(prev_unit) and prev_unit_price > 0
           then round((latest_unit_price / prev_unit_price - 1) * 100, 1)
         when prev_monthly > 0 then round((latest_monthly / prev_monthly - 1) * 100, 1) end as pct_since_previous
  from pairs
)
select pct.*,
  -- referentie voor het signaal: begin van het jaar, anders de oudste factuur
  case when pct_since_year_start is not null then 'year_start' when pct_since_oldest is not null then 'oldest' end as signal_reference,
  round(latest_monthly - latest_monthly / nullif(1 + coalesce(pct_since_year_start, pct_since_oldest) / 100.0, 0), 2) as extra_per_month,
  coalesce(coalesce(pct_since_year_start, pct_since_oldest) >= 10
           and latest_monthly - latest_monthly / nullif(1 + coalesce(pct_since_year_start, pct_since_oldest) / 100.0, 0) >= 50, false) as is_signal
from pct;
comment on view public.huos_cost_comparison is
  'HUOS Mijn kosten (intern): nieuwste kostenregel per categorie/leverancier/product vergeleken met begin jaar, oudste en vorige regel. Drempel signaal: >=10% en >=50 euro per maand.';
revoke all on public.huos_cost_comparison from public, anon, authenticated;
grant select on public.huos_cost_comparison to authenticated;

-- Terugdraaien (alleen na akkoord; verwijdert ingevoerde kostenregels):
--   drop view public.huos_cost_comparison;
--   drop policy huos_pilot_files_staff_read on storage.objects;
--   drop policy huos_pilot_contracts_staff_read on public.huos_pilot_contracts;
--   drop policy huos_pilot_documents_staff_read on public.huos_pilot_documents;
--   drop policy huos_pilot_org_staff_read on public.huos_pilot_organizations;
--   drop table public.huos_cost_line_audit; drop table public.huos_cost_lines;
--   drop function public.huos_cost_lines_log(); drop function public.huos_cost_audit_guard();
--   drop function public.huos_cost_lines_guard(); drop function public.huos_staff_can_access_org(uuid);

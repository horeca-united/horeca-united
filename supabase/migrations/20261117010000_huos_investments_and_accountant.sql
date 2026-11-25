-- HUOS: investeringen (KIA-inzicht) + e-mailadres van de boekhouder
-- 1) Tabel public.huos_investments: per bedrijfsmiddel omschrijving, bedrag excl. btw, datum, optioneel gekoppeld document.
--    Eigenaar van het bedrijf: lezen/toevoegen/wijzigen/verwijderen van eigen investeringen.
--    Medewerkers (reviewer+, met toegang tot het bedrijf): idem; viewer: alleen lezen.
-- 2) Append-only logboek public.huos_investment_audit (wie/wat/wanneer, klant of medewerker).
-- 3) Kolom public.huos_pilot_organizations.accountant_email (door de eigenaar zelf in te vullen).
-- Raakt geen bestaande gegevens. Terugdraaien:
--   drop table public.huos_investment_audit; drop table public.huos_investments;
--   drop function public.huos_investments_log(); alter table public.huos_pilot_organizations drop column accountant_email;

create table public.huos_investments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  document_id uuid references public.huos_pilot_documents(id) on delete set null,
  description text not null check (length(btrim(description)) between 2 and 200),
  amount_excl_vat numeric(12,2) not null check (amount_excl_vat >= 0 and amount_excl_vat < 10000000),
  invested_on date not null check (invested_on >= date '2015-01-01' and invested_on <= current_date + 366),
  note text check (note is null or length(note) <= 1000),
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index huos_investments_org_idx on public.huos_investments (organization_id, invested_on);
create index huos_investments_doc_idx on public.huos_investments (document_id);

alter table public.huos_investments enable row level security;

create policy huos_investments_owner_select on public.huos_investments for select to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o where o.id = organization_id and o.owner_id = (select auth.uid())));
create policy huos_investments_owner_insert on public.huos_investments for insert to authenticated
  with check (created_by = (select auth.uid())
    and exists (select 1 from public.huos_pilot_organizations o where o.id = organization_id and o.owner_id = (select auth.uid()))
    and (document_id is null or exists (select 1 from public.huos_pilot_documents d where d.id = document_id and d.organization_id = huos_investments.organization_id)));
create policy huos_investments_owner_update on public.huos_investments for update to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o where o.id = organization_id and o.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.huos_pilot_organizations o where o.id = organization_id and o.owner_id = (select auth.uid()))
    and (document_id is null or exists (select 1 from public.huos_pilot_documents d where d.id = document_id and d.organization_id = huos_investments.organization_id)));
create policy huos_investments_owner_delete on public.huos_investments for delete to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o where o.id = organization_id and o.owner_id = (select auth.uid())));

create policy huos_investments_staff_read on public.huos_investments for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_investments_staff_insert on public.huos_investments for insert to authenticated
  with check (created_by = (select auth.uid()) and public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id)
    and (document_id is null or exists (select 1 from public.huos_pilot_documents d where d.id = document_id and d.organization_id = huos_investments.organization_id)));
create policy huos_investments_staff_update on public.huos_investments for update to authenticated
  using (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id))
  with check (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id)
    and (document_id is null or exists (select 1 from public.huos_pilot_documents d where d.id = document_id and d.organization_id = huos_investments.organization_id)));
create policy huos_investments_staff_delete on public.huos_investments for delete to authenticated
  using (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(organization_id));

revoke all on public.huos_investments from public, anon, authenticated;
grant select, delete on public.huos_investments to authenticated;
grant insert (organization_id, document_id, description, amount_excl_vat, invested_on, note) on public.huos_investments to authenticated;
grant update (document_id, description, amount_excl_vat, invested_on, note) on public.huos_investments to authenticated;

create or replace function public.huos_investments_touch() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;
create trigger huos_investments_touch before update on public.huos_investments for each row execute function public.huos_investments_touch();

-- logboek (append-only)
create table public.huos_investment_audit (
  id bigint generated always as identity primary key,
  investment_id uuid not null,
  organization_id uuid not null,
  action text not null check (action in ('insert','update','delete')),
  actor_id uuid,
  actor_kind text not null check (actor_kind in ('klant','medewerker','systeem')),
  actor_email text,
  changes jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index huos_investment_audit_org_idx on public.huos_investment_audit (organization_id, created_at desc);
alter table public.huos_investment_audit enable row level security;
create policy huos_investment_audit_staff_read on public.huos_investment_audit for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
revoke all on public.huos_investment_audit from public, anon, authenticated;
grant select on public.huos_investment_audit to authenticated;
create trigger huos_investment_audit_guard before update or delete on public.huos_investment_audit
  for each row execute function public.huos_cost_audit_guard();

create or replace function public.huos_investments_log() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_org uuid := coalesce(new.organization_id, old.organization_id); v_uid uuid := (select auth.uid());
        v_kind text; v_email text; v_changes jsonb := '{}'::jsonb; k text; o jsonb; n jsonb;
begin
  if not exists (select 1 from public.huos_pilot_organizations x where x.id = v_org) then return null; end if;
  v_kind := case when v_uid is null then 'systeem' when public.huos_staff_role() is not null then 'medewerker' else 'klant' end;
  if v_uid is not null then select u.email::text into v_email from auth.users u where u.id = v_uid; end if;
  if tg_op = 'UPDATE' then
    o := to_jsonb(old) - array['updated_at','created_at','created_by','organization_id','id'];
    n := to_jsonb(new) - array['updated_at','created_at','created_by','organization_id','id'];
    for k in select jsonb_object_keys(n) loop
      if (o -> k) is distinct from (n -> k) then v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(o -> k, n -> k)); end if;
    end loop;
    if v_changes = '{}'::jsonb then return null; end if;
  elsif tg_op = 'DELETE' then
    v_changes := to_jsonb(old) - array['updated_at','created_by','organization_id'];
  else
    v_changes := jsonb_build_object('description', new.description, 'amount_excl_vat', new.amount_excl_vat, 'invested_on', new.invested_on);
  end if;
  insert into public.huos_investment_audit (investment_id, organization_id, action, actor_id, actor_kind, actor_email, changes)
  values (coalesce(new.id, old.id), v_org, lower(tg_op), v_uid, v_kind, v_email, v_changes);
  return null;
end $$;
revoke all on function public.huos_investments_log() from public, anon, authenticated;
create trigger huos_investments_audit after insert or update or delete on public.huos_investments
  for each row execute function public.huos_investments_log();

-- e-mailadres boekhouder (eigenaar vult zelf in)
alter table public.huos_pilot_organizations
  add column accountant_email text
  constraint huos_pilot_org_accountant_email_check check (accountant_email is null or (length(accountant_email) <= 254 and accountant_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'));
grant update (accountant_email) on public.huos_pilot_organizations to authenticated;
comment on column public.huos_pilot_organizations.accountant_email is 'E-mailadres van de boekhouder; door de ondernemer zelf ingevuld, gebruikt voor "Mail naar mijn boekhouder".';

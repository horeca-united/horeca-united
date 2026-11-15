-- HUOS 2.0 — Medewerker zet een contract-document bij Mijn contracten van de klant
-- Nieuw / gewijzigd:
--   huos_pilot_contracts.added_by_staff     (boolean, standaard false) — klant ziet "Toegevoegd door Horeca United"
--   huos_staff_actions                      logboek van medewerkeracties in klantomgevingen (alleen toevoegen)
--   huos_staff_add_contract(...)            RPC: beoordelaar/beheerder met toegang tot het bedrijf
-- created_by van het contract wordt de eigenaar van de klantomgeving (niet de medewerker), zodat het contract
-- nooit verdwijnt als een medewerkeraccount wordt verwijderd; wie het toevoegde staat in huos_staff_actions.
-- Raakt geen bestaande gegevens (nieuwe kolom met standaardwaarde false).
-- Terugdraaien: drop function public.huos_staff_add_contract(uuid,uuid,text,text,text,date,date,boolean,smallint,text,boolean,boolean,smallint,numeric,text);
--               drop table public.huos_staff_actions; alter table public.huos_pilot_contracts drop column added_by_staff;

alter table public.huos_pilot_contracts add column added_by_staff boolean not null default false;

create table public.huos_staff_actions (
  id               bigint generated always as identity primary key,
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  actor_id         uuid,
  actor_role       text,
  action           text not null check (length(action) <= 60),
  entity           text not null check (length(entity) <= 60),
  entity_id        uuid,
  details          jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);
create index on public.huos_staff_actions (organization_id, created_at desc);
create trigger huos_staff_actions_append_only before update or delete on public.huos_staff_actions
  for each row execute function public.huos_cost_audit_guard();
alter table public.huos_staff_actions enable row level security;
create policy huos_staff_actions_staff_read on public.huos_staff_actions for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
revoke all on public.huos_staff_actions from public, anon, authenticated;
grant select on public.huos_staff_actions to authenticated;

create or replace function public.huos_staff_add_contract(p_org uuid, p_document uuid, p_category text, p_supplier text,
  p_description text, p_start date, p_end date, p_dates_estimated boolean, p_notice_months smallint, p_notice_text text,
  p_flexible boolean, p_auto_renews boolean, p_renewal_months smallint, p_amount numeric, p_amount_period text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_owner uuid;
begin
  if not (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(p_org)) then
    raise exception 'Geen rechten om contracten toe te voegen voor dit bedrijf';
  end if;
  select owner_id into v_owner from public.huos_pilot_organizations where id = p_org;
  if v_owner is null then raise exception 'Bedrijf niet gevonden'; end if;
  if p_document is not null then
    if not exists (select 1 from public.huos_pilot_documents d where d.id = p_document and d.organization_id = p_org) then
      raise exception 'Document hoort niet bij dit bedrijf';
    end if;
    if exists (select 1 from public.huos_pilot_contracts c where c.document_id = p_document) then
      raise exception 'Dit document is al aan een contract gekoppeld';
    end if;
  end if;
  insert into public.huos_pilot_contracts (organization_id, created_by, category, supplier, description, start_date, end_date,
    dates_estimated, notice_period_months, notice_period_text, flexible_cancellation, auto_renews, renewal_months,
    amount, amount_period, document_id, added_by_staff)
  values (p_org, v_owner, p_category, btrim(p_supplier), nullif(btrim(p_description),''), p_start, p_end,
    coalesce(p_dates_estimated,false), p_notice_months, nullif(btrim(p_notice_text),''), coalesce(p_flexible,false),
    p_auto_renews, p_renewal_months, p_amount, p_amount_period, p_document, true)
  returning id into v_id;
  insert into public.huos_staff_actions (organization_id, actor_id, actor_role, action, entity, entity_id, details)
  values (p_org, (select auth.uid()), public.huos_staff_role(), 'contract_added', 'huos_pilot_contracts', v_id,
    jsonb_build_object('document_id', p_document, 'supplier', p_supplier, 'category', p_category));
  return v_id;
end $$;
revoke all on function public.huos_staff_add_contract(uuid,uuid,text,text,text,date,date,boolean,smallint,text,boolean,boolean,smallint,numeric,text) from public, anon, authenticated;
grant execute on function public.huos_staff_add_contract(uuid,uuid,text,text,text,date,date,boolean,smallint,text,boolean,boolean,smallint,numeric,text) to authenticated;

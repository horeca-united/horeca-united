-- HUOS 2.0 — Actie / tijdelijke korting bij contracten
-- Gewijzigd:
--   huos_pilot_contracts: + promo_end_date (laatste dag actieprijs), + amount_after_promo (bedrag na de actie)
--   huos_staff_add_contract: twee extra (optionele) parameters voor deze velden
-- Raakt geen bestaande gegevens (nieuwe kolommen zijn leeg).
-- Terugdraaien: kolommen verwijderen en de functie terugzetten uit 20261115020000_huos_staff_add_contract.sql.

alter table public.huos_pilot_contracts
  add column promo_end_date date,
  add column amount_after_promo numeric(12,2) check (amount_after_promo is null or amount_after_promo >= 0);

drop function public.huos_staff_add_contract(uuid,uuid,text,text,text,date,date,boolean,smallint,text,boolean,boolean,smallint,numeric,text);

create or replace function public.huos_staff_add_contract(p_org uuid, p_document uuid, p_category text, p_supplier text,
  p_description text, p_start date, p_end date, p_dates_estimated boolean, p_notice_months smallint, p_notice_text text,
  p_flexible boolean, p_auto_renews boolean, p_renewal_months smallint, p_amount numeric, p_amount_period text,
  p_amount_note text default null, p_promo_end date default null, p_amount_after_promo numeric default null)
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
    amount, amount_period, amount_note, promo_end_date, amount_after_promo, document_id, added_by_staff)
  values (p_org, v_owner, p_category, btrim(p_supplier), nullif(btrim(p_description),''), p_start, p_end,
    coalesce(p_dates_estimated,false), p_notice_months, nullif(btrim(p_notice_text),''), coalesce(p_flexible,false),
    p_auto_renews, p_renewal_months, p_amount, p_amount_period, nullif(btrim(p_amount_note),''), p_promo_end, p_amount_after_promo,
    p_document, true)
  returning id into v_id;
  insert into public.huos_staff_actions (organization_id, actor_id, actor_role, action, entity, entity_id, details)
  values (p_org, (select auth.uid()), public.huos_staff_role(), 'contract_added', 'huos_pilot_contracts', v_id,
    jsonb_build_object('document_id', p_document, 'supplier', p_supplier, 'category', p_category));
  return v_id;
end $$;
revoke all on function public.huos_staff_add_contract(uuid,uuid,text,text,text,date,date,boolean,smallint,text,boolean,boolean,smallint,numeric,text,text,date,numeric) from public, anon, authenticated;
grant execute on function public.huos_staff_add_contract(uuid,uuid,text,text,text,date,date,boolean,smallint,text,boolean,boolean,smallint,numeric,text,text,date,numeric) to authenticated;

-- HUOS 2.0 — Logboek contracten: vastleggen wie (e-mailadres) de wijziging deed + aanvulling met terugwerkende kracht
-- Gewijzigd:
--   huos_contract_audit: + actor_email (momentopname van het e-mailadres van de ondernemer of medewerker)
--   huos_pilot_contracts_log(): vult actor_email
--   Aanvulling: contracten die een medewerker toevoegde vóórdat het logboek bestond, krijgen alsnog een
--   'toegevoegd'-regel op basis van huos_staff_actions (met oorspronkelijk tijdstip).
-- Alleen medewerkers kunnen het logboek lezen. Raakt geen klantgegevens.
-- Terugdraaien: functie terugzetten uit 20261115040000_huos_contract_audit.sql; kolom actor_email laten staan of verwijderen.

alter table public.huos_contract_audit add column actor_email text;

create or replace function public.huos_pilot_contracts_log()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid := coalesce(new.organization_id, old.organization_id);
        v_uid uuid := (select auth.uid()); v_kind text; v_changes jsonb := '{}'::jsonb; k text;
        o jsonb; n jsonb; v_email text;
begin
  if not exists (select 1 from public.huos_pilot_organizations x where x.id = v_org) then return null; end if;
  v_kind := case when v_uid is null then 'systeem' when public.huos_staff_role() is not null then 'medewerker' else 'klant' end;
  if v_uid is not null then select u.email::text into v_email from auth.users u where u.id = v_uid; end if;
  if tg_op = 'UPDATE' then
    o := to_jsonb(old) - array['updated_at','cancel_by_date','created_at','created_by','organization_id','id'];
    n := to_jsonb(new) - array['updated_at','cancel_by_date','created_at','created_by','organization_id','id'];
    for k in select jsonb_object_keys(n) loop
      if (o -> k) is distinct from (n -> k) then
        v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(o -> k, n -> k));
      end if;
    end loop;
    if v_changes = '{}'::jsonb then return null; end if;
  elsif tg_op = 'DELETE' then
    v_changes := to_jsonb(old) - array['updated_at','cancel_by_date','created_by','organization_id'];
  else
    v_changes := jsonb_build_object('category', new.category, 'end_date', new.end_date, 'added_by_staff', new.added_by_staff);
  end if;
  insert into public.huos_contract_audit (contract_id, organization_id, action, actor_id, actor_kind, actor_email, supplier, changes)
  values (coalesce(new.id, old.id), v_org, lower(tg_op), v_uid, v_kind, v_email, coalesce(new.supplier, old.supplier), v_changes);
  return null;
end $$;
revoke all on function public.huos_pilot_contracts_log() from public, anon, authenticated;

insert into public.huos_contract_audit (contract_id, organization_id, action, actor_id, actor_kind, actor_email, supplier, changes, created_at)
select a.entity_id, a.organization_id, 'insert', a.actor_id, 'medewerker', (select u.email::text from auth.users u where u.id = a.actor_id),
       a.details->>'supplier', jsonb_build_object('category', a.details->>'category', 'aangevuld', true), a.created_at
from public.huos_staff_actions a
where a.action = 'contract_added'
  and exists (select 1 from public.huos_pilot_contracts c where c.id = a.entity_id)
  and not exists (select 1 from public.huos_contract_audit x where x.contract_id = a.entity_id and x.action = 'insert');

-- Eenmalig het nieuwe veld actor_email invullen voor bestaande regels (alleen dit lege veld; verder niets gewijzigd).
alter table public.huos_contract_audit disable trigger huos_contract_audit_append_only;
update public.huos_contract_audit a set actor_email = u.email::text from auth.users u where u.id = a.actor_id and a.actor_email is null;
alter table public.huos_contract_audit enable trigger huos_contract_audit_append_only;

-- HUOS 2.0 — Logboek van wijzigingen aan contracten (klant én medewerker)
-- Nieuw:
--   huos_contract_audit         per toevoeging/wijziging/verwijdering: wie (klant/medewerker), welke velden oud → nieuw
--   trigger op huos_pilot_contracts (na insert/update/delete)
-- Alleen medewerkers met toegang tot het bedrijf kunnen het logboek lezen; niemand kan het wijzigen of wissen
-- (verdwijnt alleen mee als het hele klantbedrijf wordt verwijderd). Raakt geen bestaande gegevens.
-- Terugdraaien: drop trigger huos_pilot_contracts_audit on public.huos_pilot_contracts;
--               drop function public.huos_pilot_contracts_log(); drop table public.huos_contract_audit;

create table public.huos_contract_audit (
  id               bigint generated always as identity primary key,
  contract_id      uuid not null,
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  action           text not null check (action in ('insert','update','delete')),
  actor_id         uuid,
  actor_kind       text not null check (actor_kind in ('klant','medewerker','systeem')),
  supplier         text,
  changes          jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);
create index on public.huos_contract_audit (organization_id, created_at desc);
create index on public.huos_contract_audit (contract_id);
create trigger huos_contract_audit_append_only before update or delete on public.huos_contract_audit
  for each row execute function public.huos_cost_audit_guard();

create or replace function public.huos_pilot_contracts_log()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid := coalesce(new.organization_id, old.organization_id);
        v_uid uuid := (select auth.uid()); v_kind text; v_changes jsonb := '{}'::jsonb; k text;
        o jsonb; n jsonb;
begin
  if not exists (select 1 from public.huos_pilot_organizations x where x.id = v_org) then return null; end if;  -- hele bedrijf verwijderd
  v_kind := case when v_uid is null then 'systeem' when public.huos_staff_role() is not null then 'medewerker' else 'klant' end;
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
  insert into public.huos_contract_audit (contract_id, organization_id, action, actor_id, actor_kind, supplier, changes)
  values (coalesce(new.id, old.id), v_org, lower(tg_op), v_uid, v_kind, coalesce(new.supplier, old.supplier), v_changes);
  return null;
end $$;
revoke all on function public.huos_pilot_contracts_log() from public, anon, authenticated;
create trigger huos_pilot_contracts_audit after insert or update or delete on public.huos_pilot_contracts
  for each row execute function public.huos_pilot_contracts_log();

alter table public.huos_contract_audit enable row level security;
create policy huos_contract_audit_staff_read on public.huos_contract_audit for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
revoke all on public.huos_contract_audit from public, anon, authenticated;
grant select on public.huos_contract_audit to authenticated;

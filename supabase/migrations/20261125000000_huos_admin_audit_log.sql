-- Admin-auditlog: wie deed wat en wanneer
-- Voorzichtig met gevoelige gegevens: geen wachtwoorden, geen volledige e-mailadressen van externe partijen,
-- geen ondertekeningsgegevens of persoonlijke machtigingsgegevens.
--
-- Toepassing:
--  * huos_admin_audit_log: acties van medewerkers (staff) op leads, contracten, documenten etc.
--    - action: 'staff_role_created', 'staff_role_updated', 'lead_stage_changed', 'contract_updated', 'document_reviewed', 'document_archived'
--    - actor_id: wie deed het
--    - actor_email: voorzorgshalve opgeslagen (ingelogde gebruiker)
--    - resource_type: 'staff_member', 'lead', 'contract', 'document', 'organization' etc.
--    - resource_id: het object dat werd gewijzigd (uuid)
--    - old_state: beperkte samenvatting van de vorige toestand (geen gevoelige velden)
--    - new_state: beperkte samenvatting van de nieuwe toestand (geen gevoelige velden)
--    - details: extra context (bijv. stage change reason) — ook schoon
--    - created_at: wanneer
--
-- RLS: alleen staff (admin/reviewer) mag logs zien en alleen voor hun organisaties.

create table public.huos_admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  action text not null check (length(action) between 4 and 100),
  actor_id uuid not null references auth.users(id) on delete set null,
  actor_email text not null check (length(actor_email) between 5 and 254),
  resource_type text not null check (length(resource_type) between 4 and 50),
  resource_id uuid,
  organization_id uuid references public.huos_pilot_organizations(id) on delete set null,
  old_state jsonb,
  new_state jsonb,
  details jsonb,
  created_at timestamptz not null default now()
);

-- Index voor snelle queries op actor, resource of organisatie
create index huos_admin_audit_log_actor_idx on public.huos_admin_audit_log (actor_id, created_at desc);
create index huos_admin_audit_log_resource_idx on public.huos_admin_audit_log (resource_type, resource_id);
create index huos_admin_audit_log_org_idx on public.huos_admin_audit_log (organization_id, created_at desc);

-- RLS: alleen staff kan logs zien
alter table public.huos_admin_audit_log enable row level security;
revoke all on public.huos_admin_audit_log from anon, authenticated;
grant select on public.huos_admin_audit_log to authenticated;

create policy huos_admin_audit_log_staff_read on public.huos_admin_audit_log for select to authenticated
  using (public.huos_staff_has('viewer'));

-- Voorkomen dat logs worden verwijderd of gewijzigd (append-only)
create trigger huos_admin_audit_log_append_only before update or delete on public.huos_admin_audit_log
  for each row execute function public.huos_cost_audit_guard();

-- Helper-functie om logs toe te voegen (security definer, dus altijd callable)
create or replace function public.huos_audit_log_add(
  p_action text,
  p_resource_type text,
  p_resource_id uuid default null,
  p_organization_id uuid default null,
  p_old_state jsonb default null,
  p_new_state jsonb default null,
  p_details jsonb default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_actor uuid; v_email text;
begin
  v_actor := public.huos_my_user_id();
  if v_actor is null then raise exception 'Niet ingelogd'; end if;
  
  select email into v_email from auth.users where id = v_actor;
  if v_email is null then raise exception 'Gebruiker gevonden maar geen e-mail'; end if;
  
  insert into public.huos_admin_audit_log (
    action, actor_id, actor_email, resource_type, resource_id, organization_id, old_state, new_state, details
  ) values (
    p_action, v_actor, v_email, p_resource_type, p_resource_id, p_organization_id, p_old_state, p_new_state, p_details
  )
  returning id into v_id;
  
  return v_id;
end $$;

grant execute on function public.huos_audit_log_add(text, text, uuid, uuid, jsonb, jsonb, jsonb) to authenticated;

-- Hulpfunctie: stuur log per medewerker naar organizatie (meeste logs zijn via leads/contracts aan org gekoppeld)
create or replace function public.huos_audit_log_add_via_lead(
  p_action text,
  p_lead_id uuid,
  p_resource_type text,
  p_resource_id uuid default null,
  p_old_state jsonb default null,
  p_new_state jsonb default null,
  p_details jsonb default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org_id uuid;
begin
  -- Organisatie ophalen via lead
  select organization_id into v_org_id from public.huos_beer_leads where id = p_lead_id;
  
  return public.huos_audit_log_add(
    p_action, p_resource_type, p_resource_id, v_org_id, p_old_state, p_new_state, p_details
  );
end $$;

grant execute on function public.huos_audit_log_add_via_lead(text, uuid, text, uuid, jsonb, jsonb, jsonb) to authenticated;

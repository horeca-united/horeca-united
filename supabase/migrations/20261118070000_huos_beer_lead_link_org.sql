-- Website-bierscan (lead) koppelen aan een pilotklant.
--
-- Wat verandert:
--  * huos_beer_leads.organization_id krijgt een foreign key naar huos_pilot_organizations (on delete set null).
--    Nu nog bij geen enkele lead ingevuld.
--  * huos_beer_lead_link_org(lead, org): admin koppelt een lead aan een pilotklant. Heeft de lead een lopende
--    machtiging en de klant nog geen eigen lopende machtiging, dan gaat de machtiging mee. Gelogd in de tijdlijn.
--  * huos_beer_link_suggestions(): voorstellen voor koppelingen op basis van hetzelfde e-mailadres
--    (website-inzending ↔ inlogaccount van de pilotklant). Alleen voor medewerkers met toegang tot beide.
-- Rollback: drop function huos_beer_link_suggestions(), huos_beer_lead_link_org(uuid,uuid);
--           alter table huos_beer_leads drop constraint huos_beer_leads_organization_id_fkey;
--           update huos_beer_leads set organization_id = null (alleen als koppelingen ongedaan moeten).

alter table public.huos_beer_leads
  add constraint huos_beer_leads_organization_id_fkey foreign key (organization_id)
  references public.huos_pilot_organizations(id) on delete set null;
create index if not exists huos_beer_leads_org_idx on public.huos_beer_leads (organization_id);

create or replace function public.huos_beer_lead_link_org(p_lead uuid, p_org uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_old uuid; v_m record; v_moved boolean := false; v_reason text := null;
begin
  if not public.huos_staff_has('admin') or not public.huos_staff_can_access_lead(p_lead) or not public.huos_staff_can_access_org(p_org) then
    raise exception 'Niet bevoegd';
  end if;
  select organization_id into v_old from public.huos_beer_leads where id = p_lead for update;
  if not found then raise exception 'Onbekende lead'; end if;
  if v_old is not null and v_old <> p_org then raise exception 'Deze lead is al aan een andere pilotklant gekoppeld'; end if;
  update public.huos_beer_leads set organization_id = p_org where id = p_lead;

  select * into v_m from public.huos_beer_mandates where lead_id = p_lead and status in ('pending','verified') for update;
  if v_m.id is not null then
    if v_m.organization_id = p_org then v_moved := true;
    elsif exists (select 1 from public.huos_beer_mandates where organization_id = p_org and status in ('pending','verified') and id <> v_m.id) then
      v_reason := 'Klant heeft al een eigen machtiging; de machtiging uit de bierscan blijft bij de lead.';
    else
      update public.huos_beer_mandates set organization_id = p_org where id = v_m.id;
      v_moved := true;
    end if;
  end if;
  perform public.huos_beer_log(p_lead, 'lead_linked_org', 'organization', p_org::text,
    jsonb_build_object('mandate_linked', v_moved, 'note', v_reason));
  return jsonb_build_object('mandate_linked', v_moved, 'note', v_reason);
end $$;

create or replace function public.huos_beer_link_suggestions()
returns table (lead_id uuid, organization_id uuid)
language sql stable security definer set search_path = '' as $$
  select l.id, o.id
  from public.huos_beer_leads l
  join public.huos_beer_intake_submissions s on s.id = l.submission_id
  join auth.users u on lower(u.email) = lower(btrim(s.email))
  join public.huos_pilot_organizations o on o.owner_id = u.id
  where l.organization_id is null and l.erased_at is null
    and public.huos_staff_has('reviewer')
    and public.huos_staff_can_access_lead(l.id) and public.huos_staff_can_access_org(o.id)
$$;

revoke all on function public.huos_beer_lead_link_org(uuid,uuid) from public, anon;
revoke all on function public.huos_beer_link_suggestions() from public, anon;
grant execute on function public.huos_beer_lead_link_org(uuid,uuid) to authenticated;
grant execute on function public.huos_beer_link_suggestions() to authenticated;

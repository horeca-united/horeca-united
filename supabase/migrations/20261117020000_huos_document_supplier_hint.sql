-- HUOS: leverancier automatisch herkennen bij upload (label bij het document)
-- 1) Kolom public.huos_pilot_documents.supplier_hint: door de browser bij het uploaden uit de PDF gehaalde leveranciersnaam.
--    Alleen een label; geen bedragen. Verwerking in beheer (kostenregel/contract) blijft leidend.
-- 2) RPC public.huos_set_document_supplier(p_doc, p_supplier): eigenaar van het bedrijf of medewerker (reviewer+) zet het label.
-- 3) public.huos_my_document_suppliers(): valt terug op het label als er nog geen kostenregel/contract is.
-- Raakt geen bestaande gegevens. Terugdraaien: functie huos_set_document_supplier verwijderen, kolom supplier_hint verwijderen,
--   huos_my_document_suppliers terugzetten naar 20261116090000.

alter table public.huos_pilot_documents
  add column supplier_hint text check (supplier_hint is null or length(btrim(supplier_hint)) between 2 and 120);
grant select (supplier_hint) on public.huos_pilot_documents to authenticated;

create or replace function public.huos_set_document_supplier(p_doc uuid, p_supplier text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_uid uuid := (select auth.uid()); v_sup text := nullif(btrim(left(coalesce(p_supplier,''), 120)), '');
begin
  select d.organization_id into v_org from public.huos_pilot_documents d where d.id = p_doc;
  if v_org is null then raise exception 'Document niet gevonden'; end if;
  if not (exists (select 1 from public.huos_pilot_organizations o where o.id = v_org and o.owner_id = v_uid)
          or (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(v_org))) then
    raise exception 'Geen rechten';
  end if;
  if v_sup is not null and length(v_sup) < 2 then v_sup := null; end if;
  update public.huos_pilot_documents set supplier_hint = v_sup where id = p_doc;
end $$;
revoke all on function public.huos_set_document_supplier(uuid, text) from public, anon;
grant execute on function public.huos_set_document_supplier(uuid, text) to authenticated;

create or replace function public.huos_my_document_suppliers()
returns table (document_id uuid, supplier text)
language sql stable security definer set search_path = ''
as $$
  select d.id, coalesce(s.suppliers, d.supplier_hint)
  from public.huos_pilot_documents d
  join public.huos_pilot_organizations o on o.id = d.organization_id and o.owner_id = (select auth.uid())
  left join lateral (
    select string_agg(distinct x.supplier, ', ' order by x.supplier) as suppliers from (
      select btrim(l.supplier) as supplier from public.huos_cost_lines l where l.document_id = d.id
      union
      select btrim(c.supplier) from public.huos_pilot_contracts c where c.document_id = d.id and c.organization_id = d.organization_id
    ) x where x.supplier is not null and x.supplier <> ''
  ) s on true
  where coalesce(s.suppliers, d.supplier_hint) is not null;
$$;
revoke all on function public.huos_my_document_suppliers() from public, anon;
grant execute on function public.huos_my_document_suppliers() to authenticated;

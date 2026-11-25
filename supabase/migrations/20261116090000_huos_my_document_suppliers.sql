-- HUOS klantzijde: per eigen document de naam van de leverancier tonen.
-- Geeft alleen documentnummer + leveranciersnaam terug (uit gekoppelde kostenregels en contracten),
-- uitsluitend voor documenten van bedrijven waarvan de ingelogde gebruiker eigenaar is.
-- Bedragen, kostenregels en adviezen blijven onzichtbaar voor de klant.
-- Raakt: geen bestaande tabellen of policies; alleen deze nieuwe functie.
-- Terugdraaien: drop function public.huos_my_document_suppliers();

create or replace function public.huos_my_document_suppliers()
returns table (document_id uuid, supplier text)
language sql
stable
security definer
set search_path = ''
as $$
  select d.id, string_agg(distinct s.supplier, ', ' order by s.supplier)
  from public.huos_pilot_documents d
  join public.huos_pilot_organizations o on o.id = d.organization_id and o.owner_id = (select auth.uid())
  join lateral (
    select btrim(l.supplier) as supplier from public.huos_cost_lines l where l.document_id = d.id
    union
    select btrim(c.supplier) from public.huos_pilot_contracts c where c.document_id = d.id and c.organization_id = d.organization_id
  ) s on s.supplier is not null and s.supplier <> ''
  group by d.id;
$$;

comment on function public.huos_my_document_suppliers() is
  'HUOS klant: leveranciersnaam per eigen document (alleen eigenaar van het bedrijf; geen bedragen).';

revoke all on function public.huos_my_document_suppliers() from public, anon;
grant execute on function public.huos_my_document_suppliers() to authenticated;

-- HUOS: dubbele documenten herkennen op inhoud (vingerafdruk), niet op bestandsnaam
-- 1) Kolom public.huos_pilot_documents.content_hash: SHA-256 van het bestand (in de browser berekend). Geen inhoud, alleen de code.
-- 2) RPC public.huos_set_document_hash(p_doc, p_hash): eigenaar of medewerker (reviewer+) vult de code aan voor bestaande documenten
--    (alleen als die nog leeg is).
-- Raakt geen bestaande gegevens. Terugdraaien: functie verwijderen, index en kolom content_hash verwijderen.

alter table public.huos_pilot_documents
  add column content_hash text check (content_hash is null or content_hash ~ '^[0-9a-f]{64}$');
create index huos_pilot_documents_hash_idx on public.huos_pilot_documents (organization_id, content_hash);
grant select (content_hash), insert (content_hash) on public.huos_pilot_documents to authenticated;

create or replace function public.huos_set_document_hash(p_doc uuid, p_hash text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_uid uuid := (select auth.uid()); v_hash text := lower(btrim(coalesce(p_hash, '')));
begin
  if v_hash !~ '^[0-9a-f]{64}$' then raise exception 'Ongeldige code'; end if;
  select d.organization_id into v_org from public.huos_pilot_documents d where d.id = p_doc;
  if v_org is null then raise exception 'Document niet gevonden'; end if;
  if not (exists (select 1 from public.huos_pilot_organizations o where o.id = v_org and o.owner_id = v_uid)
          or (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(v_org))) then
    raise exception 'Geen rechten';
  end if;
  update public.huos_pilot_documents set content_hash = v_hash where id = p_doc and content_hash is null;
end $$;
revoke all on function public.huos_set_document_hash(uuid, text) from public, anon;
grant execute on function public.huos_set_document_hash(uuid, text) to authenticated;

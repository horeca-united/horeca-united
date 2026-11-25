-- Audit wijzigingen aan documenten in de bierlead-workflow.
-- Staff-, contract-, kosten-, investerings- en overige lead-acties hebben al
-- eigen audit-tabellen; deze trigger vult alleen het ontbrekende documentspoor aan.
-- Details bevatten geen bestandsnaam, reviewnotitie, persoonsgegevens of documentinhoud.

create or replace function public.huos_beer_lead_documents_log()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lead uuid := coalesce(new.lead_id, old.lead_id);
  v_id uuid := coalesce(new.id, old.id);
  v_event text;
  v_details jsonb;
  v_fields text[] := '{}';
begin
  -- Verwijderen van een lead wist documenten via ON DELETE CASCADE. Laat die
  -- cascade niet mislukken doordat het audit-event naar de verwijderde lead wijst.
  if not exists (
    select 1 from public.huos_beer_leads l where l.id = v_lead
  ) then
    return null;
  end if;

  if tg_op = 'INSERT' then
    v_event := 'document_received';
    v_details := jsonb_build_object(
      'doc_type', new.doc_type,
      'status', new.status,
      'mime_type', new.mime_type,
      'size_bytes', new.size_bytes
    );
  elsif tg_op = 'DELETE' then
    v_event := 'document_deleted';
    v_details := jsonb_build_object('doc_type', old.doc_type, 'status', old.status);
  else
    if old.status is distinct from new.status then
      v_fields := array_append(v_fields, 'status');
    end if;
    if old.reviewed_by is distinct from new.reviewed_by
      or old.reviewed_at is distinct from new.reviewed_at then
      v_fields := array_append(v_fields, 'review');
    end if;
    if old.review_note is distinct from new.review_note then
      v_fields := array_append(v_fields, 'review_note');
    end if;
    if old.deleted_at is distinct from new.deleted_at then
      v_fields := array_append(v_fields, 'deleted_at');
    end if;
    if cardinality(v_fields) = 0 then
      return null;
    end if;

    v_event := case
      when old.deleted_at is null and new.deleted_at is not null then 'document_deleted'
      when old.status is distinct from new.status then 'document_status_changed'
      when old.reviewed_at is distinct from new.reviewed_at then 'document_reviewed'
      else 'document_updated'
    end;
    v_details := jsonb_build_object(
      'doc_type', new.doc_type,
      'changed_fields', to_jsonb(v_fields),
      'from_status', old.status,
      'to_status', new.status
    );
  end if;

  perform public.huos_beer_log(v_lead, v_event, 'document', v_id::text, v_details);
  return null;
end
$$;

revoke all on function public.huos_beer_lead_documents_log() from public, anon, authenticated;

create trigger huos_beer_lead_documents_audit
after insert or update or delete on public.huos_beer_lead_documents
for each row execute function public.huos_beer_lead_documents_log();

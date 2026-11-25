-- HUOS: klanten mogen naast PDF/PNG/JPG ook Excel (.xlsx) en CSV uploaden (afnameoverzichten van leveranciers).
-- Verruimt alleen de toegestane bestandstypen: in de opslagbucket en in de check op huos_pilot_documents.file_type.
-- RLS, storage-policies (eigen map {uid}/{org}/…), grootte-limiet (10 MB) en grants blijven ongewijzigd.
-- Oud Excel (.xls) wordt bewust niet toegestaan.

update storage.buckets
   set allowed_mime_types = array[
     'application/pdf','image/png','image/jpeg',
     'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/csv']
 where id = 'huos-pilot-private';

alter table public.huos_pilot_documents drop constraint if exists huos_pilot_documents_file_type_check;
alter table public.huos_pilot_documents add constraint huos_pilot_documents_file_type_check
  check (file_type = any (array[
    'application/pdf'::text, 'image/png'::text, 'image/jpeg'::text,
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'::text, 'text/csv'::text]));

-- Rollback (alleen als er geen documenten van deze typen meer zijn):
--   update storage.buckets set allowed_mime_types = array['application/pdf','image/png','image/jpeg'] where id = 'huos-pilot-private';
--   alter table public.huos_pilot_documents drop constraint huos_pilot_documents_file_type_check;
--   alter table public.huos_pilot_documents add constraint huos_pilot_documents_file_type_check
--     check (file_type = any (array['application/pdf'::text, 'image/png'::text, 'image/jpeg'::text]));

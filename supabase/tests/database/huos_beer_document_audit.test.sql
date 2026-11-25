begin;
select plan(3);

select has_table('public', 'huos_beer_lead_events', 'lead audit events table exists');
select has_trigger(
  'public',
  'huos_beer_lead_documents',
  'huos_beer_lead_documents_audit',
  'document changes are connected to the lead audit trail'
);
select ok(
  (select t.tgenabled = 'O'
   from pg_trigger t
   where t.tgrelid = 'public.huos_beer_lead_documents'::regclass
     and t.tgname = 'huos_beer_lead_documents_audit'),
  'document audit trigger is enabled'
);

select * from finish();
rollback;

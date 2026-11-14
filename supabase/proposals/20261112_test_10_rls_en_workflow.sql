\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
create or replace function public.t_expect_fail(p_name text, p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'FAIL  ' || p_name || ' (werd niet geblokkeerd)';
exception when others then return 'PASS  ' || p_name || '  [' || left(sqlerrm, 80) || ']'; end $$;
create or replace function public.t_expect_ok(p_name text, p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'PASS  ' || p_name;
exception when others then return 'FAIL  ' || p_name || '  [' || sqlerrm || ']'; end $$;
create or replace function public.t_expect_rows(p_name text, p_sql text, p_n int) returns text language plpgsql as $$
declare v int; begin execute 'select count(*) from (' || p_sql || ') q' into v;
return case when v = p_n then 'PASS  ' else 'FAIL  ' end || p_name || ' (rijen=' || v || ', verwacht ' || p_n || ')';
exception when others then return case when p_n = 0 then 'PASS  ' else 'FAIL  ' end || p_name || '  [' || left(sqlerrm,80) || ']'; end $$;
grant execute on function public.t_expect_fail(text,text), public.t_expect_ok(text,text), public.t_expect_rows(text,text,int) to anon, authenticated, service_role;

\echo '== 0. Na bootstrap: precies één beheerder (de eigenaar), oude admins niet overgenomen'
select t_expect_rows('precies 1 medewerker', 'select 1 from huos_staff', 1);
select t_expect_rows('dat is de eigenaar als admin', $$select 1 from huos_staff where user_id='00000000-0000-0000-0000-00000000000a' and role='admin' and scope='all'$$, 1);
select t_expect_rows('facturen@volkarnhem.nl (oude intake-admin) NIET in huos_staff', $$select 1 from huos_staff where user_id='00000000-0000-0000-0000-00000000000e'$$, 0);
select t_expect_rows('aanstelling staat in auditlog (database, met reden)', $$select 1 from huos_staff_audit where action='granted' and actor_kind='database' and reason like 'Eerste hoofdbeheerder%'$$, 1);

\echo '== 1. Geen rol = geen toegang'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000d';
select t_expect_rows('nieuwe gebruiker ziet geen leads', 'select 1 from huos_beer_leads', 0);
select t_expect_rows('nieuwe gebruiker ziet geen inzendingen', 'select 1 from huos_beer_intake_submissions', 0);
select t_expect_rows('nieuwe gebruiker ziet geen medewerkers', 'select 1 from huos_staff', 0);
select t_expect_rows('nieuwe gebruiker ziet geen rechten-audit', 'select 1 from huos_staff_audit', 0);
select t_expect_fail('nieuwe gebruiker kan zichzelf geen rol geven (functie)', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000d','admin','all','{}','ik wil admin')$$);
select t_expect_fail('nieuwe gebruiker kan niet direct in huos_staff schrijven', $$insert into huos_staff (user_id, role, scope) values ('00000000-0000-0000-0000-00000000000d','admin','all')$$);
select t_expect_fail('nieuwe gebruiker kan medewerkerslijst niet opvragen', $$select * from huos_staff_list()$$);
reset role;
set role anon; reset request.jwt.claim.sub;
select t_expect_fail('anon: geen toegang tot huos_staff', 'select * from huos_staff');
select t_expect_fail('anon: rolfunctie niet uitvoerbaar', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000d','admin')$$);
reset role;

\echo '== 2. Beheerder beheert rollen'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_fail('rol toekennen zonder reden geweigerd', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000b','reviewer')$$);
select t_expect_fail('rol aan onbevestigd account geweigerd', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000f','viewer','assigned','{}','test onbevestigd')$$);
select t_expect_ok('reviewer toegekend (bereik: toegewezen leads)', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000b','reviewer','assigned','{}','Pilot beoordelaar')$$);
select t_expect_ok('viewer toegekend (bereik: regio Gelderland)', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000c','viewer','region',array['Gelderland'],'Pilot meekijker')$$);
select t_expect_fail('bereik regio zonder waarden geweigerd', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000c','viewer','region','{}','fout bereik')$$);
select t_expect_fail('admin kan zichzelf niet degraderen', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000a','viewer','all','{}','test degradatie')$$);
select t_expect_fail('admin kan zichzelf niet intrekken', $$select huos_staff_revoke('00000000-0000-0000-0000-00000000000a','test intrekken')$$);
select t_expect_rows('admin ziet 3 medewerkers in lijst', 'select * from huos_staff_list()', 3);
select t_expect_rows('admin ziet rechten-audit (3 regels)', 'select 1 from huos_staff_audit', 3);
select t_expect_fail('rechten-audit niet te wijzigen', $$update huos_staff_audit set reason='x'$$);
select t_expect_fail('rechten-audit niet te wissen', $$delete from huos_staff_audit$$);
reset role;

\echo '== 3. Beoordelaar en alleen-lezen kunnen zichzelf niet ophogen'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_rows('reviewer ziet alleen eigen rij in huos_staff', 'select 1 from huos_staff', 1);
select t_expect_fail('reviewer -> admin via functie', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000b','admin','all','{}','ik wil meer')$$);
select t_expect_fail('reviewer -> scope all via directe update', $$update huos_staff set scope='all' where user_id='00000000-0000-0000-0000-00000000000b'$$);
select t_expect_fail('reviewer kan viewer niet ophogen', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000c','reviewer','all','{}','collega helpen')$$);
select t_expect_rows('reviewer ziet geen rechten-audit', 'select 1 from huos_staff_audit', 0);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';
select t_expect_fail('viewer -> admin via functie', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000c','admin','all','{}','ik wil meer')$$);
select t_expect_fail('viewer kan eigen rij niet wijzigen', $$update huos_staff set role='admin'$$);
reset role;
-- Zelfs als iemand per ongeluk schrijfrechten zou geven, houdt de guard-trigger het tegen:
grant update on public.huos_staff to authenticated;
create policy tmp_all_update on public.huos_staff for update to authenticated using (true) with check (true);
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_fail('guard-trigger blokkeert ophogen ook bij foutieve grant+policy', $$update huos_staff set role='admin', scope='all' where user_id='00000000-0000-0000-0000-00000000000b'$$);
reset role;
drop policy tmp_all_update on public.huos_staff; revoke update on public.huos_staff from authenticated;

\echo '== 4. Bereik: reviewer met scope assigned ziet alleen eigen leads'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_rows('reviewer ziet 0 leads zolang niets is toegewezen', 'select 1 from huos_beer_lead_overview', 0);
select t_expect_rows('reviewer ziet 0 inzendingen zolang niets is toegewezen', 'select 1 from huos_beer_intake_submissions', 0);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_ok('admin wijst lead toe aan reviewer', $$select huos_beer_lead_assign((select id from huos_beer_leads limit 1),'00000000-0000-0000-0000-00000000000b', now()+interval '3 days','high')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_rows('reviewer ziet nu 1 lead', 'select 1 from huos_beer_lead_overview', 1);
select t_expect_rows('reviewer ziet nu 1 inzending', 'select 1 from huos_beer_intake_submissions', 1);
select t_expect_fail('reviewer kan lead niet aan ander toewijzen', $$select huos_beer_lead_assign((select lead_id from huos_beer_lead_overview limit 1),'00000000-0000-0000-0000-00000000000a')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';
select t_expect_rows('viewer (regio Gelderland) ziet 0 leads zonder regio', 'select 1 from huos_beer_lead_overview', 0);
reset role;
update public.huos_beer_leads set region = 'Gelderland';   -- simulatie: lead krijgt regio
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';
select t_expect_rows('viewer ziet lead in eigen regio', 'select 1 from huos_beer_lead_overview', 1);
select t_expect_fail('viewer kan fase niet wijzigen', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'contact_needed')$$);
select t_expect_fail('viewer kan antwoorden niet wijzigen', $$update huos_beer_intake_submissions set answers='{}'$$);
reset role;

\echo '== 5. Workflow (reviewer op toegewezen lead)'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_ok('new -> contact_needed', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'contact_needed','gebeld')$$);
select t_expect_fail('contact_needed -> customer (ongeldig)', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'customer')$$);
select t_expect_fail('afsluiten zonder reden', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'closed')$$);
select t_expect_ok('notitie toevoegen', $$select huos_beer_lead_add_note((select lead_id from huos_beer_lead_overview limit 1),'Klant terugbellen na 14:00')$$);
select t_expect_fail('verificatie negatieve hl', $$select huos_beer_lead_verify((select lead_id from huos_beer_lead_overview limit 1),'annual_volume_hl',2025::smallint,'-5','hl','corrected','invoice','factuur bekeken')$$);
select t_expect_fail('verificatie zonder notitie', $$select huos_beer_lead_verify((select lead_id from huos_beer_lead_overview limit 1),'annual_volume_hl',2025::smallint,'110','hl','corrected','invoice','')$$);
select t_expect_ok('hl gecorrigeerd naar 110', $$select huos_beer_lead_verify((select lead_id from huos_beer_lead_overview limit 1),'annual_volume_hl',2025::smallint,'110','hl','corrected','invoice','Jaaroverzicht 2025 Heineken')$$);
select 'INFO  overzicht: ' || hl_submitted || ' opgegeven / ' || hl_verified || ' geverifieerd / label ' || hl_quality from huos_beer_lead_overview;
select t_expect_fail('verificatie wijzigen (append-only)', $$update huos_beer_lead_verifications set note='x'$$);
select t_expect_fail('auditlog wissen', $$delete from huos_beer_lead_events$$);
select t_expect_fail('oude RPC huos_beer_verify_hl', $$select huos_beer_verify_hl((select submission_id from huos_beer_lead_overview limit 1), true, 'test test')$$);
select t_expect_fail('direct verificatiekolom inzending wijzigen', $$update huos_beer_intake_submissions set annual_volume_verified_at=null$$);
select t_expect_ok('-> review_needed', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'review_needed')$$);
select t_expect_ok('-> ready_for_offer (hl geverifieerd)', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'ready_for_offer')$$);
select t_expect_ok('afsluiten met reden', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'closed','Klant kiest voor huidige brouwerij')$$);
select t_expect_fail('heropenen (alleen admin)', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'contact_needed')$$);
select t_expect_fail('export (alleen admin)', $$select * from huos_beer_export_leads()$$);
reset role;

\echo '== 6. Admin: heropenen, export gelogd; nieuwe inzending krijgt automatisch lead'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_ok('admin heropent', $$select huos_beer_lead_set_stage((select lead_id from huos_beer_lead_overview limit 1),'contact_needed','Klant belde terug')$$);
select t_expect_rows('admin export levert rijen', $$select * from huos_beer_export_leads()$$, 1);
select t_expect_rows('export staat in auditlog', $$select 1 from huos_beer_lead_events where event_type='export'$$, 1);
reset role;
set role service_role; reset request.jwt.claim.sub;
select t_expect_ok('intake slaat inzending met machtiging op', $$insert into huos_beer_intake_submissions (company_name,contact_name,email,answers,privacy_notice_version,data_route,mandate_status,mandate_consent_at,mandate_consent_version,mandate_authority_asserted) values ('Bar Twee','Piet','piet@bar.nl','{"annual_volume_source":"unknown"}','huos-beer-2026-11','mandate','pending',now(),'huos-mandate-beer-v1',true)$$);
reset role;
select 'INFO  leads: ' || string_agg(stage, ', ') from huos_beer_leads;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_rows('reviewer ziet nieuwe (niet-toegewezen) lead niet', $$select 1 from huos_beer_leads where stage='mandate_pending'$$, 0);
select t_expect_fail('reviewer kan machtiging van niet-toegewezen lead niet beoordelen', $$select huos_beer_mandate_decide((select id from huos_beer_mandates limit 1),'verified','kvk_extract','KvK bekeken')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_fail('machtiging verifiëren zonder methode', $$select huos_beer_mandate_decide((select id from huos_beer_mandates limit 1),'verified')$$);
select t_expect_ok('machtiging geverifieerd via KvK', $$select huos_beer_mandate_decide((select id from huos_beer_mandates limit 1),'verified','kvk_extract','KvK-uittreksel: Piet is eigenaar')$$);
select t_expect_ok('machtiging ingetrokken', $$select huos_beer_mandate_decide((select id from huos_beer_mandates limit 1),'revoked',null,'Klant mailde intrekking','email')$$);
select t_expect_fail('ingetrokken machtiging heropenen', $$select huos_beer_mandate_decide((select id from huos_beer_mandates limit 1),'verified','kvk_extract','opnieuw opnieuw')$$);
select t_expect_ok('lead 2 -> document_received', $$select huos_beer_lead_set_stage((select id from huos_beer_leads where stage='mandate_pending'),'document_received')$$);
select t_expect_ok('lead 2 -> review_needed', $$select huos_beer_lead_set_stage((select id from huos_beer_leads where stage='document_received'),'review_needed')$$);
select t_expect_fail('lead 2 zonder hl: ready_for_offer zonder onderbouwing', $$select huos_beer_lead_set_stage((select id from huos_beer_leads where stage='review_needed'),'ready_for_offer')$$);
reset role;

\echo '== 7. Intrekken van rechten'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_ok('admin trekt reviewer in', $$select huos_staff_revoke('00000000-0000-0000-0000-00000000000b','Einde pilotperiode')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
select t_expect_rows('ingetrokken reviewer ziet niets meer', 'select 1 from huos_beer_lead_overview', 0);
select t_expect_fail('ingetrokken reviewer kan niets meer', $$select huos_beer_lead_add_note((select id from huos_beer_leads limit 1),'nog even')$$);
reset role;

\echo '== 8. Wijziging buiten de API (SQL-editor) wordt ook vastgelegd; laatste admin beschermd'
reset request.jwt.claim.sub;
select t_expect_fail('laatste actieve admin niet te verwijderen (ook niet via SQL)', $$delete from huos_staff where user_id='00000000-0000-0000-0000-00000000000a'$$);
update public.huos_staff set scope='all', scope_values='{}' where user_id='00000000-0000-0000-0000-00000000000c';
select t_expect_rows('SQL-editorwijziging gelogd als database', $$select 1 from huos_staff_audit where actor_kind='database' and action='changed'$$, 1);

\echo '== 9. Bestaande functionaliteit ongewijzigd'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000e';
select t_expect_rows('oude intake-admin ziet nog inzendingen via bestaande policy', 'select 1 from huos_beer_intake_submissions', 2);
select t_expect_rows('oude intake-admin ziet GEEN nieuwe werktabellen', 'select 1 from huos_beer_leads', 0);
reset role;
select 'INFO  inzendingen ongewijzigd: ' || string_agg(status || '/' || mandate_status || '/hl=' || coalesce(answers->>'annual_volume_hl','-'), '; ') from huos_beer_intake_submissions;

\echo '== 10. Scheiding intern / extern'
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_fail('klantaccount facturen@volkarnhem.nl kan geen interne rol krijgen', $$select huos_staff_set_role('00000000-0000-0000-0000-00000000000e','viewer','assigned','{}','test klant')$$);
select t_expect_fail('persoonlijk account huihu274@gmail.com kan geen interne rol krijgen', $$select huos_staff_set_role('00000000-0000-0000-0000-000000000010','viewer','assigned','{}','test gmail')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-000000000011';
select t_expect_ok('horecaunited-account zonder rol maakt (per ongeluk) klantomgeving aan', $$insert into huos_pilot_organizations (owner_id, name) values ('00000000-0000-0000-0000-000000000011','Test')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_fail('eigenaar van klantomgeving kan geen interne rol krijgen', $$select huos_staff_set_role('00000000-0000-0000-0000-000000000011','viewer','assigned','{}','test menging')$$);
select t_expect_fail('hoofdbeheerder kan geen klantomgeving aanmaken', $$insert into huos_pilot_organizations (owner_id, name) values ('00000000-0000-0000-0000-00000000000a','Intern')$$);
reset role;
\echo '-- Stap 5 gesimuleerd: oude admin-toegang facturen@volkarnhem.nl afsluiten (C3)'
drop policy huos_beer_intake_admin_select on public.huos_beer_intake_submissions;
drop policy huos_beer_intake_admin_update on public.huos_beer_intake_submissions;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000e';
select t_expect_ok('klant maakt eigen klantomgeving aan', $$insert into huos_pilot_organizations (owner_id, name) values ('00000000-0000-0000-0000-00000000000e','Restaurant t Volk')$$);
select t_expect_rows('klant ziet alleen eigen onderneming', 'select 1 from huos_pilot_organizations', 1);
select t_expect_fail('klant kan geen onderneming op andermans naam aanmaken', $$insert into huos_pilot_organizations (owner_id, name) values ('00000000-0000-0000-0000-00000000000d','Ander')$$);
select t_expect_rows('klant ziet 0 inzendingen (na C3)', 'select 1 from huos_beer_intake_submissions', 0);
select t_expect_rows('klant ziet 0 leads', 'select 1 from huos_beer_leads', 0);
select t_expect_rows('klant ziet 0 machtigingen', 'select 1 from huos_beer_mandates', 0);
select t_expect_rows('klant ziet 0 verificaties', 'select 1 from huos_beer_lead_verifications', 0);
select t_expect_rows('klant ziet 0 notities', 'select 1 from huos_beer_lead_notes', 0);
select t_expect_rows('klant ziet 0 auditregels', 'select 1 from huos_beer_lead_events', 0);
select t_expect_rows('klant ziet 0 medewerkers', 'select 1 from huos_staff', 0);
select t_expect_fail('klant kan export niet aanroepen', $$select * from huos_beer_export_leads()$$);
select t_expect_fail('klant kan geen fase wijzigen', $$select huos_beer_lead_set_stage((select gen_random_uuid()),'closed','test test')$$);
reset role;
set role authenticated; set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
select t_expect_rows('hoofdbeheerder ziet na C3 nog alle inzendingen (via huos_staff)', 'select 1 from huos_beer_intake_submissions', 2);
select t_expect_rows('hoofdbeheerder ziet klantomgevingen niet (klantdata blijft van klant)', 'select 1 from huos_pilot_organizations', 0);
reset role;

\echo '== Rechten-audit'
select 'INFO  ' || id || ' ' || action || ' door ' || coalesce(actor_id::text, 'database') || ' -> ' || coalesce(new_value->>'role', old_value->>'role') || '/' || coalesce(new_value->>'scope','-') || ' reden: ' || coalesce(reason,'-') from huos_staff_audit order by id;

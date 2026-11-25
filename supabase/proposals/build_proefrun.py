#!/usr/bin/env python3
"""Bouwt één atomair proefscript (DO-blok) voor Supabase:
migraties A0 + A + B + C uitvoeren, tests draaien met echte account-ID's,
en het blok eindigt ALTIJD met RAISE EXCEPTION -> volledige rollback.
Gebruik: build_proefrun.py <hoofdbeheerder-uuid> <facturen-uuid> <huihu-uuid> > proefrun.sql
"""
import re, sys
from pathlib import Path

HERE = Path(__file__).parent
ADMIN, KLANT, PERSOONLIJK = sys.argv[1:4]
REV  = 'aaaaaaaa-0000-4000-8000-00000000000b'   # tijdelijke proef-accounts (bestaan alleen in de transactie)
VIEW = 'aaaaaaaa-0000-4000-8000-00000000000c'
NEW  = 'aaaaaaaa-0000-4000-8000-00000000000d'
NOLOG= 'aaaaaaaa-0000-4000-8000-000000000011'

def strip_tx(sql: str) -> str:
    # transactiegrenzen weghalen: het DO-blok is zelf de (enige) transactie
    return re.sub(r'(?im)^\s*(begin|commit);\s*$', '', sql)

a0 = strip_tx((HERE/'20261112_A0_huos_staff_roles_PROPOSAL.sql').read_text().replace('__BEVESTIGD_USER_ID__', ADMIN))
main = strip_tx((HERE/'20261112_huos_beer_lead_workflow_PROPOSAL.sql').read_text())
for tag in ('$m0$', '$m1$', '$q$', '$proef$'):
    assert tag not in a0 and tag not in main

out = []
w = out.append
w("do $proef$")
w("declare r text := ''; n_real int; fp_before text; fp_after text; ids_before uuid[];")
w("begin")
w("  -- 0. Uitgangssituatie vastleggen (zonder persoonsgegevens)")
w("  select count(*), array_agg(id) into n_real, ids_before from public.huos_beer_intake_submissions;")
w("  select md5(string_agg(to_jsonb(s)::text, '|' order by id)) into fp_before from public.huos_beer_intake_submissions s;")
w("  -- 1. Tijdelijke proef-accounts (worden met de rest teruggedraaid)")
w(f"""  insert into auth.users (id, aud, role, email, email_confirmed_at, last_sign_in_at) values
   ('{REV}','authenticated','authenticated','proef-reviewer@horecaunited.nl',now(),now()),
   ('{VIEW}','authenticated','authenticated','proef-viewer@horecaunited.nl',now(),now()),
   ('{NEW}','authenticated','authenticated','proef-klant@voorbeeld.nl',now(),now()),
   ('{NOLOG}','authenticated','authenticated','proef-nooitingelogd@horecaunited.nl',now(),null);""")
w("  -- 2. Migraties")
w("  execute $m0$" + a0 + "$m0$;")
w("  execute $m1$" + main + "$m1$;")
w("  r := r || chr(10) || 'INFO  migraties A0+A+B+C uitgevoerd';")

def as_(role, uid=None):
    w(f"  execute 'set local role {role}';")
    w(f"  perform set_config('request.jwt.claim.sub', '{uid or ''}', true);")
def su():
    w("  execute 'reset role'; perform set_config('request.jwt.claim.sub', '', true);")
def t(kind, name, sql, n=None):
    name = name.replace("'", "''")
    if kind == 'rows':
        w(f"  r := r || chr(10) || public.t_expect_rows('{name}', $q${sql}$q$, {n});")
    else:
        w(f"  r := r || chr(10) || public.t_expect_{kind}('{name}', $q${sql}$q$);")
def info(expr):
    w(f"  r := r || chr(10) || 'INFO  ' || coalesce(({expr})::text, '-');")
def hdr(s): w(f"  r := r || chr(10) || '== {s}';")
def raw(s): w("  " + s)

# testhelpers
raw("""execute $h$
create function public.t_expect_fail(p_name text, p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'FAIL  ' || p_name || ' (werd niet geblokkeerd)';
exception when others then return 'PASS  ' || p_name || '  [' || left(sqlerrm, 70) || ']'; end $f$;
create function public.t_expect_ok(p_name text, p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return 'PASS  ' || p_name;
exception when others then return 'FAIL  ' || p_name || '  [' || sqlerrm || ']'; end $f$;
create function public.t_expect_rows(p_name text, p_sql text, p_n int) returns text language plpgsql as $f$
declare v int; begin execute 'select count(*) from (' || p_sql || ') q' into v;
return case when v = p_n then 'PASS  ' else 'FAIL  ' end || p_name || ' (rijen=' || v || ', verwacht ' || p_n || ')';
exception when others then return case when p_n = 0 then 'PASS  ' else 'FAIL  ' end || p_name || '  [' || left(sqlerrm,70) || ']'; end $f$;
grant execute on function public.t_expect_fail(text,text), public.t_expect_ok(text,text), public.t_expect_rows(text,text,int) to anon, authenticated, service_role;
$h$;""")

hdr('0. Bootstrap en backfill')
t('rows', 'precies 1 medewerker', "select 1 from public.huos_staff", 1)
t('rows', 'hui@horecaunited.nl is admin met bereik alles', f"select 1 from public.huos_staff s join auth.users u on u.id=s.user_id where s.user_id='{ADMIN}' and lower(u.email)='hui@horecaunited.nl' and s.role='admin' and s.scope='all' and s.active", 1)
t('rows', 'facturen@volkarnhem.nl NIET in huos_staff', f"select 1 from public.huos_staff where user_id='{KLANT}'", 0)
t('rows', 'huihu274@gmail.com NIET in huos_staff', f"select 1 from public.huos_staff where user_id='{PERSOONLIJK}'", 0)
t('rows', 'aanstelling in rechten-audit met reden', "select 1 from public.huos_staff_audit where action='granted' and reason like 'Eerste hoofdbeheerder%'", 1)
t('rows', 'elke bestaande inzending heeft een werkrecord (backfill)', "select 1 from public.huos_beer_intake_submissions s where not exists (select 1 from public.huos_beer_leads l where l.submission_id=s.id)", 0)
info("select 'bestaande leads na backfill: ' || count(*) || ' (' || string_agg(stage, ',') || ')' from public.huos_beer_leads")
info("select 'legacy hl-verificaties overgenomen: ' || count(*) from public.huos_beer_lead_verifications where evidence_kind='legacy_import'")

# proefinzendingen via de echte intake-rol
hdr('1. Proefinzendingen via service_role (zoals de Edge Function)')
as_('service_role')
t('ok', 'proefinzending 1 opgeslagen', """insert into public.huos_beer_intake_submissions (company_name,contact_name,email,answers,privacy_notice_version) values ('PROEF Testcafe','Proef Persoon','proef1@voorbeeld.nl','{"annual_volume_hl":120,"annual_volume_source":"own_estimate","brewery_supplier":"Heineken"}','huos-beer-2026-11')""")
t('ok', 'proefinzending 2 met machtiging opgeslagen', """insert into public.huos_beer_intake_submissions (company_name,contact_name,email,answers,privacy_notice_version,data_route,mandate_status,mandate_consent_at,mandate_consent_version,mandate_authority_asserted) values ('PROEF Bar','Proef Twee','proef2@voorbeeld.nl','{"annual_volume_source":"unknown"}','huos-beer-2026-11','mandate','pending',now(),'huos-mandate-beer-v1',true)""")
su()
t('rows', 'trigger maakte 2 nieuwe leads aan', "select 1 from public.huos_beer_leads l join public.huos_beer_intake_submissions s on s.id=l.submission_id where s.company_name like 'PROEF %'", 2)
t('rows', 'machtiging-inzending -> lead mandate_pending + machtiging pending', "select 1 from public.huos_beer_leads l join public.huos_beer_intake_submissions s on s.id=l.submission_id join public.huos_beer_mandates m on m.lead_id=l.id where s.company_name='PROEF Bar' and l.stage='mandate_pending' and m.status='pending'", 1)

L1 = "(select l.id from public.huos_beer_leads l join public.huos_beer_intake_submissions s on s.id=l.submission_id where s.company_name='PROEF Testcafe')"
L2 = "(select l.id from public.huos_beer_leads l join public.huos_beer_intake_submissions s on s.id=l.submission_id where s.company_name='PROEF Bar')"
M2 = f"(select id from public.huos_beer_mandates where lead_id={L2})"

hdr('2. Geen rol = geen toegang')
for who, uid in (('persoonlijk account huihu274', PERSOONLIJK), ('nieuw klantaccount', NEW)):
    as_('authenticated', uid)
    t('rows', f'{who}: 0 leads', "select 1 from public.huos_beer_leads", 0)
    t('rows', f'{who}: 0 inzendingen', "select 1 from public.huos_beer_intake_submissions", 0)
    t('rows', f'{who}: 0 medewerkers', "select 1 from public.huos_staff", 0)
    t('rows', f'{who}: 0 rechten-audit', "select 1 from public.huos_staff_audit", 0)
    t('fail', f'{who}: kan zichzelf geen rol geven', f"select public.huos_staff_set_role('{uid}','admin','all','{{}}','ik wil admin')")
    t('fail', f'{who}: kan niet direct in huos_staff schrijven', f"insert into public.huos_staff (user_id, role, scope) values ('{uid}','admin','all')")
    su()
as_('anon')
t('fail', 'anon: geen toegang tot huos_staff', "select * from public.huos_staff")
t('rows', 'anon: 0 inzendingen', "select 1 from public.huos_beer_intake_submissions", 0)
t('fail', 'anon: rolfunctie niet uitvoerbaar', f"select public.huos_staff_set_role('{NEW}','admin')")
su()

hdr('3. Hoofdbeheerder (hui@horecaunited.nl) beheert rollen')
as_('authenticated', ADMIN)
t('rows', 'beheerder ziet alle inzendingen (echt + proef)', "select 1 from public.huos_beer_intake_submissions", "n_real + 2")
t('rows', 'beheerder ziet alle leads in overzicht', "select 1 from public.huos_beer_lead_overview", "n_real + 2")
t('fail', 'rol toekennen zonder reden geweigerd', f"select public.huos_staff_set_role('{REV}','reviewer')")
t('fail', 'klantaccount facturen@ kan geen interne rol krijgen', f"select public.huos_staff_set_role('{KLANT}','viewer','assigned','{{}}','test klant')")
t('fail', 'persoonlijk account huihu274 kan geen interne rol krijgen', f"select public.huos_staff_set_role('{PERSOONLIJK}','viewer','assigned','{{}}','test gmail')")
t('ok', 'proef-reviewer toegekend (bereik: toegewezen)', f"select public.huos_staff_set_role('{REV}','reviewer','assigned','{{}}','Proefrun beoordelaar')")
t('ok', 'proef-viewer toegekend (bereik: regio)', f"select public.huos_staff_set_role('{VIEW}','viewer','region',array['Gelderland'],'Proefrun meekijker')")
t('fail', 'beheerder kan zichzelf niet degraderen', f"select public.huos_staff_set_role('{ADMIN}','viewer','all','{{}}','test degradatie')")
t('fail', 'beheerder kan zichzelf niet intrekken', f"select public.huos_staff_revoke('{ADMIN}','test intrekken')")
t('rows', 'medewerkerslijst toont 3', "select * from public.huos_staff_list()", 3)
t('fail', 'rechten-audit niet te wijzigen', "update public.huos_staff_audit set reason='x'")
t('fail', 'rechten-audit niet te wissen', "delete from public.huos_staff_audit")
t('fail', 'beheerder kan geen klantomgeving aanmaken', f"insert into public.huos_pilot_organizations (owner_id, name) values ('{ADMIN}','Intern')")
su()

hdr('4. Beoordelaar en alleen-lezen kunnen zich niet ophogen; bereik werkt')
as_('authenticated', REV)
t('rows', 'reviewer ziet alleen eigen rij huos_staff', "select 1 from public.huos_staff", 1)
t('fail', 'reviewer -> admin via functie', f"select public.huos_staff_set_role('{REV}','admin','all','{{}}','ik wil meer')")
t('fail', 'reviewer -> bereik alles via directe update', f"update public.huos_staff set scope='all' where user_id='{REV}'")
t('rows', 'reviewer ziet 0 leads zolang niets toegewezen', "select 1 from public.huos_beer_lead_overview", 0)
t('rows', 'reviewer ziet 0 inzendingen zolang niets toegewezen', "select 1 from public.huos_beer_intake_submissions", 0)
t('fail', 'reviewer kan niet-zichtbare lead niet claimen', f"select public.huos_beer_lead_assign({L1},'{REV}')")
su()
as_('authenticated', VIEW)
t('fail', 'viewer -> admin via functie', f"select public.huos_staff_set_role('{VIEW}','admin','all','{{}}','ik wil meer')")
t('rows', 'viewer (regio Gelderland) ziet 0 leads', "select 1 from public.huos_beer_lead_overview", 0)
su()
raw("grant update on public.huos_staff to authenticated;")
raw("create policy proef_tmp_all_update on public.huos_staff for update to authenticated using (true) with check (true);")
as_('authenticated', REV)
t('fail', 'guard-trigger blokkeert ophogen ook bij foutieve grant+policy', f"update public.huos_staff set role='admin', scope='all' where user_id='{REV}'")
su()
raw("drop policy proef_tmp_all_update on public.huos_staff; revoke update on public.huos_staff from authenticated;")
as_('authenticated', ADMIN)
t('ok', 'beheerder wijst proeflead 1 toe aan reviewer', f"select public.huos_beer_lead_assign({L1},'{REV}', now()+interval '3 days','high')")
su()
raw(f"update public.huos_beer_leads set region='Gelderland' where id={L1};")
as_('authenticated', REV)
t('rows', 'reviewer ziet nu precies 1 lead', "select 1 from public.huos_beer_lead_overview", 1)
t('rows', 'reviewer ziet precies 1 inzending', "select 1 from public.huos_beer_intake_submissions", 1)
t('rows', 'dat is de proefinzending (niet de echte)', "select 1 from public.huos_beer_intake_submissions where company_name='PROEF Testcafe'", 1)
t('fail', 'reviewer kan lead niet aan ander toewijzen', f"select public.huos_beer_lead_assign({L1},'{ADMIN}')")
su()
as_('authenticated', VIEW)
t('rows', 'viewer ziet lead in eigen regio', "select 1 from public.huos_beer_lead_overview", 1)
t('fail', 'viewer kan fase niet wijzigen', f"select public.huos_beer_lead_set_stage({L1},'contact_needed')")
t('fail', 'viewer kan antwoorden niet wijzigen', "update public.huos_beer_intake_submissions set answers='{}'")
su()

hdr('5. Workflow en verificatie (reviewer op proeflead)')
as_('authenticated', REV)
t('ok', 'new -> contact_needed', f"select public.huos_beer_lead_set_stage({L1},'contact_needed','gebeld')")
t('fail', 'contact_needed -> customer (ongeldig)', f"select public.huos_beer_lead_set_stage({L1},'customer')")
t('fail', 'afsluiten zonder reden', f"select public.huos_beer_lead_set_stage({L1},'closed')")
t('ok', 'notitie toevoegen', f"select public.huos_beer_lead_add_note({L1},'Proefnotitie')")
t('fail', 'verificatie negatieve hl', f"select public.huos_beer_lead_verify({L1},'annual_volume_hl',2025::smallint,'-5','hl','corrected','invoice','factuur bekeken')")
t('fail', 'verificatie zonder notitie', f"select public.huos_beer_lead_verify({L1},'annual_volume_hl',2025::smallint,'110','hl','corrected','invoice','')")
t('ok', 'hl gecorrigeerd 120 -> 110', f"select public.huos_beer_lead_verify({L1},'annual_volume_hl',2025::smallint,'110','hl','corrected','invoice','Proef: jaaroverzicht 2025')")
t('rows', 'overzicht: 120 opgegeven / 110 geverifieerd / label verified', "select 1 from public.huos_beer_lead_overview where hl_submitted=120 and hl_verified=110 and hl_quality='verified'", 1)
t('rows', 'oorspronkelijk antwoord blijft 120', "select 1 from public.huos_beer_intake_submissions where company_name='PROEF Testcafe' and answers->>'annual_volume_hl'='120'", 1)
t('fail', 'verificatie wijzigen (append-only)', "update public.huos_beer_lead_verifications set note='x'")
t('fail', 'auditlog wissen', "delete from public.huos_beer_lead_events")
t('fail', 'oude RPC huos_beer_verify_hl ingetrokken', f"select public.huos_beer_verify_hl((select submission_id from public.huos_beer_lead_overview limit 1), true, 'test test')")
t('fail', 'direct verificatiekolom inzending wijzigen', "update public.huos_beer_intake_submissions set annual_volume_verified_at=null")
t('ok', '-> review_needed', f"select public.huos_beer_lead_set_stage({L1},'review_needed')")
t('ok', '-> ready_for_offer (hl geverifieerd)', f"select public.huos_beer_lead_set_stage({L1},'ready_for_offer')")
t('ok', 'afsluiten met reden', f"select public.huos_beer_lead_set_stage({L1},'closed','Proef: klant kiest huidige brouwerij')")
t('fail', 'heropenen (alleen beheerder)', f"select public.huos_beer_lead_set_stage({L1},'contact_needed')")
t('fail', 'export (alleen beheerder)', "select * from public.huos_beer_export_leads()")
t('fail', 'machtiging van niet-toegewezen lead beoordelen', f"select public.huos_beer_mandate_decide({M2},'verified','kvk_extract','KvK bekeken')")
su()

hdr('6. Beheerder: heropenen, export, machtiging')
as_('authenticated', ADMIN)
t('ok', 'beheerder heropent', f"select public.huos_beer_lead_set_stage({L1},'contact_needed','Proef: klant belde terug')")
t('rows', 'export levert alle leads', "select * from public.huos_beer_export_leads()", "n_real + 2")
t('rows', 'export gelogd', "select 1 from public.huos_beer_lead_events where event_type='export'", 1)
t('fail', 'machtiging verifiëren zonder methode', f"select public.huos_beer_mandate_decide({M2},'verified')")
t('ok', 'machtiging geverifieerd via KvK', f"select public.huos_beer_mandate_decide({M2},'verified','kvk_extract','Proef: KvK-uittreksel bekeken')")
t('ok', 'machtiging ingetrokken', f"select public.huos_beer_mandate_decide({M2},'revoked',null,'Proef: klant mailde intrekking','email')")
t('fail', 'ingetrokken machtiging heropenen', f"select public.huos_beer_mandate_decide({M2},'verified','kvk_extract','opnieuw opnieuw')")
t('ok', 'lead 2 -> document_received', f"select public.huos_beer_lead_set_stage({L2},'document_received')")
t('ok', 'lead 2 -> review_needed', f"select public.huos_beer_lead_set_stage({L2},'review_needed')")
t('fail', 'lead 2 zonder hl: ready_for_offer zonder onderbouwing', f"select public.huos_beer_lead_set_stage({L2},'ready_for_offer')")
t('ok', 'beheerder trekt proef-reviewer in', f"select public.huos_staff_revoke('{REV}','Proef: einde test')")
su()
as_('authenticated', REV)
t('rows', 'ingetrokken reviewer ziet niets meer', "select 1 from public.huos_beer_lead_overview", 0)
t('fail', 'ingetrokken reviewer kan niets meer', f"select public.huos_beer_lead_add_note({L1},'nog even')")
su()

hdr('7. Scheiding intern/extern')
as_('authenticated', NOLOG)
t('ok', 'horecaunited-account zonder rol maakt klantomgeving aan', f"insert into public.huos_pilot_organizations (owner_id, name) values ('{NOLOG}','Proef')")
su()
as_('authenticated', ADMIN)
t('fail', 'eigenaar klantomgeving kan geen interne rol krijgen', f"select public.huos_staff_set_role('{NOLOG}','viewer','assigned','{{}}','test menging')")
su()
t('fail', 'laatste actieve beheerder niet te verwijderen (ook niet via SQL)', f"delete from public.huos_staff where user_id='{ADMIN}'")
raw(f"update public.huos_staff set scope='all', scope_values='{{}}' where user_id='{VIEW}';")
t('rows', 'wijziging via SQL-editor gelogd als database', "select 1 from public.huos_staff_audit where actor_kind='database' and action='changed'", 1)

hdr('8. Huidige toegang facturen@ ongewijzigd (stap 5 nog niet uitgevoerd)')
as_('authenticated', KLANT)
t('rows', 'facturen@ ziet nog alle inzendingen via oude intake-admin-policy', "select 1 from public.huos_beer_intake_submissions", "n_real + 2")
t('rows', 'facturen@ ziet GEEN nieuwe werktabellen', "select 1 from public.huos_beer_leads", 0)
t('rows', 'facturen@ ziet geen medewerkers', "select 1 from public.huos_staff", 0)
su()

hdr('9. Simulatie stap 5: oude toegang facturen@ afsluiten (C3)')
raw("drop policy huos_beer_intake_admin_select on public.huos_beer_intake_submissions;")
raw("drop policy huos_beer_intake_admin_update on public.huos_beer_intake_submissions;")
as_('authenticated', KLANT)
t('ok', 'klant maakt eigen klantomgeving aan', f"insert into public.huos_pilot_organizations (owner_id, name) values ('{KLANT}','PROEF Restaurant')")
t('rows', 'klant ziet alleen eigen onderneming', "select 1 from public.huos_pilot_organizations", 1)
t('fail', 'klant kan geen onderneming op andermans naam aanmaken', f"insert into public.huos_pilot_organizations (owner_id, name) values ('{NEW}','Ander')")
for tbl in ('huos_beer_intake_submissions','huos_beer_leads','huos_beer_mandates','huos_beer_lead_verifications','huos_beer_lead_notes','huos_beer_lead_events','huos_staff','huos_staff_audit'):
    t('rows', f'klant ziet 0 rijen in {tbl}', f"select 1 from public.{tbl}", 0)
t('fail', 'klant kan export niet aanroepen', "select * from public.huos_beer_export_leads()")
su()
as_('authenticated', ADMIN)
t('rows', 'hoofdbeheerder ziet na C3 nog alle inzendingen (via huos_staff)', "select 1 from public.huos_beer_intake_submissions", "n_real + 2")
t('rows', 'hoofdbeheerder ziet klantomgevingen niet', "select 1 from public.huos_pilot_organizations", 0)
su()

hdr('10. Bestaande gegevens ongewijzigd')
raw("select md5(string_agg(to_jsonb(s)::text, '|' order by id)) into fp_after from public.huos_beer_intake_submissions s where id = any(ids_before);")
raw("r := r || chr(10) || case when fp_after = fp_before then 'PASS  bestaande inzending(en) byte-voor-byte ongewijzigd' else 'FAIL  bestaande inzending(en) gewijzigd!' end;")
info("select 'rechten-audit regels: ' || count(*) from public.huos_staff_audit")
info("select 'lead-auditregels: ' || count(*) || ' (' || string_agg(distinct event_type, ',') || ')' from public.huos_beer_lead_events")

w("  -- 11. ALTIJD terugdraaien")
w("  raise exception 'PROEFRUN_KLAAR (alles teruggedraaid)%', r;")
w("end $proef$;")
print("\n".join(out))

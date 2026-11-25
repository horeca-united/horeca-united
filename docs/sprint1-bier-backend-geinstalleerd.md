# HUOS Biercollectief – werkelijke Supabase-backendstatus (10 november 2026)

## Geïnstalleerd
In project `yyvzqnjumnpotawnrvfw` is de **additieve migratie** `huos_bier_scan_backend_sprint1_base` succesvol toegepast. Zes nieuwe tabellen:
- `public.bier_leads`: bedrijfs- en contactdata, brouwerij, tapbier, distributeur (incl. Bidfood), fustprijs, jaarvolume 2025 en kwaliteit/herkomst, bonussen, contract, afnameverplichting, tapinstallatie, financiering, overstapbereidheid, intentie bij vraag 13, machtiging, leadstatus, herkomst/campagne, opvolgdatum.
- `public.bier_lead_preferences`: herinneringskeuze en aparte marketingtoestemming.
- `public.bier_lead_documents`: per lead gekoppeld uploadmetadata en acceptatiestatus.
- `public.bier_lead_email_events`: bedankmail, herinnering dag 3 en dag 10, idempotentie, retry/status.
- `public.bier_lead_activity`: interne opvolgtijdlijn.
- `public.bier_scan_funnel_events`: per scan sessie gebeurtenis zonder IP of cookie-identiteit.

Alle zes tabellen hebben RLS. Alleen `bier_leads`, `bier_lead_preferences` en `bier_lead_documents` hebben een beperkte eigenaar-SELECT-policy en SELECT-grant voor geauthenticeerden; er zijn **geen client writes**. Email/activiteit/funnel zijn afgeschermd; server/service_role kan deze muteren. Er zijn geen oude tabellen of data gemigreerd.

## Nog NIET geïmplementeerd
1. Definitieve Quick Scan op frontend (de proefversie staat alleen in ChatGPT); huidige generieke website schrijft niet naar `bier_leads`.
2. Server-verified intake, privacy/consent flow, lead-eigenaarschap, machtiging, admin rol en geautoriseerde beheer-endpoints.
3. Upload-to-lead koppeling, uitgaande emailprovider, veilige cron worker en automatische dag 3/10-reminders.
4. Auth-geteste beheerinterface en dashboards. Geen actuele tellingen op website; oude beheerscherm bevat demogegevens.
5. RLS integratietests met twee gescheiden testaccounts en veilige pilotreview.
6. Geautomatiseerde funnel events en daadwerkelijke gerealiseerde leveranciersbesparingen.

## Praktische queries – uitsluitend Supabase SQL Editor / geautoriseerde admin server
Geen persoonlijke gegevens exporteren naar de browser zonder geautoriseerde admin-endpoint.

```sql
-- Nieuwe leads en opvolgacties
select id,company_name,city,brewery_supplier,tap_beer_brand,distributor,
 annual_volume_hl,annual_volume_source,proposal_interest,willingness_to_switch,
 contract_end_status,brewery_loan_status,stage,missing_fields,next_follow_up_at,created_at
from public.bier_leads
order by created_at desc limit 100;

-- Pipeline: commerciële interesse apart van bereidheid tot overstappen
select proposal_interest,willingness_to_switch,count(*) as bedrijven,
 count(annual_volume_hl) as volume_bekend,
 coalesce(sum(annual_volume_hl),0) as volume_hl,
 coalesce(sum(annual_volume_hl) filter(where annual_volume_source in ('document_verified','supplier_verified')),0) as geverifieerd_hl
from public.bier_leads
where stage <> 'closed'
group by 1,2 order by bedrijven desc;

-- Brouwerijvolume: ruwe indicatie vs gecontroleerd
select coalesce(brewery_supplier,'Onbekend') as brouwerij,count(*) as leads,
 coalesce(sum(annual_volume_hl),0) as potentieel_hl,
 coalesce(sum(annual_volume_hl) filter (where annual_volume_source in ('document_verified','supplier_verified')),0) as gecontroleerd_hl
from public.bier_leads where stage <> 'closed'
group by 1 order by potentieel_hl desc;

-- Ontbrekende documenten / dagelijkse acties
select l.id,l.company_name,l.stage,l.data_route,l.missing_fields,
 p.upload_reminders_enabled,l.next_follow_up_at
from public.bier_leads l left join public.bier_lead_preferences p on p.lead_id=l.id
where l.stage in ('new','awaiting_upload','mandate_pending','contact_needed','review_needed')
order by l.next_follow_up_at nulls last,l.created_at;

-- Funnel (pas betekenisvol na implementatie events)
select event_type,step_number,count(*) from public.bier_scan_funnel_events group by 1,2 order by 1,2;
```

## Ontwerpwaarborgen
- Zelf opgegeven volume mag nooit stilzwijgend als geverifieerd worden aangemerkt; optellen in hl alleen binnen consistent jaar/scope en geen dubbel getelde vestigingen.
- Een keuze om afnamegegevens op te vragen is **geen machtiging**; alleen expliciet goedgekeurde machtiging met passend doel/scope.
- Bij lening=ja/onbekend alleen interne follow-up, geen automatisch financieel oordeel.
- Vraag 13 bewaart `yes`, `maybe` of `insight_only` zonder marketingtoestemming af te leiden.
- E-mailreminders standaard UIT tot de expliciete keuze uit de scan is vastgelegd.
- De test/demo website en bestaande imports zijn geen bron voor echte KPI's.
- Drie informatieve security advisor-meldingen: no-policy op interne RLS-tabellen is intentioneel; oudere projectwaarschuwingen voor pg_net in public en gelekte-wachtwoordbescherming vereisen aparte beoordeling.

## Ontwikkelomgeving
Feature branch: `feature/sprint1-bier-lead-opvolging`. Let op: Supabase-migratie is op project toegepast (niet een aparte databasebranch); productiegebruik van deze nieuwe tabellen blijft geblokkeerd totdat server intake en auth klaar zijn.

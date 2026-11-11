# HUOS v2 — digitale horecamanager: technische architectuur en behoud v1
Status: goedgekeurde richting, **ontwerp in GitHub**. Geen productie-frontend of -database gewijzigd door dit document.
Datum: 11 november 2026.

## Productbelofte
HUOS is primair een persoonlijke digitale bedrijfsmanager voor horecaondernemers.
Drie pijlers: **inzicht** (eigen data), **begeleiding** (controleerbare signalen) en **voordeel** (o.a. inkoopcollectieven).
Collectieve bierinkoop is de eerste commerciële module, niet het gehele product.

## Versiebeheer
- Bestaande `main` is de huidige website en blijft onaangetast.
- Onveranderde referentiebranch: `archive/huos-platform-v1-2026-11` vanaf `main`. **Git-branch, geen volledige database-, storage- of deploymentbackup.**
- Actieve ontwikkeling: `feature/huos-digitale-manager-v2` vanaf `feature/sprint1-bier-lead-opvolging`. Pas na testen PR richting main.
- Niet de publieke GitHub Pages-site omzetten zolang intake, toegang, real-data-KPI's en tests niet zijn gevalideerd.

## Bestaande code: hergebruiken, repareren of vervangen
- Hergebruiken: Supabase client/Auth, documentupload+extract-pdf, categorieoverzicht, contractreminders, bestaande styling/cards, navigatiepatronen, voorstellen.
- Aanpassen: `src/app.js` Dashboard en QuickScan, `src/body.html` schermen, `src/style.css`, intern AdminApp.
- Vervangen: `Engine.computeResult()` huidige niet-onderbouwde 'besparingen' (algemene aannames van 4-10% etc); `Engine.profileCompletion()` op 6 willekeurige signalen; hardcoded admin-leads.
- Browser `localStorage` alleen voor tijdelijke conceptinvoer/UI (niet als zakelijke bron van waarheid).
- `index.html` is build-uitvoer: alleen `src/` aanpassen en via `build.js` genereren.

## Doelarchitectuur, gefaseerd
```
Landingspagina + algemene Quick Scan + Bier Quick Scan
             |
Supabase Auth (persoon) -> Organisaties -> Leden & rollen
             |                          |
             +---- documentuploads ----+---- contracten ----+
             |                          |                     |
        extractie/OCR              verificatielaag        deadlines
             \                         |                     /
              -> gestructureerde kosten / volumes / bronnen
                             |
               gecontroleerde HUOS signalen
                             |
          ondernemerdashboard + interne admin cockpit
                             |
         kansen, voorstellen, opvolging, opt-in meldingen
```
Gebruik één `organization_id` als tenant-key. User IDs zijn personen; e-mail is NIET de autorisatiesleutel. Ondersteun meer vestigingen onder een onderneming (site/vestiging afzonderlijk), en eventueel meerdere ondernemingen per gebruiker.
**Fase 1 hoeft geen complete boekhoud/AI-app te zijn.** Eerst veilige registratie + bruikbare contract-/documentanalyse.

## Minimale gegevensobjecten voor v2 (concept, nog niet gemigreerd)
1. `organizations`: bedrijfsnaam, soort horeca, vestigingsplaats, KvK optioneel; auth/user koppeling via `organization_members` met owner/admin/member.
2. `locations`: vestigingen; onderscheid organisatiebreed vs vestigingspecifiek.
3. `organization_categories`: geselecteerde besparingsonderwerpen, prioriteit, staat van gegevens.
4. `documents`: eigenaar/organisatie/vestiging, categorie, private storage path, checksum, documenttype, datum, verwerkingsstatus, verwerkingsfout, aanleverroute, bewaarbeleid.
5. `extracted_facts`: één gecontroleerd gegeven per bron met type, waarde, eenheid, periode, `source_document_id`, `confidence`, status (`extracted`, `user_confirmed`, `verified`, `rejected`), beoordeeld door/tijdstip. Scheid feiten van schattingen en conclusies.
6. `contracts`: leverancier, dienst, start/einddatum, opzegdeadline, verlengingsregel, verplichtingen en documentreferentie. Geen alarm op niet-gecontroleerde data zonder toelichting.
7. `insights`: type, bewijs/bronids, geldigheid, zekerheid, belangrijkheid, eigenaar, status, actie. Alleen concrete bedragen als aantoonbaar herleidbaar uit feiten/aanbiedingen.
8. `tasks` / `notifications`: acties, toegewezen persoon, deadline, notificatievoorkeur, herinnering, afgehandeld.
9. `supplier_offers` / `proposals`: bestaande voorstellen zo veel mogelijk hergebruiken; berekende en geverifieerde voordelen apart.
10. `audit_events`: kritieke data- en toegangswijzigingen, niet onbeperkt ruwe persoonsgegevens loggen.
11. Bestaande `bier_leads` + gekoppelde records blijven commerciële intake; verbind uiteindelijk via organisatie/tenant-ID zonder eerdere data te overschrijven.

## Slimme, goedkope introductie: eerst de gegevensmanager, dan de 'AI-manager'
- Startpagina na login: 'Dit vraagt vandaag je aandacht', 'Jouw data', 'Contracten', 'Kosten per categorie', 'Kansen'. Niet starten met fictieve €-besparingskaarten.
- Datadekking: score per categorie op *aanwezigheid, actualiteit, volledigheid en verificatiestatus* met gewichten die je zichtbaar uitlegt; geen score gebaseerd op uploadvolume alleen.
- Documentextractie: bestaande `extract-pdf` testen, output normaliseren naar facts, discrepanties als controletaak. Extractie is nooit bewijs dat fact correct is.
- Eerst deterministische controles: naderende opzegdatum, prijsverandering voor zelfde product en eenheid/periode, ontbrekende gegevens. Daarna pas AI-Q&A met verwijzingen naar bronfacturen/contracten (geen ongefundeerde claims).
- Voor financiële vergelijking: normaliseer leverancier, VAT/ex-VAT, periode, eenheid, fustgrootte, kortingsafspraken, vestiging en contractduur. Maak ontbrekende data expliciet.
- Exact Online later als read-only connector met intrekbare toestemming en sync-log; geen verplichte koppeling.

## Interne beheeromgeving — bestaand AdminApp ombouwen tot cockpit
Navigatie:
1. **Vandaag**: opvolgtaken, contractdeadlines, extractiefouten, nieuwe scans; aantallen van echte records.
2. **Ondernemingen**: zoek/funnel, profielvolledigheid, vestigingen, bronstatus, contact.
3. **Documenten & controles**: nieuw, in verwerking, afwijking, goedgekeurd, fout; bron-document naast extractie.
4. **Contracten**: per maand deadline/opzegging, leverancier, vestiging, bronbewijs.
5. **Biercollectief**: filters op volume (opgegeven/geverifieerd apart), brouwerij, tapbier, distributeur, financiering, overstapbereidheid, voorstel-intentie, mail/mandaatstaat.
6. **Kansen & voorstellen**: kansen, voorstelhistorie, geaccepteerd/afgewezen met reden, werkelijk gerealiseerde voordelen.
7. **Inzicht & groei**: conversiefunnel per categorie en campagne, doorlooptijd upload, documentenkwaliteit, activeringsgraad.
8. **Systeembeheer**: rolbeheer, privacyrechten, foutlogs, audittrail, consent.

Filters en acties moeten server-side worden geautoriseerd. Bestaande `admin_users` niet vertrouwen zonder controle op RLS/policies; nooit een publiek toegankelijke adminlijst.

## Sprintvolgorde
S0: backup/branch ✅; code en DB inventarisatie ✅; PR/architectuurdocument ✅ zodra geschreven.
S1: org/rollen + authenticated tenant ownership + RLS tests, beveiligde intake; nieuwe algemene Quick Scan gekoppeld aan organisatie.
S2: document-library, veilige upload en extractiebron, validatie en contract/actie-model; bestaand dashboard met echte data.
S3: interne cockpit met document- en leadfunnel, belangrijke alerts, admin rollen.
S4: Bier Quick Scan koppelen, alleen geverifieerde bierprijsvergelijking, concrete voorstellen, reminders en toestemmingen.
S5: trends en AI-antwoord met bronverwijzingen, latere boekhoudkoppeling en kostenvergelijking per vestiging.

## Vereiste acceptatietests
- A kan geen bedrijfsgegevens van B lezen of wijzigen, ook niet via het endpoint/storage pad.
- Admin toegang alleen met servergecontroleerde rol; alleen toegestane ondernemingen.
- Gegevens uit oude v1 intact, nieuwe migraties additief/rollbackbaar.
- Document met onjuiste extractie geeft controletaak, geen definitief financieel signaal.
- Contractdeadline werkt met expliciet geverifieerde datum en opzegtermijn.
- Geen algemene 'besparingsindicatie' zonder herleidbare aannames.
- Als klant 'Weet ik niet' kiest blijft onboarding mogelijk; we verwerken ontbrekende gegevens als vervolgstap.
- Testdata en productieanalyse staan gescheiden.
- Marketing en operationele berichten gescheiden; opt-out wordt nageleefd.

## Huidige toestand (11 november 2026)
- Project `yyvzqnjumnpotawnrvfw` heeft bestaande public-tabellen voor transacties, uploads, profielen, machtigingen, contractreminders en 6 RLS-beveiligde bierleadtabellen.
- Vier bestaande Edge Functions: `extract-pdf`, `send-upload-confirmation`, `send-contract-reminders`, `notify-proposal`.
- De bierlead-structuur is aanwezig maar heeft nog geen werkende intake/frontend of uitgaande mailqueue.
- **Nieuwe organisatie-/fact-/insighttabellen hierboven zijn alleen een voorstel**, niet geïnstalleerd.

## Eerste visuele ontwerpprioriteit
Behoud kleurgebruik en rustige typografie van v1; voeg toe aan ondernemerdashboard:
* Mijn HUOS, Mijn gegevens, Contracten & kosten, Mijn digitale manager, Kansen & inkoop.
Vermijd een dashboard dat uitsluitend als sales-funnel aanvoelt; belangrijkste acties zijn bedrijfsinzicht en tijdige signalen.

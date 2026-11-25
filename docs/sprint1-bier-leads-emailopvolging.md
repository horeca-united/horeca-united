# HUOS Sprint 1 — bierleads, documenten en e-mailopvolging
**Status: ontwikkelontwerp op feature branch; NIET live.**

## Bevestigde productkeuzes
- Bier is de commerciële instap; groothandel en energie krijgen later eigen modules op dezelfde gegevensbasis.
- Wanneer bierprijs, volume of contracteinddatum onbekend is: kies `Weet ik niet`; vervolgens eenmaal keuze `Later uploaden` of `Machtig Horeca United`. Upload tijdens de gewone scan is optioneel.
- Sla de aanvraag meteen op, ook zonder documenten. Het niet weten van bierprijzen geeft **geen** negatieve leadscore.
- Een nieuw geregistreerde lead ontvangt eenmaal een bedankmail met knop **Mijn gegevens aanvullen** naar veilig portaal.
- Op dag 3 en dag 10 maximaal één uploadherinnering per stap, uitsluitend als route = later_uploaden, nog geen relevant document veilig is ontvangen, lead open is, voorkeuren toestaan en geen eerdere gelijke e-mail is verzonden.
- Na relevante upload stoppen de generieke uploadherinneringen direct; bij afkeuring of onvolledige AI-extractie creëert HUOS een interne controle-taak. Voor machtigingsleads loopt een aparte opvolgflow, niet de uploadherinneringen.
- Marketing staat standaard uit en is afzonderlijk opt-in. Optionele herinneringsvoorkeuren zijn zichtbaar en aanpasbaar; opt-out stopt toekomstige herinneringen. Transactionele bevestiging van een aangevraagde scan is los van marketing.

## Leadbeheer / filters voor de beheerder

Beheerweergave: **Bierleads** met zoekfunctie en gecombineerde filters:

| Filter | Waarden |
| --- | --- |
| Fase | nieuwe lead, contact nodig, wacht op upload, machtiging afhandelen, document ontvangen, controle nodig, klaar voor voorstel, voorstel verzonden, klant, gesloten |
| Ontbrekende info | huidige leverancier, merk standaard tappils, fustformaat, fustprijs excl. btw, jaarlijkse afname, contracteinde, kortings-/bonusvoorwaarden |
| Documentstatus | geen, ontvangen, verwerken, controleren, goedgekeurd, afgewezen |
| Mailstatus | bedankmail niet/verzonden; dag-3 niet/verzonden; dag-10 niet/verzonden; fout; overgeslagen; herinneringen uitgezet |
| Leadprioriteit | hoog, midden, laag of onbekend; uitsluitend bekende factoren |
| Tijd | aanmelddatum, laatste reactie, laatste upload, dagen sinds aanvraag, contracteinde |
| Overig | leverancier, pilsmerk, regio, contactverantwoordelijke, kanaal, interesse in voorstel |

Noodzakelijke kolommen: onderneming, contact, type bier, volume, ontbrekende info, fase, documenten, bedankmail, herinnering 1, herinnering 2, laatste activiteit, volgende actie, eigenaar. Klik op lead -> tijdlijn van scan, mails, uploads, controles en voorstellen.

**Presets**
1. **Direct opvolgen:** interesse=ja én klaar voor voorstel OF concreet contractmoment.
2. **Gegevens ontbreken:** geen relevant bestand; route=later_uploaden.
3. **Na eerste herinnering:** dag-3 verzonden, dag-10 nog niet verzonden, document ontbreekt.
4. **Na tweede herinnering:** dag-10 verzonden, document ontbreekt; voorstel handmatige opvolging, geen 3e automatische mail.
5. **Document binnen, nog controleren:** verwerking of beoordeling open.
6. **Machtiging aangevraagd:** route=machtigen en uitvoering nog open.
7. **Technische problemen:** e-mailfouten en upload/extractiefouten.

## Funnelmeting

Meet aantallen + conversies per lead/cohort (geen fictieve demo-bedrijven):
- scan gestart -> scan afgerond -> lead aangemaakt -> bedankmail verzonden
- upload voltooid vóór dag 3; na eerste herinnering, vóór dag 10; na tweede herinnering
- document geldig verklaard -> voorstel mogelijk -> voorstel verzonden -> akkoord
- e-mailbezorgingsstatus indien provider die levert (bezorgd, gebounced); **niet** e-mailopeningen als betrouwbare KPI
- mediane dagen tot eerste upload, percentage ontbrekende velden, percentage upload/verwerkingsfouten
- uitsplitsing per pilsmerk, leverancier, afnameband, regio en gekozen route (alleen als groep voldoende groot; geen herkenbare benchmarkdata)

Voor causale beweringen over effect van reminders is een latere gecontroleerde A/B-test nodig; gewone funnelcijfers zijn geen bewijs dat een mail upload veroorzaakt.

## Technische route

- Project: `yyvzqnjumnpotawnrvfw`; frontend `src/app.js` + `src/body.html`, gegenereerd naar `index.html` via `build.js`.
- Gebruik Supabase Auth (magic-link) voor portaltoegang, `auth.uid()` + organisatie/tenant-id voor rechten; e-mailadres **niet** als enige eigendomscontrole.
- E-mailknop verwijst naar de applicatie en logt de gebruiker veilig in. Geen onbeschermde, langdurig geldige token in querystring en geen publieke bestandslink.
- Server-side Edge Function voor intake en e-mailqueue, met geauthentiseerde eigenaar of streng gevalideerd beveiligd intakeproces. Laat credentials uitsluitend in Supabase secret store staan.
- Worker/cron verwerkt uitgaande e-mailqueue: transactie/invoer eerst opnieuw controleren, idempotency key per lead/soort uniek, atomaire claim, rate-limits, retry, log verzonden/fout; verzend nooit opnieuw na opt-out/gesloten status/ontvangen upload.
- Transactionele provider/SMTP + SPF/DKIM/DMARC configureren voordat live mails worden verstuurd. Bestaand STRATO-postvak alleen is geen gegarandeerde geautomatiseerde verzendinfra.
- Beperk `admin`-inzage via server-side rollen; geen globale `select *` uit de browser voor normale klanten.
- Gebruik voorgesteld datamodel in `docs/sql/sprint1_bier_leads_draft.sql`; **niet toepassen** voor RLS, end-to-end auth, storage, e-mailprovider, deployment en tests gecontroleerd zijn.
- Bewaar datum van voorkeurwijzigingen en bewijs/versie van toestemmingen. Opzeglink voor marketing; in portaal mogelijkheid herinneringen uit te zetten.
- E-mailbijlagen naar `info@horecaunited.nl` worden in Sprint 1 niet automatisch verwerkt. Een eventuele inbound-mailparser is een apart beveiligd traject.

## Acceptatiecriteria (voor eerste echte pilot)
- Een deelnemer kan 'Weet ik niet' op meerdere velden selecteren en afronden; er ontstaat precies één lead en maximaal één bedankmail.
- Medewerker filtert afzonderlijk `ontbrekende afname`, `dag-3 verstuurd`, `dag-10 verstuurd`, `upload ontbreekt`, en combinaties.
- Relevante upload vóór geplande herinnering verhindert verzending; upload tijdens queueverwerking wordt opnieuw gecontroleerd.
- Er volgt nooit een dag-10 e-mail na een geslaagde relevante upload.
- Nieuwe leads zien uitsluitend eigen bestanden; onbevoegde medewerkers zien geen leadinformatie.
- Bij uitgeschakelde herinneringen, opgeheven machtiging of gesloten lead worden geen reminders verzonden.
- Kanalen en acties worden meetbaar gelogd; demodata uitgesloten.
- Uitsluitend transactionele mail bij aanvraag; marketingopt-in apart en standaard uit.

## Uitvoeringstoestand
Alleen ontwerp en SQL-voorstel in GitHub. **Geen databasewijzigingen, geen cronjobs, geen mailverzending, geen feature live.**

# HUOS 2.0 – eerste ingebouwde frontend (11 november 2026)

## Wat daadwerkelijk is gebouwd
Op branch `feature/huos-digitale-manager-v2`:
- `src/body.html`: nieuw scherm `#screen-manager` met vijf tabs: Mijn overzicht, Mijn gegevens, Contracten & acties, Mijn inzichten, Kansen & inkoop. Desktop en mobiele navigatie hebben een ingang.
- `src/style.css`: eigen responsive stijlen, in de bestaande rustige v1-huisstijl.
- `src/app.js`: `ManagerV2` leest gegevens alleen na Supabase Auth en gebruikt bestaande RLS-beschermde tabellen `profiles`, `uploads`, `transactions` en `contract_reminders`. Er worden geen klantgegevens naar nieuwe tabellen geschreven.
- Bestaande algemene Quick Scan, uploads en het oude dashboard blijven beschikbaar. De toegang tot het nieuwe scherm is apart.
- Inloggen vanuit de manager ververst het managerscherm in plaats van terug te springen naar het legacy-dashboard.

## Echte functionele inhoud
- Aantal geregistreerde uploads, transactieregels, gemarkeerde contractregels, open contractmeldingen.
- Vijf expliciete gegevensgroepen met alleen de status 'Aanwezig / Aanvullen' (geen geclaimde kwaliteits- of gezondheidspercentage).
- Relevante vervolgstappen op basis van ontbrekende gegevens.
- Uploadcategorieën, contractregels met beschikbare actie- en verlengdatum, bestaande contractherinneringen.
- Inzichten: aantal voorkomende inkoopcategorieën en datadekking, met transparante beperking.
- Kansen: biercollectief en andere categorieën als toekomstige modules.

## Bewuste grenzen
- Geen fictieve geldbesparingen op het nieuwe managerscherm.
- De bestaande `Engine.computeResult()` in de legacy Quick Scan **is nog niet vervangen** en toont elders nog onbetrouwbare generieke schattingen. Niet presenteren als echte resultaten; vereist aparte wijziging.
- RLS is de werkelijke autorisatie; e-mailfilter is extra queryscope, geen beveiligingsgarantie. Bestaande legacy e-mail-RLS moet later naar UUID/organisatie/leden worden gemigreerd.
- Eén account = één e-mail-gefilterd profiel in dit eerste scherm; meerdere vestigingen en org-ledensysteem zijn nog NIET beschikbaar.
- Lijstqueries hebben limieten; bij 1000 transacties/uploads of 200 alerts geeft UI een plus-achtige telling, geen exact totaal.
- Het beheerscherm is nog de oude demo-app, niet vervangen. Geen database DDL of mailworkers gedeployed.
- Ruwe `amount` uit verschillende eenheden wordt bewust niet opgeteld tot één misleidende besparingssom.
- De oude website op `main` en de bewaarde branch `archive/huos-platform-v1-2026-11` blijven ongewijzigd.

## Validatie
- Code gelezen uit de ontwikkelbranch en geparseerd met een JavaScript-parser via `new Function`: geslaagd.
- Controleren aanwezigheid router, manager-scherm, styles, nav en build-template: geslaagd.
- Volledige browser-E2E, twee gescheiden klanten, RLS-isolatie, documentupload en publicatie: nog NIET uitgevoerd.
- `build.js` zet de bestanden in `index.html` samen. Gepubliceerde GitHub Pages-website blijft op main.

## Volgende ontwikkeling
1. Tenant/organisatie met leden/RLS in een geïsoleerde testomgeving en migraties.
2. Documentlibrary met bronbewijs, extractiecontrole en validatie.
3. Actielijst en inzichten met geverifieerde brongegevens.
4. Interne HUOS-commandocentrum ombouwen van demo naar geautoriseerd werkend beheer.
5. Bier Quick Scan & algemene bedrijfsintake verbinden aan centrale organisatie.

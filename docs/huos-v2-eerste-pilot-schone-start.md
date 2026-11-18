# HUOS 2.0 – pilot 1 (schone start zonder historische uploads)
Status: databasebasis toegepast; frontend uitsluitend op ontwikkelbranch, nog geen publieke preview of productie-uitrol.
Datum: 11 november 2026.

## Afgesproken
Eerste tester gebruikt een bestaande Supabase Auth-login, maar begint in HUOS v2 met een **nieuw, leeg bedrijfsprofiel**. Oude uploads, transacties, historische documentextracties en browser-demo-state worden nooit geïmporteerd in het pilotdashboard. Er is niets verwijderd uit legacy.

## Gebouwd
Databaseproject `yyvzqnjumnpotawnrvfw`:
- `public.huos_pilot_organizations`: id (UUID), owner_id auth.uid, bedrijfsnaam, type, plaats, tijdstip, één eerste pilotomgeving per persoon (unieke owner).
- `public.huos_pilot_documents`: UUID, org-id, uploader uid, storage_path, bestandsnaam, type, categorie, status en uploadtijdstip.
- Private Supabase Storage bucket `huos-pilot-private` (PDF/PNG/JPG, 10 MB); bestanden onder `<auth.uid()>/<org-id>/<random UUID>.<ext>`.
- RLS voor organisaties, metadata en storage. Gewone gebruiker kan alleen eigen organisatie/data zien en in een eigen pad uploaden. Geen publieke URL of globale adminread.
- Migraties: `huos_v2_pilot_isolated_organizations_documents`, `huos_pilot_storage_owner_path_policy_fix`.

Frontend op `feature/huos-digitale-manager-v2`:
- Beveiligde eerste login via bestaande Supabase Auth.
- Eerste aanmaak met bedrijfsnaam, horecatype en vestigingsplaats; **geen prefill vanuit oude profielen**.
- Lege start met 0 documenten en 0 gecontroleerde gegevens.
- Documentupload naar speciale private bucket, metadata naar nieuwe documents table, alleen voor actief ingelogde eigenaar.
- Nieuwe documentlijst, eerste stappen, voorlopig contractoverzicht, expliciet geen kunstmatige bedragen of analyses.
- Formulier heeft nog geen AI-documentextractie en geen verwerking van financiële bedragen.

## Tests uitgevoerd
- Syntactische JS-codecontrole in ontwikkelbranch: geslaagd.
- Statische controle op tabellen, bucket, nieuwe schermen: geslaagd.
- Geauthenticeerde `INSERT` voor eigen testbedrijf in `BEGIN ... ROLLBACK`: geslaagd.
- Cross-account RLS: eerste geauthenticeerde gebruiker legt testbedrijf aan, tweede ziet nul records, daarna rollback: geslaagd.
- Storage-policies gecontroleerd op **storage.objects.name**, expliciete correctie toegepast.
- Database heeft na tests 0 pilotbedrijven en 0 pilotdocumenten.
- Nog NIET gedaan: echte browser/e-mail magic-link login test, uploadtest met echte PDF en twee actieve clients, bevestiging documentextractie, staginghosting.

## Aandachtspunten vóór uitnodiging externe testpersonen
- De v1-privacypagina bevat nog placeholders; invullen en juridisch/operationeel controleren. Pilotgebruikers voorlopig alleen eigen zakelijke bestanden, geen extra persoonsgegevens of gezondheidsinformatie.
- Storage uploads werken los van legacy extract-pdf; extractie moet later veilig per org worden gekoppeld.
- Bij storage upload gelukt maar metadataregistratie mislukt: bestand kan verweesd achterblijven. Later server-side herstellogica/opruimtaak.
- Echte publieke preview vereist aparte staging deployment, geldige Auth Redirect URL en browsertest. Niets op main publiceren totdat dat gevalideerd is.
- Bestaande oude dashboard blijft technisch beschikbaar en kan historische data tonen. Voor v2-pilot uitsluitend scherm 'Mijn digitale manager' gebruiken. Niet beweren dat bestanden gewist zijn.
- Voor productie uitbreiden naar meer eigenaars/medewerkers per organisatie, rollen, locatie en geverifieerde documentfeiten.

## Eerste testscript voor de ondernemer (na staging)
1. Log in met je bestaande account. Open 'Mijn digitale manager'.
2. Je ziet onboarding voor **nieuwe** bedrijfsaangifte, niet je oude documenten.
3. Maak het eerste bedrijfsprofiel aan.
4. Controleer dat 'Nieuwe documenten' op 0 staat.
5. Voeg één eigen zakelijke PDF of afbeelding toe via 'Mijn gegevens'.
6. Controleer dat exact één document verschijnt met status ontvangen en dat oude bestanden er niet tussen staan.
7. Log uit en in; controleer dat pilotprofiel en document blijven staan.
8. Test later met tweede account dat pilotdocumenten niet uitleesbaar zijn.

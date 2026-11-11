# HUOS 2.0 — beveiliging en toekomstige Turnstile-activatie

Status: **Cloudflare Turnstile voorlopig uitgeschakeld**, op verzoek (11 november 2026). Dit document betreft alleen de **afgeschermde privé-pilot** in `pilot-v2/`. Verander de openbare HUOS-website of de hoofdbranch niet.

## Huidige beveiliging

- HTTPS wordt door Vercel afgehandeld; HSTS wordt door het platform teruggestuurd.
- `pilot-v2/vercel.json` bevat extra headers: `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy`, `Permissions-Policy`, `Cross-Origin-Opener-Policy` en een beperkte `Content-Security-Policy` met `frame-ancestors 'none'`, `base-uri 'self'`, `object-src 'none'`, `form-action 'self'`, `upgrade-insecure-requests`.
- Een volledig strenge `script-src` CSP is **nog niet actief**. Het bestaande `index.html` bevat inline scripts en inline event handlers; eerst vervangen door aparte scripts en event listeners en daarna CSP gefaseerd aanscherpen.
- De Supabase Edge Function `huos-beer-intake` gebruikt CORS voor alleen de officiële pilot-origin, `Cache-Control: no-store`, en enkele API-securityheaders.
- De aanvraag-API heeft een honeypot en rate limiting: 10 verzoeken per uur per gehashte IP-waarde en 4 per uur per gehasht e-mailadres. **Security follow-up**: `cf-connecting-ip` kan bij een rechtstreekse aanroep van de Supabase-functie niet zonder aanvullende vertrouwde proxy-controle als authentiek worden beschouwd. Het e-mailquotum is onafhankelijk; stel voor een publieke lancering betrouwbare edge-IP-derivatie, aanvullende botchecks en abuse monitoring in.
- Admin-data blijft achter RLS en wordt niet publiek leesbaar gemaakt.

## Later activeren: Cloudflare Turnstile

- Een frontend-widget en backend-verificatie van Turnstile zijn al voorbereid, maar worden pas ingeschakeld wanneer **beide** Supabase Edge Function omgevingsvariabelen beschikbaar zijn:
  - `HUOS_TURNSTILE_SITE_KEY`: openbare sitekey.
  - `HUOS_TURNSTILE_SECRET_KEY`: **geheim**, uitsluitend als server-side secret configureren. Nooit in GitHub of frontend publiceren.
- Maak in Cloudflare Turnstile een widget aan voor `huos-v2-prive-pilot.vercel.app` (bij de openbare lancering hostnaam aanpassen).
- Configureer beide sleutels in de Supabase **Edge Function secrets** van project `yyvzqnjumnpotawnrvfw`. Het huidige frontend haalt alleen de sitekey via de configuratie-GET van de Edge Function op.
- Wanneer beide sleutels aanwezig zijn, gaat de API ontbrekende/ongeldige tokens weigeren. De frontend laadt dan het Cloudflare-script en stuurt een token mee.
- Backend controleert bij `siteverify` op `success`, de exacte `hostname` en `action='beer_intake'`. Controleer tijdens activatie tokenverloop, dubbel gebruik, netwerkfouten en bijbehorende gebruikservaring.
- **Niet eerder activeren**: sleutelconfiguratie zonder werkende client kan inzendingen blokkeren.
- Volledige end-to-end test vóór publieke lancering: zonder token geweigerd, ongeldig/verlopen token geweigerd, geldig token geaccepteerd, herhaalde token geweigerd; API-limieten en honeypot blijven van kracht.
- Eventuele overzetting naar een nieuw domein vereist update van de exact toegestane origin en de hostnamecheck; wijzig deze niet voordat de site verhuist.

## Beveiligingscontrole bij lancering

1. Controleer werkelijke HTTPS-redirect en HSTS op de live hostname.
2. Controleer alle beveiligingsheaders in live HTTP-responses, zowel HTML als API, inclusief CORS.
3. Controleer dat auth en publieke scan blijven werken onder de CSP.
4. Bevestig dat Vercel Authentication voor de privé-pilot aan staat.
5. Controleer trusted proxy/IP-integriteit, rate limiting en Turnstile vóór publiek verkeer.
6. Controleer dat machtigingen alleen als **pending** worden opgeslagen totdat bevoegdheid is geverifieerd.

-- Machtiging versie 3, stap 2: tekstversie 3 en uitgebreide klantweergave.
--  * huos_mandate_texts: versie 'huos-mandate-v3' (concept, akkoord Hui 19-11-2026; jurist volgt).
--  * huos_my_mandate(): levert nu ook boekjaar-voorstellen, perioden, ondertekeningen en geldigheid; toont tekst v3.
-- Rollback: huos_my_mandate uit 20261118040000 terugzetten. Tekstversies zijn append-only en blijven staan.

insert into public.huos_mandate_texts (version, title, body) values ('huos-mandate-v3', 'Machtiging leveranciersgegevens opvragen',
'Met deze machtiging geef ik, namens {bedrijf} (KvK {kvk}), Aziaat Holding B.V. (KvK 73911437), handelend onder de naam Horeca United, toestemming om inkoopgegevens op te vragen, te ontvangen en te verwerken bij deze leveranciers: {leveranciers}.

Welke gegevens?
- Afnamegegevens: welke producten mijn onderneming heeft ingekocht en in welke hoeveelheden.
- Inkoopprijzen: de daadwerkelijk gefactureerde prijzen, inclusief direct toegepaste kortingen.

Over welke periode? {periode}. Bij een lopend boekjaar gaat het om gegevens tot de datum van opvragen, uiterlijk de laatste dag van dat boekjaar.

Waarvoor? Horeca United gebruikt mijn gegevens om mijn inkoopkosten te analyseren, prijsstijgingen te signaleren en mogelijke besparingen te onderzoeken. Daarnaast mag Horeca United samengevoegde gegevens, die niet tot mijn onderneming te herleiden zijn, gebruiken om betere collectieve inkoopvoorwaarden te onderzoeken en te onderhandelen.

Mijn individuele inkoopprijzen, facturen en bedrijfsgegevens worden niet gedeeld met andere deelnemende ondernemers of met andere leveranciers, tenzij ik daar afzonderlijk toestemming voor geef.

Wat mag Horeca United niet? Namens mijn onderneming bestellingen plaatsen, contracten afsluiten, bestaande contracten wijzigen of contracten opzeggen. Voor aanvullende gegevens, zoals jaarbonussen en contractvoorwaarden, vraagt Horeca United indien nodig afzonderlijk toestemming.

Geldigheid en intrekken. Deze machtiging geldt tot ik haar intrek, maar uiterlijk 24 maanden na ondertekening. Ik kan haar op elk moment binnen HUOS intrekken, voor één leverancier of volledig. Daarna worden op basis van die machtiging geen nieuwe gegevens meer opgevraagd.

Bewaren. Ontvangen gegevens bewaart Horeca United zolang ik deelneem en daarna maximaal 2 jaar, tenzij ik eerder om verwijdering vraag en de wet dat toestaat.');

create or replace function public.huos_my_mandate()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid := public.huos_my_org_id(); o record; v_m record; v_sup jsonb := '[]'; v_prop jsonb := '[]'; v_text jsonb;
  v_per jsonb := '[]'; v_sig jsonb := '[]';
begin
  if v_org is null or not exists (select 1 from public.huos_org_features where organization_id = v_org and feature = 'mandate') then
    return jsonb_build_object('enabled', false);
  end if;
  select * into o from public.huos_pilot_organizations where id = v_org;
  select jsonb_build_object('version', version, 'title', title, 'body', body) into v_text
  from public.huos_mandate_texts where version like 'huos-mandate-v3%' order by created_at desc limit 1;
  select * into v_m from public.huos_beer_mandates where organization_id = v_org and status in ('pending','verified');
  if v_m.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.supplier_name, 'role', s.role, 'scope', s.scope, 'status', s.status,
             'revoked_at', s.revoked_at,
             'request', (select jsonb_build_object('status', r.status, 'sent_at', r.sent_at, 'answered_at', r.answered_at)
                         from public.huos_beer_mandate_requests r where r.supplier_id = s.id and r.status <> 'cancelled'
                         order by r.created_at desc limit 1)) order by s.status, s.supplier_name), '[]')
      into v_sup from public.huos_beer_mandate_suppliers s where s.mandate_id = v_m.id;
    select coalesce(jsonb_agg(jsonb_build_object('start', period_start, 'end', period_end, 'kind', kind, 'label', label) order by period_start), '[]')
      into v_per from public.huos_mandate_periods where mandate_id = v_m.id;
    select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'kind', g.kind, 'signed_at', g.signed_at, 'signer', g.signer_name,
             'function', g.signer_function, 'suppliers', g.suppliers, 'pdf', g.pdf_document_id is not null, 'pdf_document_id', g.pdf_document_id,
             'text', g.text_rendered, 'version', g.text_version, 'hash', g.text_sha256) order by g.signed_at), '[]')
      into v_sig from public.huos_mandate_signatures g where g.mandate_id = v_m.id;
  end if;
  with cand as (
    select btrim(l.supplier) as name, (array_agg(l.category order by l.amount_excl_vat desc nulls last))[1] as cat
    from public.huos_cost_lines l
    where l.organization_id = v_org and l.category in ('groothandel','food','vis','wijn','drank','bier','fris','vlees','agf','zuivel','brood','gedistilleerd')
      and length(btrim(coalesce(l.supplier,''))) >= 2
    group by btrim(l.supplier)
    union
    select btrim(b.answers->>'brewery_supplier'), 'brouwerij' from public.huos_pilot_beer_scans b
    where b.organization_id = v_org and length(btrim(coalesce(b.answers->>'brewery_supplier',''))) >= 2
      and lower(b.answers->>'brewery_supplier') not in ('other','unknown','anders','onbekend')
    union
    select btrim(b.answers->>'distributor'), 'drank' from public.huos_pilot_beer_scans b
    where b.organization_id = v_org and length(btrim(coalesce(b.answers->>'distributor',''))) >= 2
      and lower(b.answers->>'distributor') not in ('other','unknown','direct','anders','onbekend')
  )
  select coalesce(jsonb_agg(jsonb_build_object('name', c.name, 'role', public.huos_mandate_guess_role(c.name, c.cat),
           'scope', case when public.huos_mandate_guess_role(c.name, c.cat) = 'brouwerij'
                         then '["volume","prices","discounts","bonuses","contract_terms"]'::jsonb
                         else '["volume","prices","discounts"]'::jsonb end) order by c.name), '[]')
    into v_prop
  from (select distinct on (lower(name)) name, cat from cand order by lower(name)) c
  where not exists (select 1 from public.huos_beer_mandate_suppliers s
                    where s.mandate_id = v_m.id and s.status <> 'revoked' and lower(btrim(s.supplier_name)) = lower(c.name));
  return jsonb_build_object('enabled', true, 'text', v_text, 'suppliers', v_sup, 'proposals', v_prop, 'periods', v_per, 'signatures', v_sig,
    'org', jsonb_build_object('name', o.name, 'kvk', o.kvk_number),
    'fiscal', jsonb_build_object('start_month', o.fiscal_year_start_month,
                                 'options', public.huos_fiscal_period_options(o.fiscal_year_start_month, current_date)),
    'mandate', case when v_m.id is null then null else jsonb_build_object('id', v_m.id, 'status', v_m.status,
      'signer_name', v_m.signer_name, 'signer_function', v_m.signer_function, 'consent_at', v_m.consent_at,
      'text_version', v_m.consent_text_version, 'verified_at', v_m.authority_checked_at,
      'valid_until', v_m.valid_until, 'kind', v_m.kind, 'v3', v_m.consent_text_version like 'huos-mandate-v3%') end);
end $$;

-- HUOS 2.0 — migratie huos_beer_lead_workflow_base
-- Toegepast op project yyvzqnjumnpotawnrvfw op 13-11-2026 (na proefrun 109/109 en akkoord eigenaar).
-- Rollback-instructies: zie docs in supabase/proposals/20261112_huos_beer_lead_workflow_PROPOSAL.sql

create table public.huos_beer_leads (
 id                 uuid primary key default gen_random_uuid(),
 submission_id      uuid not null unique
 references public.huos_beer_intake_submissions(id) on delete restrict,
 stage              text not null default 'new' check (stage in (
 'new','contact_needed','awaiting_upload','mandate_pending',
 'document_received','review_needed','ready_for_offer',
 'offer_sent','customer','closed')),
 stage_changed_at   timestamptz not null default now(),
 assigned_to        uuid references auth.users(id) on delete set null,
 priority           text not null default 'unknown'
 check (priority in ('high','medium','low','unknown')),
 next_follow_up_at  timestamptz,
 closed_reason      text check (closed_reason is null or length(closed_reason) <= 500),
 region             text check (region is null or length(region) <= 80),  -- voor toekomstig bereik per regio
 organization_id    uuid,               -- voor toekomstige koppeling aan onderneming (geen FK nu)
 retention_until    timestamptz,       -- gezet bij afsluiten, zie AVG-paragraaf
 erased_at          timestamptz,       -- gezet na AVG-verwijderverzoek
 created_at         timestamptz not null default now(),
 updated_at         timestamptz not null default now(),
 constraint huos_beer_leads_closed_reason_chk
 check (stage <> 'closed' or closed_reason is not null)
);
create index huos_beer_leads_stage_idx    on public.huos_beer_leads (stage, next_follow_up_at);
create index huos_beer_leads_assigned_idx on public.huos_beer_leads (assigned_to) where assigned_to is not null;
create function public.huos_staff_can_access_lead(p_lead uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
 select coalesce((
 select case
 when s.role = 'admin' or s.scope = 'all' then true
 when s.scope = 'assigned'     then l.assigned_to = s.user_id
 when s.scope = 'region'       then l.region = any (s.scope_values)
 when s.scope = 'organization' then l.organization_id::text = any (s.scope_values)
 else false end
 from public.huos_staff s, public.huos_beer_leads l
 where s.user_id = (select auth.uid()) and s.active and l.id = p_lead), false)
$$;
revoke all on function public.huos_staff_can_access_lead(uuid) from public, anon;
grant execute on function public.huos_staff_can_access_lead(uuid) to authenticated;
comment on table public.huos_beer_leads is
 'Interne opvolging per Bier Quick Scan-inzending. Bevat bewust geen persoonsgegevens; die blijven in huos_beer_intake_submissions.';
create table public.huos_beer_stage_transitions (
 from_stage  text not null,
 to_stage    text not null,
 min_role    text not null default 'reviewer' check (min_role in ('reviewer','admin')),
 primary key (from_stage, to_stage)
);
insert into public.huos_beer_stage_transitions (from_stage, to_stage, min_role) values
 ('new','contact_needed','reviewer'),('new','awaiting_upload','reviewer'),
 ('new','mandate_pending','reviewer'),('new','review_needed','reviewer'),('new','closed','reviewer'),
 ('contact_needed','awaiting_upload','reviewer'),('contact_needed','mandate_pending','reviewer'),
 ('contact_needed','review_needed','reviewer'),('contact_needed','closed','reviewer'),
 ('awaiting_upload','document_received','reviewer'),('awaiting_upload','contact_needed','reviewer'),
 ('awaiting_upload','closed','reviewer'),
 ('mandate_pending','document_received','reviewer'),('mandate_pending','contact_needed','reviewer'),
 ('mandate_pending','closed','reviewer'),
 ('document_received','review_needed','reviewer'),('document_received','awaiting_upload','reviewer'),
 ('document_received','closed','reviewer'),
 ('review_needed','ready_for_offer','reviewer'),('review_needed','awaiting_upload','reviewer'),
 ('review_needed','contact_needed','reviewer'),('review_needed','closed','reviewer'),
 ('ready_for_offer','offer_sent','reviewer'),('ready_for_offer','review_needed','reviewer'),
 ('ready_for_offer','closed','reviewer'),
 ('offer_sent','customer','reviewer'),('offer_sent','review_needed','reviewer'),('offer_sent','closed','reviewer'),
 ('customer','closed','admin'),
 ('closed','contact_needed','admin');   -- heropenen alleen door admin
create table public.huos_beer_lead_notes (
 id           uuid primary key default gen_random_uuid(),
 lead_id      uuid not null references public.huos_beer_leads(id) on delete cascade,
 author_id    uuid references auth.users(id) on delete set null,
 body         text not null check (length(trim(body)) between 1 and 4000),
 created_at   timestamptz not null default now(),
 redacted_at  timestamptz,
 redacted_by  uuid references auth.users(id) on delete set null
);
create index huos_beer_lead_notes_lead_idx on public.huos_beer_lead_notes (lead_id, created_at desc);
comment on column public.huos_beer_lead_notes.body is
 'Zakelijke notitie. Geen bijzondere persoonsgegevens (gezondheid e.d.) of privéomstandigheden vastleggen.';
create table public.huos_beer_lead_documents (
 id                 uuid primary key default gen_random_uuid(),
 lead_id            uuid not null references public.huos_beer_leads(id) on delete cascade,
 doc_type           text not null check (doc_type in (
 'invoice','annual_statement','supplier_statement',
 'beer_contract','loan_agreement','installation_agreement',
 'authority_proof','other')),
 status             text not null default 'received' check (status in (
 'received','processing','accepted','rejected','deleted')),
 storage_bucket     text not null default 'huos-beer-lead-private'
 check (storage_bucket = 'huos-beer-lead-private'),
 storage_path       text not null unique
 check (storage_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(pdf|png|jpg)$'),
 original_filename  text check (original_filename is null or length(original_filename) <= 255),
 mime_type          text not null check (mime_type in ('application/pdf','image/png','image/jpeg')),
 size_bytes         integer not null check (size_bytes between 1 and 15728640),
 sha256             text check (sha256 is null or sha256 ~ '^[0-9a-f]{64}$'),
 uploaded_via       text not null check (uploaded_via in ('upload_link','staff')),
 upload_request_id  uuid,              -- FK in fase 2 (upload-links)
 received_at        timestamptz not null default now(),
 reviewed_by        uuid references auth.users(id) on delete set null,
 reviewed_at        timestamptz,
 review_note        text check (review_note is null or length(review_note) <= 1000),
 deleted_at         timestamptz
);
create index huos_beer_lead_documents_lead_idx on public.huos_beer_lead_documents (lead_id, received_at desc);
comment on column public.huos_beer_lead_documents.storage_path is
 'Server-gegenereerd: <lead_id>/<random uuid>.<ext>. Nooit afgeleid van de bestandsnaam.';
create table public.huos_beer_lead_verifications (
 id               uuid primary key default gen_random_uuid(),
 lead_id          uuid not null references public.huos_beer_leads(id) on delete cascade,
 field            text not null check (field in (
 'annual_volume_hl','keg_price_ex_vat','keg_size_l','contract_end_date',
 'bonus_status','purchase_obligation','installation_status',
 'brewery_loan_status','brewery_supplier','tap_beer_brand','distributor')),
 period_year      smallint check (period_year is null or period_year between 2020 and 2100),
 submitted_value  jsonb,               -- momentopname van het oorspronkelijke antwoord
 verified_value   jsonb not null,      -- door Horeca United bevestigde waarde
 unit             text not null check (unit in ('hl','eur_ex_vat','liter','date','text')),
 outcome          text not null check (outcome in ('confirmed','corrected','retracted')),
 evidence_kind    text not null check (evidence_kind in (
 'document','supplier_statement','invoice','call_note','legacy_import')),
 document_id      uuid references public.huos_beer_lead_documents(id) on delete set null,
 note             text not null check (length(trim(note)) between 5 and 1000),
 supersedes_id    uuid references public.huos_beer_lead_verifications(id),
 verified_by      uuid references auth.users(id) on delete set null,
 verified_at      timestamptz not null default now(),
 constraint huos_beer_verif_hl_year_chk
 check (field <> 'annual_volume_hl' or period_year is not null),
 constraint huos_beer_verif_hl_unit_chk
 check (field <> 'annual_volume_hl' or unit = 'hl')
);
create index huos_beer_lead_verif_lookup_idx
 on public.huos_beer_lead_verifications (lead_id, field, period_year, verified_at desc);
comment on table public.huos_beer_lead_verifications is
 'Append-only. Een correctie of intrekking is een nieuwe regel (supersedes_id); oude regels blijven bewaard.';
create table public.huos_beer_mandates (
 id                      uuid primary key default gen_random_uuid(),
 lead_id                 uuid not null unique references public.huos_beer_leads(id) on delete cascade,
 consent_text_version    text not null,
 consent_at              timestamptz not null,
 authority_asserted      boolean not null,
 status                  text not null default 'pending'
 check (status in ('pending','verified','rejected','revoked')),
 authority_check_method  text check (authority_check_method in (
 'kvk_extract','owner_confirmation','signed_statement','other')),
 authority_checked_by    uuid references auth.users(id) on delete set null,
 authority_checked_at    timestamptz,
 authority_note          text check (authority_note is null or length(authority_note) <= 1000),
 revoked_at              timestamptz,
 revoked_via             text check (revoked_via in ('email','phone','in_person','other')),
 revoked_reason          text check (revoked_reason is null or length(revoked_reason) <= 1000),
 created_at              timestamptz not null default now(),
 updated_at              timestamptz not null default now(),
 constraint huos_beer_mandates_verified_chk check (
 status <> 'verified' or (authority_check_method is not null
 and authority_checked_by is not null
 and authority_checked_at is not null)),
 constraint huos_beer_mandates_revoked_chk check (
 status <> 'revoked' or revoked_at is not null)
);
comment on table public.huos_beer_mandates is
 'Levende machtigingsstatus. huos_beer_intake_submissions.mandate_status blijft de stand op het moment van inzenden.';
create table public.huos_beer_mandate_requests (
 id                    uuid primary key default gen_random_uuid(),
 mandate_id            uuid not null references public.huos_beer_mandates(id) on delete restrict,
 supplier_name         text not null check (length(trim(supplier_name)) between 2 and 160),
 channel               text not null check (channel in ('email','portal','phone','letter')),
 scope                 text[] not null check (scope <@ array[
 'volume','prices','discounts','bonuses','contract_terms']::text[]
 and cardinality(scope) > 0),
 status                text not null default 'draft'
 check (status in ('draft','approved','sent','answered','cancelled')),
 drafted_by            uuid references auth.users(id) on delete set null,
 approved_by           uuid references auth.users(id) on delete set null,
 sent_at               timestamptz,
 answered_at           timestamptz,
 response_document_id  uuid references public.huos_beer_lead_documents(id) on delete set null,
 created_at            timestamptz not null default now(),
 constraint huos_beer_mreq_four_eyes_chk check (
 approved_by is null or approved_by is distinct from drafted_by)
);
create table public.huos_beer_lead_events (
 id           bigint generated always as identity primary key,
 lead_id      uuid references public.huos_beer_leads(id) on delete set null,
 actor_id     uuid,                -- geen FK: log blijft bestaan als account vervalt
 actor_role   text,
 event_type   text not null check (event_type ~ '^[a-z_]{3,60}$'),
 entity       text,
 entity_id    text,
 details      jsonb not null default '{}'::jsonb
 check (pg_column_size(details) <= 4000),
 created_at   timestamptz not null default now()
);
create index huos_beer_lead_events_lead_idx on public.huos_beer_lead_events (lead_id, created_at desc);
comment on table public.huos_beer_lead_events is
 'Append-only audittrail. details bevat veldnamen en interne waarden, géén naam/e-mail/telefoon van de ondernemer.';
create trigger huos_beer_lead_events_append_only
 before update or delete on public.huos_beer_lead_events
 for each row execute function public.huos_block_mutation();
create trigger huos_beer_lead_verifications_append_only
 before update or delete on public.huos_beer_lead_verifications
 for each row execute function public.huos_block_mutation();
create function public.huos_beer_log(
 p_lead uuid, p_event text, p_entity text, p_entity_id text, p_details jsonb)
returns void language sql security definer set search_path = ''
as $$
 insert into public.huos_beer_lead_events (lead_id, actor_id, actor_role, event_type, entity, entity_id, details)
 values (p_lead, (select auth.uid()), public.huos_staff_role(), p_event, p_entity, p_entity_id,
 coalesce(p_details, '{}'::jsonb));
$$;
revoke all on function public.huos_beer_log(uuid,text,text,text,jsonb) from public, anon, authenticated;
create function public.huos_touch_updated_at()
returns trigger language plpgsql set search_path = ''
as $$ begin new.updated_at := now(); return new; end $$;
create trigger huos_beer_leads_touch   before update on public.huos_beer_leads
 for each row execute function public.huos_touch_updated_at();
create trigger huos_beer_mandates_touch before update on public.huos_beer_mandates
 for each row execute function public.huos_touch_updated_at();
alter table public.huos_beer_leads              enable row level security;
alter table public.huos_beer_stage_transitions  enable row level security;
alter table public.huos_beer_lead_notes         enable row level security;
alter table public.huos_beer_lead_documents     enable row level security;
alter table public.huos_beer_lead_verifications enable row level security;
alter table public.huos_beer_mandates           enable row level security;
alter table public.huos_beer_mandate_requests   enable row level security;
alter table public.huos_beer_lead_events        enable row level security;
revoke all on public.huos_beer_leads, public.huos_beer_stage_transitions,
 public.huos_beer_lead_notes, public.huos_beer_lead_documents, public.huos_beer_lead_verifications,
 public.huos_beer_mandates, public.huos_beer_mandate_requests, public.huos_beer_lead_events
 from anon, authenticated;
grant select on public.huos_beer_leads, public.huos_beer_stage_transitions,
 public.huos_beer_lead_notes, public.huos_beer_lead_documents, public.huos_beer_lead_verifications,
 public.huos_beer_mandates, public.huos_beer_mandate_requests, public.huos_beer_lead_events
 to authenticated;
create policy huos_beer_leads_staff_read on public.huos_beer_leads for select to authenticated
 using (public.huos_staff_can_access_lead(id));
create policy huos_beer_transitions_staff_read on public.huos_beer_stage_transitions for select to authenticated
 using (public.huos_staff_has('viewer'));
create policy huos_beer_notes_staff_read on public.huos_beer_lead_notes for select to authenticated
 using (public.huos_staff_can_access_lead(lead_id));
create policy huos_beer_docs_staff_read on public.huos_beer_lead_documents for select to authenticated
 using (public.huos_staff_can_access_lead(lead_id));
create policy huos_beer_verif_staff_read on public.huos_beer_lead_verifications for select to authenticated
 using (public.huos_staff_can_access_lead(lead_id));
create policy huos_beer_mandates_staff_read on public.huos_beer_mandates for select to authenticated
 using (public.huos_staff_can_access_lead(lead_id));
create policy huos_beer_mreq_staff_read on public.huos_beer_mandate_requests for select to authenticated
 using (public.huos_staff_has('reviewer') and exists (
 select 1 from public.huos_beer_mandates m where m.id = mandate_id and public.huos_staff_can_access_lead(m.lead_id)));
create policy huos_beer_events_staff_read on public.huos_beer_lead_events for select to authenticated
 using (public.huos_staff_has('admin')
 or (public.huos_staff_has('reviewer') and lead_id is not null
 and public.huos_staff_can_access_lead(lead_id)
 and event_type not like 'gdpr_%' and event_type <> 'export'));
create policy huos_beer_intake_staff_select on public.huos_beer_intake_submissions
 for select to authenticated using (exists (
 select 1 from public.huos_beer_leads l
 where l.submission_id = huos_beer_intake_submissions.id
 and public.huos_staff_can_access_lead(l.id)));
create view public.huos_beer_lead_overview with (security_invoker = true) as
with latest_hl as (
 select distinct on (v.lead_id) v.lead_id, v.outcome, v.verified_value, v.period_year, v.verified_at
 from public.huos_beer_lead_verifications v
 where v.field = 'annual_volume_hl'
 order by v.lead_id, v.verified_at desc
)
select
 l.id                     as lead_id,
 s.id                     as submission_id,
 s.created_at             as submitted_at,
 s.company_name, s.contact_name, s.email, s.phone,
 s.answers->>'brewery_supplier'      as brewery_supplier,
 s.answers->>'tap_beer_brand'        as tap_beer_brand,
 s.answers->>'distributor'           as distributor,
 s.answers->>'proposal_interest'     as proposal_interest,
 s.answers->>'willingness_to_switch' as willingness_to_switch,
 s.answers->>'contract_end_status'   as contract_end_status,
 s.data_route,
 (s.answers->>'annual_volume_hl')::numeric as hl_submitted,
 2025                                      as hl_submitted_year,   -- scanversie huos-beer-2026-11 vraagt naar 2025
 case when h.outcome in ('confirmed','corrected') then (h.verified_value #>> '{}')::numeric end as hl_verified,
 case
 when h.outcome in ('confirmed','corrected')                         then 'verified'
 when nullif(s.answers->>'annual_volume_hl','') is null              then 'unknown'
 when s.answers->>'annual_volume_source' = 'invoice'                 then 'reported_invoice'
 when s.answers->>'annual_volume_source' = 'supplier_statement'      then 'reported_supplier'
 when s.answers->>'annual_volume_source' = 'own_estimate'            then 'estimated'
 else 'unknown'
 end                                        as hl_quality,
 coalesce(m.status, 'not_requested')        as mandate_status_current,
 l.stage, l.assigned_to, l.priority, l.next_follow_up_at, l.updated_at
from public.huos_beer_leads l
join public.huos_beer_intake_submissions s on s.id = l.submission_id
left join latest_hl h on h.lead_id = l.id
left join public.huos_beer_mandates m on m.lead_id = l.id
where l.erased_at is null;
revoke all on public.huos_beer_lead_overview from anon, authenticated;
grant select on public.huos_beer_lead_overview to authenticated;
create function public.huos_beer_ensure_lead(p_submission uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_lead uuid; v_sub record;
begin
 select id into v_lead from public.huos_beer_leads where submission_id = p_submission;
 if v_lead is not null then return v_lead; end if;
 select id, data_route, mandate_consent_version, mandate_consent_at, mandate_authority_asserted
 into v_sub from public.huos_beer_intake_submissions where id = p_submission;
 if not found then raise exception 'Onbekende inzending'; end if;
 insert into public.huos_beer_leads (submission_id, stage)
 values (p_submission, case when v_sub.data_route = 'mandate' then 'mandate_pending' else 'new' end)
 on conflict (submission_id) do nothing
 returning id into v_lead;
 if v_lead is null then
 select id into v_lead from public.huos_beer_leads where submission_id = p_submission;
 return v_lead;
 end if;
 if v_sub.data_route = 'mandate' then
 insert into public.huos_beer_mandates (lead_id, consent_text_version, consent_at, authority_asserted)
 values (v_lead, v_sub.mandate_consent_version, v_sub.mandate_consent_at, v_sub.mandate_authority_asserted);
 end if;
 perform public.huos_beer_log(v_lead, 'lead_created', 'submission', p_submission::text,
 jsonb_build_object('data_route', v_sub.data_route));
 return v_lead;
end $$;
revoke all on function public.huos_beer_ensure_lead(uuid) from public, anon, authenticated;
create function public.huos_beer_lead_set_stage(p_lead uuid, p_to text, p_note text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_from text; v_min text; v_has_hl boolean;
begin
 if not public.huos_staff_has('reviewer') or not public.huos_staff_can_access_lead(p_lead) then
 raise exception 'Niet bevoegd'; end if;
 select stage into v_from from public.huos_beer_leads where id = p_lead and erased_at is null for update;
 if v_from is null then raise exception 'Onbekende lead'; end if;
 select min_role into v_min from public.huos_beer_stage_transitions
 where from_stage = v_from and to_stage = p_to;
 if v_min is null then raise exception 'Overgang % -> % is niet toegestaan', v_from, p_to; end if;
 if not public.huos_staff_has(v_min) then raise exception 'Deze overgang vereist rol %', v_min; end if;
 if p_to = 'closed' and length(trim(coalesce(p_note,''))) < 5 then
 raise exception 'Geef een reden voor afsluiten'; end if;
 if p_to = 'ready_for_offer' then
 select exists(select 1 from public.huos_beer_lead_verifications
 where lead_id = p_lead and field = 'annual_volume_hl'
 and outcome in ('confirmed','corrected')) into v_has_hl;
 if not v_has_hl and length(trim(coalesce(p_note,''))) < 10 then
 raise exception 'Klaar voor voorstel zonder geverifieerde hl vereist een onderbouwing (min. 10 tekens)';
 end if;
 end if;
 update public.huos_beer_leads
 set stage = p_to, stage_changed_at = now(),
 closed_reason = case when p_to = 'closed' then trim(p_note) when v_from = 'closed' then null else closed_reason end,
 retention_until = case when p_to = 'closed' then now() + interval '12 months'
 when v_from = 'closed' then null else retention_until end
 where id = p_lead;
 perform public.huos_beer_log(p_lead, 'stage_changed', 'lead', p_lead::text,
 jsonb_build_object('from', v_from, 'to', p_to, 'note', left(p_note, 500)));
end $$;
create function public.huos_beer_lead_assign(p_lead uuid, p_user uuid, p_follow_up timestamptz default null, p_priority text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_old record;
begin
 if not public.huos_staff_has('reviewer') or not public.huos_staff_can_access_lead(p_lead) then
 raise exception 'Niet bevoegd'; end if;
 if not public.huos_staff_has('admin') and p_user is distinct from (select auth.uid()) then
 raise exception 'Alleen beheerders kunnen leads aan anderen toewijzen'; end if;
 if p_user is not null and not exists (select 1 from public.huos_staff where user_id = p_user and active and role in ('reviewer','admin')) then
 raise exception 'Verantwoordelijke moet een actieve reviewer of admin zijn'; end if;
 if p_priority is not null and p_priority not in ('high','medium','low','unknown') then
 raise exception 'Ongeldige prioriteit'; end if;
 select assigned_to, next_follow_up_at, priority into v_old
 from public.huos_beer_leads where id = p_lead and erased_at is null for update;
 if not found then raise exception 'Onbekende lead'; end if;
 update public.huos_beer_leads
 set assigned_to = p_user, next_follow_up_at = p_follow_up, priority = coalesce(p_priority, priority)
 where id = p_lead;
 perform public.huos_beer_log(p_lead, 'lead_assigned', 'lead', p_lead::text,
 jsonb_build_object('assigned_from', v_old.assigned_to, 'assigned_to', p_user,
 'follow_up_from', v_old.next_follow_up_at, 'follow_up_to', p_follow_up,
 'priority_from', v_old.priority, 'priority_to', coalesce(p_priority, v_old.priority)));
end $$;
create function public.huos_beer_lead_add_note(p_lead uuid, p_body text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid;
begin
 if not public.huos_staff_has('reviewer') or not public.huos_staff_can_access_lead(p_lead) then
 raise exception 'Niet bevoegd'; end if;
 if not exists (select 1 from public.huos_beer_leads where id = p_lead and erased_at is null) then
 raise exception 'Onbekende lead'; end if;
 insert into public.huos_beer_lead_notes (lead_id, author_id, body)
 values (p_lead, (select auth.uid()), trim(p_body)) returning id into v_id;
 perform public.huos_beer_log(p_lead, 'note_added', 'note', v_id::text, '{}'::jsonb);  -- tekst niet in log
 return v_id;
end $$;
create function public.huos_beer_lead_verify(
 p_lead uuid, p_field text, p_period_year smallint, p_value jsonb, p_unit text,
 p_outcome text, p_evidence_kind text, p_note text, p_document uuid default null)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_prev uuid; v_submitted jsonb;
begin
 if not public.huos_staff_has('reviewer') or not public.huos_staff_can_access_lead(p_lead) then
 raise exception 'Niet bevoegd'; end if;
 if p_outcome not in ('confirmed','corrected','retracted') then raise exception 'Ongeldige uitkomst'; end if;
 if p_evidence_kind = 'legacy_import' then raise exception 'Bronsoort niet toegestaan'; end if;
 if p_evidence_kind = 'document' and p_document is null then
 raise exception 'Koppel het document dat als bewijs dient'; end if;
 if p_document is not null and not exists (
 select 1 from public.huos_beer_lead_documents
 where id = p_document and lead_id = p_lead and status <> 'deleted') then
 raise exception 'Document hoort niet bij deze lead'; end if;
 if p_field = 'annual_volume_hl' and p_outcome <> 'retracted' then
 if jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric < 0
 or (p_value #>> '{}')::numeric > 100000 then
 raise exception 'Hectoliters moet een getal tussen 0 en 100000 zijn'; end if;
 end if;
 select s.answers -> p_field into v_submitted
 from public.huos_beer_leads l join public.huos_beer_intake_submissions s on s.id = l.submission_id
 where l.id = p_lead and l.erased_at is null;
 if not found then raise exception 'Onbekende lead'; end if;
 select id into v_prev from public.huos_beer_lead_verifications
 where lead_id = p_lead and field = p_field and period_year is not distinct from p_period_year
 order by verified_at desc limit 1;
 if p_outcome = 'retracted' and v_prev is null then raise exception 'Er is niets om in te trekken'; end if;
 insert into public.huos_beer_lead_verifications
 (lead_id, field, period_year, submitted_value, verified_value, unit, outcome,
 evidence_kind, document_id, note, supersedes_id, verified_by)
 values (p_lead, p_field, p_period_year, v_submitted, coalesce(p_value, 'null'::jsonb), p_unit, p_outcome,
 p_evidence_kind, p_document, trim(p_note), v_prev, (select auth.uid()))
 returning id into v_id;
 perform public.huos_beer_log(p_lead, 'field_verified', 'verification', v_id::text,
 jsonb_build_object('field', p_field, 'period_year', p_period_year, 'outcome', p_outcome,
 'evidence_kind', p_evidence_kind, 'value', p_value));
 return v_id;
end $$;
create function public.huos_beer_mandate_decide(
 p_mandate uuid, p_status text, p_method text default null, p_note text default null,
 p_revoked_via text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_old text; v_lead uuid;
begin
 if not public.huos_staff_has('reviewer') then raise exception 'Niet bevoegd'; end if;
 select status, lead_id into v_old, v_lead from public.huos_beer_mandates where id = p_mandate for update;
 if v_old is null or not public.huos_staff_can_access_lead(v_lead) then raise exception 'Onbekende machtiging'; end if;
 if v_old = 'revoked' then raise exception 'Een ingetrokken machtiging kan niet worden heropend'; end if;
 if p_status not in ('verified','rejected','revoked') then raise exception 'Ongeldige status'; end if;
 if p_status = 'verified' and (p_method is null or length(trim(coalesce(p_note,''))) < 5) then
 raise exception 'Leg vast hoe de bevoegdheid is gecontroleerd (methode + notitie)'; end if;
 if p_status = 'revoked' and p_revoked_via is null then raise exception 'Leg vast hoe is ingetrokken'; end if;
 update public.huos_beer_mandates set
 status = p_status,
 authority_check_method = case when p_status in ('verified','rejected') then p_method else authority_check_method end,
 authority_checked_by   = case when p_status in ('verified','rejected') then (select auth.uid()) else authority_checked_by end,
 authority_checked_at   = case when p_status in ('verified','rejected') then now() else authority_checked_at end,
 authority_note         = case when p_status in ('verified','rejected') then trim(p_note) else authority_note end,
 revoked_at     = case when p_status = 'revoked' then now() else revoked_at end,
 revoked_via    = case when p_status = 'revoked' then p_revoked_via else revoked_via end,
 revoked_reason = case when p_status = 'revoked' then left(trim(p_note), 1000) else revoked_reason end
 where id = p_mandate;
 if p_status in ('revoked','rejected') then
 update public.huos_beer_mandate_requests set status = 'cancelled'
 where mandate_id = p_mandate and status in ('draft','approved');
 end if;
 perform public.huos_beer_log(v_lead, 'mandate_' || p_status, 'mandate', p_mandate::text,
 jsonb_build_object('from', v_old, 'to', p_status, 'method', p_method));
end $$;
create function public.huos_beer_export_leads(p_stage text default null)
returns setof public.huos_beer_lead_overview
language plpgsql security definer set search_path = ''
as $$
declare v_n int;
begin
 if not public.huos_staff_has('admin') then raise exception 'Export alleen voor beheerders'; end if;
 select count(*) into v_n from public.huos_beer_lead_overview o where p_stage is null or o.stage = p_stage;
 perform public.huos_beer_log(null, 'export', 'lead_overview', null,
 jsonb_build_object('rows', v_n, 'stage_filter', p_stage));
 return query select * from public.huos_beer_lead_overview o where p_stage is null or o.stage = p_stage;
end $$;
revoke all on function public.huos_beer_lead_set_stage(uuid,text,text)                     from public, anon;
revoke all on function public.huos_beer_lead_assign(uuid,uuid,timestamptz,text)            from public, anon;
revoke all on function public.huos_beer_lead_add_note(uuid,text)                           from public, anon;
revoke all on function public.huos_beer_lead_verify(uuid,text,smallint,jsonb,text,text,text,text,uuid) from public, anon;
revoke all on function public.huos_beer_mandate_decide(uuid,text,text,text,text)           from public, anon;
revoke all on function public.huos_beer_export_leads(text)                               from public, anon;
grant execute on function public.huos_beer_lead_set_stage(uuid,text,text)                  to authenticated;
grant execute on function public.huos_beer_lead_assign(uuid,uuid,timestamptz,text)         to authenticated;
grant execute on function public.huos_beer_lead_add_note(uuid,text)                        to authenticated;
grant execute on function public.huos_beer_lead_verify(uuid,text,smallint,jsonb,text,text,text,text,uuid) to authenticated;
grant execute on function public.huos_beer_mandate_decide(uuid,text,text,text,text)        to authenticated;
grant execute on function public.huos_beer_export_leads(text)                            to authenticated;
select public.huos_beer_ensure_lead(id) from public.huos_beer_intake_submissions;
insert into public.huos_beer_lead_verifications
 (lead_id, field, period_year, submitted_value, verified_value, unit, outcome,
 evidence_kind, note, verified_by, verified_at)
select l.id, 'annual_volume_hl', 2025, s.answers->'annual_volume_hl', s.answers->'annual_volume_hl', 'hl',
 'confirmed', 'legacy_import', coalesce(s.annual_volume_verification_note, 'Overgenomen uit huos_beer_verify_hl'),
 s.annual_volume_verified_by, s.annual_volume_verified_at
from public.huos_beer_intake_submissions s
join public.huos_beer_leads l on l.submission_id = s.id
where s.annual_volume_verified_at is not null;
comment on table public.bier_leads is
 'NIET IN GEBRUIK sinds HUOS 2.0 (nov 2026). Vervangen door huos_beer_intake_submissions + huos_beer_leads. Verwijderen alleen na apart akkoord.';
comment on table public.bier_lead_activity     is 'NIET IN GEBRUIK — zie huos_beer_lead_events.';
comment on table public.bier_lead_documents    is 'NIET IN GEBRUIK — zie huos_beer_lead_documents.';
comment on table public.bier_lead_preferences  is 'NIET IN GEBRUIK — contactvoorkeuren volgen in fase 3.';
comment on table public.bier_lead_email_events is 'NIET IN GEBRUIK — e-mailqueue volgt in fase 3.';
comment on table public.bier_scan_funnel_events is 'NIET IN GEBRUIK.';

-- HUOS 2.0 — Meldingen bij de klant + voorstelaanvragen (stap 1 + 2)
-- Nieuw:
--   huos_customer_notices            meldingen die een medewerker aan de klant toont (bijv. kostenstijging)
--   huos_proposal_requests           "Stuur mij een voorstel"-aanvragen van de klant
--   huos_proposal_request_events     logboek per aanvraag (alleen toevoegen)
--   RPC's: huos_notice_publish, huos_notice_withdraw, huos_notice_mark_read,
--          huos_request_proposal, huos_request_update
-- Schrijven gaat uitsluitend via deze functies (server-side gecontroleerd); niemand krijgt directe
-- INSERT/UPDATE/DELETE-rechten op de tabellen. Raakt geen bestaande gegevens.
-- Terugdraaien: zie onderaan.

-- 1. Meldingen
create table public.huos_customer_notices (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  kind             text not null check (kind in ('cost_increase','custom')),
  source_key       text check (source_key is null or length(source_key) <= 120),
  source           jsonb not null default '{}'::jsonb,
  title            text not null check (length(btrim(title)) between 3 and 140),
  body             text not null check (length(btrim(body)) between 3 and 1500),
  personal_note    text check (personal_note is null or length(personal_note) <= 1000),
  cta              text not null default 'proposal' check (cta in ('proposal','upload','none')),
  status           text not null default 'published' check (status in ('published','withdrawn')),
  published_at     timestamptz not null default now(),
  published_by     uuid not null references auth.users(id),
  withdrawn_at     timestamptz,
  withdrawn_by     uuid references auth.users(id),
  read_at          timestamptz,
  created_at       timestamptz not null default now()
);
create index on public.huos_customer_notices (organization_id, published_at desc);
create unique index huos_customer_notices_one_live on public.huos_customer_notices (organization_id, source_key)
  where status = 'published' and source_key is not null;
comment on table public.huos_customer_notices is
  'HUOS meldingen aan de klant (bijv. kostenstijging), gepubliceerd door een medewerker. Schrijven alleen via RPC.';

-- 2. Voorstelaanvragen
create table public.huos_proposal_requests (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  notice_id        uuid references public.huos_customer_notices(id) on delete set null,
  contract_id      uuid references public.huos_pilot_contracts(id) on delete set null,
  origin           text not null check (origin in ('notice','contract','general')),
  subject          text not null check (length(btrim(subject)) between 2 and 200),
  customer_message text check (customer_message is null or length(customer_message) <= 1000),
  status           text not null default 'new' check (status in ('new','in_progress','proposal_sent','closed')),
  assigned_to      uuid references auth.users(id) on delete set null,
  requested_by     uuid not null references auth.users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index on public.huos_proposal_requests (organization_id, created_at desc);
create index on public.huos_proposal_requests (status, created_at desc);
create unique index huos_proposal_requests_open_notice on public.huos_proposal_requests (notice_id)
  where notice_id is not null and status <> 'closed';
create unique index huos_proposal_requests_open_contract on public.huos_proposal_requests (contract_id)
  where contract_id is not null and status <> 'closed';

create table public.huos_proposal_request_events (
  id               bigint generated always as identity primary key,
  request_id       uuid not null references public.huos_proposal_requests(id) on delete cascade,
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  actor_id         uuid,
  actor_role       text,
  event            text not null check (event in ('created','status','note')),
  from_status      text,
  to_status        text,
  note             text check (note is null or length(note) <= 2000),
  created_at       timestamptz not null default now()
);
create index on public.huos_proposal_request_events (request_id, created_at);
create trigger huos_proposal_request_events_append_only before update or delete on public.huos_proposal_request_events
  for each row execute function public.huos_cost_audit_guard();

-- 3. RLS + rechten: alleen lezen via policies; schrijven via RPC
alter table public.huos_customer_notices enable row level security;
alter table public.huos_proposal_requests enable row level security;
alter table public.huos_proposal_request_events enable row level security;

create policy huos_notices_staff_read on public.huos_customer_notices for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_notices_owner_read on public.huos_customer_notices for select to authenticated
  using (status = 'published' and exists (select 1 from public.huos_pilot_organizations o
         where o.id = organization_id and o.owner_id = (select auth.uid())));

create policy huos_requests_staff_read on public.huos_proposal_requests for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_requests_owner_read on public.huos_proposal_requests for select to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o
         where o.id = organization_id and o.owner_id = (select auth.uid())));

create policy huos_request_events_staff_read on public.huos_proposal_request_events for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));

revoke all on public.huos_customer_notices, public.huos_proposal_requests, public.huos_proposal_request_events
  from public, anon, authenticated;
grant select on public.huos_customer_notices, public.huos_proposal_requests, public.huos_proposal_request_events to authenticated;
-- klant ziet bij een melding geen interne bron-/medewerkergegevens: kolomrechten
revoke select on public.huos_customer_notices from authenticated;
grant select (id, organization_id, kind, title, body, personal_note, cta, status, published_at, read_at, source_key)
  on public.huos_customer_notices to authenticated;
revoke select on public.huos_proposal_requests from authenticated;
grant select (id, organization_id, notice_id, contract_id, origin, subject, customer_message, status, created_at, updated_at)
  on public.huos_proposal_requests to authenticated;
-- interne kolommen (source, published_by, withdrawn_*, assigned_to, requested_by) alleen via staff-RPC
-- events: alleen medewerkers (policy) — kolomrechten volledig
-- (huos_proposal_request_events heeft geen klant-policy)

-- 4. RPC's
-- 4a. Medewerker publiceert een melding
create or replace function public.huos_notice_publish(p_org uuid, p_kind text, p_source_key text, p_source jsonb,
  p_title text, p_body text, p_note text, p_cta text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(p_org)) then
    raise exception 'Geen rechten om meldingen te publiceren voor dit bedrijf';
  end if;
  if p_source_key is not null and exists (select 1 from public.huos_customer_notices
       where organization_id = p_org and source_key = p_source_key and status = 'published') then
    raise exception 'Deze melding staat al bij de klant';
  end if;
  insert into public.huos_customer_notices (organization_id, kind, source_key, source, title, body, personal_note, cta, published_by)
  values (p_org, coalesce(p_kind,'custom'), nullif(btrim(p_source_key),''), coalesce(p_source,'{}'::jsonb),
          btrim(p_title), btrim(p_body), nullif(btrim(p_note),''), coalesce(p_cta,'proposal'), (select auth.uid()))
  returning id into v_id;
  return v_id;
end $$;

-- 4b. Medewerker trekt een melding in
create or replace function public.huos_notice_withdraw(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.huos_customer_notices where id = p_id and status = 'published';
  if v_org is null then raise exception 'Melding niet gevonden of al ingetrokken'; end if;
  if not (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(v_org)) then
    raise exception 'Geen rechten';
  end if;
  update public.huos_customer_notices set status = 'withdrawn', withdrawn_at = now(), withdrawn_by = (select auth.uid())
  where id = p_id;
end $$;

-- 4c. Klant markeert zijn meldingen als gelezen
create or replace function public.huos_notice_mark_read(p_org uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  if not exists (select 1 from public.huos_pilot_organizations o where o.id = p_org and o.owner_id = (select auth.uid())) then
    raise exception 'Geen rechten';
  end if;
  update public.huos_customer_notices set read_at = now()
  where organization_id = p_org and status = 'published' and read_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- 4d. Klant vraagt een voorstel aan (vanuit een melding, een contract of algemeen)
create or replace function public.huos_request_proposal(p_org uuid, p_notice uuid, p_contract uuid, p_message text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_subject text; v_origin text; v_uid uuid := (select auth.uid());
begin
  if not exists (select 1 from public.huos_pilot_organizations o where o.id = p_org and o.owner_id = v_uid) then
    raise exception 'Geen rechten';
  end if;
  if p_message is not null and length(p_message) > 1000 then raise exception 'Bericht is te lang (max. 1000 tekens)'; end if;
  if p_notice is not null then
    select n.title into v_subject from public.huos_customer_notices n
      where n.id = p_notice and n.organization_id = p_org and n.status = 'published';
    if v_subject is null then raise exception 'Melding niet gevonden'; end if;
    select id into v_id from public.huos_proposal_requests where notice_id = p_notice and status <> 'closed';
    v_origin := 'notice';
  elsif p_contract is not null then
    select coalesce(nullif(c.supplier,''),'Contract') || coalesce(' — ' || nullif(c.description,''), '') into v_subject
      from public.huos_pilot_contracts c where c.id = p_contract and c.organization_id = p_org;
    if v_subject is null then raise exception 'Contract niet gevonden'; end if;
    select id into v_id from public.huos_proposal_requests where contract_id = p_contract and status <> 'closed';
    v_origin := 'contract';
    update public.huos_pilot_contracts set proposal_requested_at = coalesce(proposal_requested_at, now()) where id = p_contract;
  else
    v_subject := 'Algemene vraag om een voorstel';
    v_origin := 'general';
  end if;
  if v_id is not null then return v_id; end if;  -- er loopt al een aanvraag
  insert into public.huos_proposal_requests (organization_id, notice_id, contract_id, origin, subject, customer_message, requested_by)
  values (p_org, p_notice, p_contract, v_origin, left(v_subject, 200), nullif(btrim(p_message),''), v_uid)
  returning id into v_id;
  insert into public.huos_proposal_request_events (request_id, organization_id, actor_id, actor_role, event, to_status, note)
  values (v_id, p_org, v_uid, 'klant', 'created', 'new', nullif(btrim(p_message),''));
  return v_id;
end $$;

-- 4e. Medewerker wijzigt status en/of voegt een notitie toe
create or replace function public.huos_request_update(p_id uuid, p_status text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_old text;
begin
  select organization_id, status into v_org, v_old from public.huos_proposal_requests where id = p_id;
  if v_org is null then raise exception 'Aanvraag niet gevonden'; end if;
  if not (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(v_org)) then
    raise exception 'Geen rechten';
  end if;
  if p_status is not null and p_status not in ('new','in_progress','proposal_sent','closed') then
    raise exception 'Ongeldige status';
  end if;
  if p_note is not null and length(p_note) > 2000 then raise exception 'Notitie is te lang'; end if;
  if p_status is not null and p_status <> v_old then
    update public.huos_proposal_requests set status = p_status, updated_at = now(),
      assigned_to = coalesce(assigned_to, (select auth.uid())) where id = p_id;
    insert into public.huos_proposal_request_events (request_id, organization_id, actor_id, actor_role, event, from_status, to_status, note)
    values (p_id, v_org, (select auth.uid()), public.huos_staff_role(), 'status', v_old, p_status, nullif(btrim(p_note),''));
  elsif nullif(btrim(p_note),'') is not null then
    update public.huos_proposal_requests set updated_at = now() where id = p_id;
    insert into public.huos_proposal_request_events (request_id, organization_id, actor_id, actor_role, event, note)
    values (p_id, v_org, (select auth.uid()), public.huos_staff_role(), 'note', btrim(p_note));
  end if;
end $$;

revoke all on function public.huos_notice_publish(uuid,text,text,jsonb,text,text,text,text) from public, anon, authenticated;
revoke all on function public.huos_notice_withdraw(uuid) from public, anon, authenticated;
revoke all on function public.huos_notice_mark_read(uuid) from public, anon, authenticated;
revoke all on function public.huos_request_proposal(uuid,uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.huos_request_update(uuid,text,text) from public, anon, authenticated;
grant execute on function public.huos_notice_publish(uuid,text,text,jsonb,text,text,text,text) to authenticated;
grant execute on function public.huos_notice_withdraw(uuid) to authenticated;
grant execute on function public.huos_notice_mark_read(uuid) to authenticated;
grant execute on function public.huos_request_proposal(uuid,uuid,uuid,text) to authenticated;
grant execute on function public.huos_request_update(uuid,text,text) to authenticated;

-- Terugdraaien (alleen na akkoord; verwijdert meldingen en aanvragen):
--   drop function public.huos_request_update(uuid,text,text);
--   drop function public.huos_request_proposal(uuid,uuid,uuid,text);
--   drop function public.huos_notice_mark_read(uuid);
--   drop function public.huos_notice_withdraw(uuid);
--   drop function public.huos_notice_publish(uuid,text,text,jsonb,text,text,text,text);
--   drop table public.huos_proposal_request_events; drop table public.huos_proposal_requests;
--   drop table public.huos_customer_notices;

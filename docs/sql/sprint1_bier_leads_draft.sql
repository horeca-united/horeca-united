-- HUOS Sprint 1: DRAFT ONLY. NOT DEPLOYED. Needs migration generation, review, auth, RLS and tests.
-- Do not apply to production until owner approves tested deployment.
create table if not exists public.bier_leads (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references auth.users(id),
  company_name text not null,
  contact_name text,
  email text not null,
  phone text,
  city text,
  supplier text,
  tap_pils_brand text,
  keg_size_l numeric(10,2),
  keg_price_ex_vat numeric(14,4),
  annual_volume_hl numeric(14,4),
  volume_is_estimate boolean not null default true,
  contract_status text not null default 'unknown',
  extra_bonus_status text not null default 'unknown',
  interest text not null default 'unknown',
  delivery_route text not null default 'later_upload' check(delivery_route in ('later_upload','mandate','uploaded')),
  missing_fields text[] not null default '{}',
  stage text not null default 'new' check(stage in ('new','contact_needed','awaiting_upload','mandate_pending','document_received','review_needed','ready_for_offer','offer_sent','customer','closed')),
  assigned_to uuid references auth.users(id),
  last_activity_at timestamptz not null default now(),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bier_leads_stage_idx on public.bier_leads(stage,created_at desc);
create index if not exists bier_leads_owner_idx on public.bier_leads(owner_id);
create index if not exists bier_leads_missing_idx on public.bier_leads using gin(missing_fields);
create index if not exists bier_leads_brand_idx on public.bier_leads(tap_pils_brand);

create table if not exists public.bier_lead_preferences (
 lead_id uuid primary key references public.bier_leads(id) on delete cascade,
 upload_reminders_enabled boolean not null default true,
 marketing_opt_in boolean not null default false,
 updated_at timestamptz not null default now(),
 marketing_consented_at timestamptz,
 marketing_unsubscribed_at timestamptz,
 preference_source text,
 notice_version text
);

create table if not exists public.bier_lead_documents (
 id uuid primary key default gen_random_uuid(),
 lead_id uuid not null references public.bier_leads(id) on delete cascade,
 upload_id uuid references public.uploads(id),
 status text not null default 'uploaded' check(status in ('uploaded','processing','review_needed','accepted','rejected')),
 subgroup text not null default 'bier',
 purpose text,
 received_at timestamptz not null default now(),
 reviewed_at timestamptz,
 constraint unique_lead_upload unique(lead_id,upload_id)
);
create index if not exists bier_lead_documents_idx on public.bier_lead_documents(lead_id,received_at desc);

create table if not exists public.bier_lead_email_events (
 id uuid primary key default gen_random_uuid(),
 lead_id uuid not null references public.bier_leads(id) on delete cascade,
 message_kind text not null check(message_kind in ('thank_you','reminder_day3','reminder_day10')),
 idempotency_key text not null unique,
 scheduled_for timestamptz not null,
 status text not null default 'pending' check(status in ('pending','sending','sent','failed','cancelled','skipped')),
 attempts integer not null default 0,
 provider_message_id text,
 sent_at timestamptz,
 last_error text,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(lead_id,message_kind)
);
create index if not exists bier_lead_email_queue_idx on public.bier_lead_email_events(status,scheduled_for);

-- Internal audit trail, visible only to authorized personnel.
create table if not exists public.bier_lead_activity (
 id uuid primary key default gen_random_uuid(),
 lead_id uuid not null references public.bier_leads(id) on delete cascade,
 event_type text not null,
 actor_id uuid references auth.users(id),
 metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists bier_lead_activity_idx on public.bier_lead_activity(lead_id,created_at desc);

-- New exposed tables must have RLS. No client read/write privileges unless explicitly authorized.
alter table public.bier_leads enable row level security;
alter table public.bier_lead_preferences enable row level security;
alter table public.bier_lead_documents enable row level security;
alter table public.bier_lead_email_events enable row level security;
alter table public.bier_lead_activity enable row level security;

-- Owner may read own lead, preference, and document metadata after authenticated sign-in.
create policy "Owners read own bier leads" on public.bier_leads for select to authenticated
 using (owner_id = (select auth.uid()));
create policy "Owners read own bier lead preferences" on public.bier_lead_preferences for select to authenticated
 using (exists(select 1 from public.bier_leads l where l.id = lead_id and l.owner_id=(select auth.uid())));
create policy "Owners read own bier lead documents" on public.bier_lead_documents for select to authenticated
 using (exists(select 1 from public.bier_leads l where l.id = lead_id and l.owner_id=(select auth.uid())));
-- No client INSERT/UPDATE/DELETE policies: validated intake, consent preference changes,
-- upload mapping and e-mail send queue must be implemented by carefully authorized server functions.
-- E-mail events and activity are private internal tables; expose only safe derived status via server endpoint.
-- Admin filtering must use an authenticated server-side endpoint that checks admin authorization.
-- Production optimization may use private schema + explicit GRANTs; check Data API exposure settings.

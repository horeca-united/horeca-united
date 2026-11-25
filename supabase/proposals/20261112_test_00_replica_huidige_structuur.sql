-- Nagebouwde huidige structuur (alleen relevante delen), op basis van live-inspectie 11-11-2026
do $$ begin if not exists (select 1 from pg_roles where rolname=$q$anon$q$) then create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls; end if; end $$;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
grant usage on schema public to anon, authenticated, service_role;
create table auth.users (id uuid primary key, email text, email_confirmed_at timestamptz, banned_until timestamptz, last_sign_in_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
grant execute on function auth.uid() to anon, authenticated;
-- Supabase-standaard: brede default privileges op public
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create table public.uploads (id uuid primary key);

create table public.huos_beer_intake_submissions (
  id uuid primary key default gen_random_uuid(),
  company_name text not null, contact_name text not null, email text not null, phone text,
  answers jsonb not null, source text not null default 'huos_v2_private_pilot', status text not null default 'new',
  privacy_notice_version text not null, created_at timestamptz not null default now(),
  data_route text not null default 'later_upload', mandate_status text not null default 'not_requested',
  mandate_consent_at timestamptz, mandate_consent_version text, mandate_authority_asserted boolean not null default false,
  annual_volume_verified_at timestamptz, annual_volume_verified_by uuid references auth.users(id), annual_volume_verification_note text,
  constraint huos_beer_intake_data_route_check check (data_route in ('later_upload','mandate','none')),
  constraint huos_beer_intake_mandate_consistency_check check (((data_route = 'mandate') AND (mandate_status = 'pending') AND (mandate_consent_at IS NOT NULL) AND (mandate_consent_version IS NOT NULL) AND mandate_authority_asserted) OR ((data_route <> 'mandate') AND (mandate_status = 'not_requested') AND (mandate_consent_at IS NULL) AND (mandate_consent_version IS NULL) AND (NOT mandate_authority_asserted))),
  constraint huos_beer_intake_submissions_status_check check (status in ('new','reviewing','awaiting_info','proposal','closed'))
);
create table public.huos_beer_intake_admins (user_id uuid primary key references auth.users(id) on delete cascade, created_at timestamptz not null default now());
alter table public.huos_beer_intake_submissions enable row level security;
alter table public.huos_beer_intake_admins enable row level security;
revoke all on public.huos_beer_intake_submissions from anon, authenticated;
grant select on public.huos_beer_intake_submissions to authenticated;
grant update (annual_volume_verified_at, annual_volume_verified_by, annual_volume_verification_note) on public.huos_beer_intake_submissions to authenticated;
revoke all on public.huos_beer_intake_admins from anon;
create policy huos_beer_admin_self on public.huos_beer_intake_admins for select to authenticated using (user_id = (select auth.uid()));
create policy huos_beer_intake_admin_select on public.huos_beer_intake_submissions for select to authenticated using (exists (select 1 from public.huos_beer_intake_admins adm where adm.user_id = (select auth.uid())));
create policy huos_beer_intake_admin_update on public.huos_beer_intake_submissions for update to authenticated using (exists (select 1 from public.huos_beer_intake_admins adm where adm.user_id = (select auth.uid()))) with check (exists (select 1 from public.huos_beer_intake_admins adm where adm.user_id = (select auth.uid())));

create function public.huos_beer_verify_hl(p_submission_id uuid, p_verified boolean, p_note text default null) returns boolean language plpgsql set search_path to 'public','pg_temp' as $$ begin return true; end $$;
revoke all on function public.huos_beer_verify_hl(uuid,boolean,text) from public, anon; grant execute on function public.huos_beer_verify_hl(uuid,boolean,text) to authenticated;

create table public.bier_leads (id uuid primary key default gen_random_uuid());
create table public.bier_lead_activity (id uuid primary key);
create table public.bier_lead_documents (id uuid primary key);
create table public.bier_lead_preferences (lead_id uuid primary key);
create table public.bier_lead_email_events (id uuid primary key);
create table public.bier_scan_funnel_events (id uuid primary key);
create table public.huos_pilot_organizations (id uuid primary key default gen_random_uuid(), owner_id uuid not null unique references auth.users(id) on delete cascade, name text not null);
alter table public.huos_pilot_organizations enable row level security;
create policy "pilot owner create" on public.huos_pilot_organizations for insert to authenticated with check (owner_id = (select auth.uid()));
create policy "pilot owner read" on public.huos_pilot_organizations for select to authenticated using (owner_id = (select auth.uid()));
create policy "pilot owner edit" on public.huos_pilot_organizations for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create table public.huos_pilot_documents (id uuid primary key);
create table public.huos_pilot_entries (id uuid primary key);
create table public.huos_pilot_beer_scans (id uuid primary key);

-- Testgebruikers: A = bestaande admin, R = reviewer, V = viewer, X = gewone gebruiker
insert into auth.users (id,email,email_confirmed_at,last_sign_in_at) values
 ('00000000-0000-0000-0000-00000000000a','hui@horecaunited.nl',now(),now()),
 ('00000000-0000-0000-0000-00000000000b','reviewer@horecaunited.nl',now(),now()),
 ('00000000-0000-0000-0000-00000000000c','viewer@horecaunited.nl',now(),now()),
 ('00000000-0000-0000-0000-00000000000d','nieuw@klant.nl',now(),now()),
 ('00000000-0000-0000-0000-00000000000e','facturen@volkarnhem.nl',now(),now()),
 ('00000000-0000-0000-0000-00000000000f','onbevestigd@horecaunited.nl',null,null),
 ('00000000-0000-0000-0000-000000000010','huihu274@gmail.com',now(),now()),
 ('00000000-0000-0000-0000-000000000011','nooitingelogd@horecaunited.nl',now(),null);
insert into public.huos_beer_intake_admins (user_id) values ('00000000-0000-0000-0000-00000000000e');
-- Eén bestaande inzending, met oude verificatie
insert into public.huos_beer_intake_submissions (id, company_name, contact_name, email, answers, privacy_notice_version, annual_volume_verified_at, annual_volume_verified_by, annual_volume_verification_note)
values ('11111111-1111-1111-1111-111111111111','Testcafé','Jan Test','jan@test.nl','{"annual_volume_hl":120,"annual_volume_source":"own_estimate","brewery_supplier":"Heineken"}','huos-beer-2026-11', now(), '00000000-0000-0000-0000-00000000000e', 'factuur 2025 gecontroleerd');
create table public.admin_users (email text, name text, created_at timestamptz default now());
insert into public.admin_users(email) values ('facturen@volkarnhem.nl');

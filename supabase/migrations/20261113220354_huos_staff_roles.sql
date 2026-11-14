-- HUOS 2.0 — migratie huos_staff_roles
-- Toegepast op project yyvzqnjumnpotawnrvfw op 13-11-2026 (na proefrun 109/109 en akkoord eigenaar).
-- Rollback-instructies: zie docs in supabase/proposals/20261112_huos_beer_lead_workflow_PROPOSAL.sql

create table public.huos_staff (
 user_id         uuid primary key references auth.users(id) on delete cascade,
 role            text not null check (role in ('admin','reviewer','viewer')),
 active          boolean not null default true,
 scope           text not null default 'assigned'
 check (scope in ('all','assigned','region','organization')),
 scope_values    text[] not null default '{}',
 note            text check (note is null or length(note) <= 500),
 created_at      timestamptz not null default now(),
 created_by      uuid references auth.users(id) on delete set null,
 updated_at      timestamptz not null default now(),
 deactivated_at  timestamptz,
 constraint huos_staff_admin_scope_chk  check (role <> 'admin' or scope = 'all'),
 constraint huos_staff_scope_values_chk check (
 (scope in ('all','assigned') and cardinality(scope_values) = 0) or
 (scope in ('region','organization') and cardinality(scope_values) between 1 and 50)),
 constraint huos_staff_deactivated_chk  check (active or deactivated_at is not null)
);
comment on table public.huos_staff is
 'Interne medewerkers. Geen rij = geen toegang. admin = alles incl. rollen en export; reviewer = leads binnen eigen bereik bewerken; viewer = leads binnen eigen bereik lezen.';
comment on column public.huos_staff.scope is
 'all = alle leads; assigned = alleen aan mij toegewezen leads (standaard, minste rechten); region/organization = leads met region resp. organization_id in scope_values.';
create table public.huos_staff_audit (
 id           bigint generated always as identity primary key,
 target_user  uuid not null,              -- geen FK: log blijft bestaan
 actor_id     uuid,                       -- null = wijziging buiten de API (SQL-editor/migratie)
 actor_kind   text not null check (actor_kind in ('user','database')),
 action       text not null check (action in ('granted','changed','deactivated','reactivated','deleted')),
 old_value    jsonb,
 new_value    jsonb,
 reason       text check (reason is null or length(reason) <= 500),
 created_at   timestamptz not null default now()
);
create index huos_staff_audit_target_idx on public.huos_staff_audit (target_user, created_at desc);
create function public.huos_block_mutation()
returns trigger language plpgsql set search_path = ''
as $$ begin raise exception 'Append-only tabel: % is niet toegestaan', tg_op; end $$;
create trigger huos_staff_audit_append_only
 before update or delete on public.huos_staff_audit
 for each row execute function public.huos_block_mutation();
create table public.huos_staff_allowed_domains (
 domain      text primary key check (domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
 created_at  timestamptz not null default now()
);
insert into public.huos_staff_allowed_domains (domain) values ('horecaunited.nl');
alter table public.huos_staff_allowed_domains enable row level security;
revoke all on public.huos_staff_allowed_domains from anon, authenticated;
comment on table public.huos_staff_allowed_domains is
 'Alleen via migratie te wijzigen. Accounts buiten deze domeinen kunnen geen interne rol krijgen.';
create function public.huos_staff_role()
returns text language sql stable security definer set search_path = ''
as $$
 select s.role from public.huos_staff s
 where s.user_id = (select auth.uid()) and s.active
$$;
create function public.huos_staff_has(p_min_role text)
returns boolean language sql stable security definer set search_path = ''
as $$
 select coalesce(
 (select case p_min_role
 when 'viewer'   then s.role in ('viewer','reviewer','admin')
 when 'reviewer' then s.role in ('reviewer','admin')
 when 'admin'    then s.role = 'admin'
 else false end
 from public.huos_staff s
 where s.user_id = (select auth.uid()) and s.active),
 false)
$$;
revoke all on function public.huos_staff_role()    from public, anon;
revoke all on function public.huos_staff_has(text) from public, anon;
grant execute on function public.huos_staff_role()    to authenticated;
grant execute on function public.huos_staff_has(text) to authenticated;
create function public.huos_staff_guard()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid()); v_admins int;
begin
 if v_uid is not null and not public.huos_staff_has('admin') then
 raise exception 'Alleen beheerders kunnen rollen wijzigen';
 end if;
 if tg_op in ('UPDATE','DELETE') and old.role = 'admin' and old.active
 and (tg_op = 'DELETE' or new.role <> 'admin' or not new.active) then
 if v_uid is not null and old.user_id = v_uid then
 raise exception 'Je kunt je eigen beheerdersrechten niet intrekken';
 end if;
 select count(*) into v_admins from public.huos_staff
 where role = 'admin' and active and user_id <> old.user_id;
 if v_admins = 0 then
 raise exception 'Er moet minimaal één actieve beheerder overblijven';
 end if;
 end if;
 if tg_op in ('INSERT','UPDATE') and new.active then
 if not exists (select 1 from auth.users u
 join public.huos_staff_allowed_domains d
 on lower(split_part(u.email, '@', 2)) = d.domain
 where u.id = new.user_id) then
 raise exception 'Alleen accounts op een Horeca United-domein kunnen een interne rol krijgen';
 end if;
 if exists (select 1 from public.huos_pilot_organizations o where o.owner_id = new.user_id) then
 raise exception 'Dit account is eigenaar van een klantomgeving en kan geen interne rol krijgen';
 end if;
 end if;
 if tg_op = 'UPDATE' then
 new.updated_at := now();
 if old.active and not new.active then new.deactivated_at := now(); end if;
 if not old.active and new.active then new.deactivated_at := null; end if;
 new.created_at := old.created_at;   -- niet te herschrijven
 new.created_by := old.created_by;
 end if;
 if tg_op = 'INSERT' then
 new.created_at := now();
 new.created_by := v_uid;
 new.deactivated_at := case when new.active then null else now() end;
 end if;
 return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger huos_staff_guard
 before insert or update or delete on public.huos_staff
 for each row execute function public.huos_staff_guard();
create function public.huos_staff_audit_trg()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare v_uid uuid := (select auth.uid()); v_action text; v_reason text;
begin
 v_reason := nullif(current_setting('huos.staff_change_reason', true), '');
 v_action := case
 when tg_op = 'INSERT' then 'granted'
 when tg_op = 'DELETE' then 'deleted'
 when old.active and not new.active then 'deactivated'
 when not old.active and new.active then 'reactivated'
 else 'changed' end;
 if tg_op = 'UPDATE' and (old.role, old.active, old.scope, old.scope_values)
 is not distinct from (new.role, new.active, new.scope, new.scope_values) then
 return null;   -- alleen notitie/tijdstempel gewijzigd: geen rechtenwijziging
 end if;
 insert into public.huos_staff_audit (target_user, actor_id, actor_kind, action, old_value, new_value, reason)
 values (coalesce(new.user_id, old.user_id), v_uid,
 case when v_uid is null then 'database' else 'user' end, v_action,
 case when tg_op <> 'INSERT' then jsonb_build_object('role', old.role, 'active', old.active,
 'scope', old.scope, 'scope_values', old.scope_values) end,
 case when tg_op <> 'DELETE' then jsonb_build_object('role', new.role, 'active', new.active,
 'scope', new.scope, 'scope_values', new.scope_values) end,
 v_reason);
 return null;
end $$;
create trigger huos_staff_audit_trg
 after insert or update or delete on public.huos_staff
 for each row execute function public.huos_staff_audit_trg();
revoke all on function public.huos_staff_guard()     from public, anon, authenticated;
revoke all on function public.huos_staff_audit_trg() from public, anon, authenticated;
create function public.huos_staff_set_role(
 p_user uuid, p_role text, p_scope text default 'assigned',
 p_scope_values text[] default '{}', p_reason text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
 if not public.huos_staff_has('admin') then raise exception 'Alleen beheerders kunnen rollen wijzigen'; end if;
 if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Geef een reden (min. 5 tekens)'; end if;
 if p_role not in ('admin','reviewer','viewer') then raise exception 'Ongeldige rol'; end if;
 if p_role = 'admin' then p_scope := 'all'; p_scope_values := '{}'; end if;
 if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null
 and (u.banned_until is null or u.banned_until < now())) then
 raise exception 'Account bestaat niet, is niet bevestigd of is geblokkeerd';
 end if;
 perform set_config('huos.staff_change_reason', trim(p_reason), true);
 insert into public.huos_staff (user_id, role, scope, scope_values, active)
 values (p_user, p_role, p_scope, coalesce(p_scope_values, '{}'), true)
 on conflict (user_id) do update
 set role = excluded.role, scope = excluded.scope,
 scope_values = excluded.scope_values, active = true;
end $$;
create function public.huos_staff_revoke(p_user uuid, p_reason text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
 if not public.huos_staff_has('admin') then raise exception 'Alleen beheerders kunnen rollen wijzigen'; end if;
 if length(trim(coalesce(p_reason,''))) < 5 then raise exception 'Geef een reden (min. 5 tekens)'; end if;
 perform set_config('huos.staff_change_reason', trim(p_reason), true);
 update public.huos_staff set active = false where user_id = p_user and active;
 if not found then raise exception 'Geen actieve medewerker gevonden'; end if;
end $$;
create function public.huos_staff_list()
returns table (user_id uuid, email text, role text, active boolean, scope text,
 scope_values text[], last_sign_in_at timestamptz, created_at timestamptz)
language plpgsql stable security definer set search_path = ''
as $$
begin
 if not public.huos_staff_has('admin') then raise exception 'Alleen beheerders'; end if;
 return query
 select s.user_id, u.email::text, s.role, s.active, s.scope, s.scope_values, u.last_sign_in_at, s.created_at
 from public.huos_staff s join auth.users u on u.id = s.user_id
 order by s.active desc, s.role, u.email;
end $$;
revoke all on function public.huos_staff_set_role(uuid,text,text,text[],text) from public, anon;
revoke all on function public.huos_staff_revoke(uuid,text)                   from public, anon;
revoke all on function public.huos_staff_list()                              from public, anon;
grant execute on function public.huos_staff_set_role(uuid,text,text,text[],text) to authenticated;
grant execute on function public.huos_staff_revoke(uuid,text)                   to authenticated;
grant execute on function public.huos_staff_list()                              to authenticated;
alter table public.huos_staff       enable row level security;
alter table public.huos_staff_audit enable row level security;
revoke all on public.huos_staff, public.huos_staff_audit from anon, authenticated;
grant select on public.huos_staff, public.huos_staff_audit to authenticated;
create policy huos_staff_read on public.huos_staff for select to authenticated
 using (user_id = (select auth.uid()) or public.huos_staff_has('admin'));
create policy huos_staff_audit_read on public.huos_staff_audit for select to authenticated
 using (public.huos_staff_has('admin'));
create policy huos_pilot_org_not_staff on public.huos_pilot_organizations
 as restrictive for insert to authenticated
 with check (not public.huos_staff_has('viewer'));
do $$
declare
 v_id    uuid := 'bf03f295-9572-4101-b0e9-a7cc321e2ed6';
 v_email text := 'hui@horecaunited.nl';
begin
 if not exists (select 1 from auth.users u
 where u.id = v_id and lower(u.email) = lower(v_email)
 and u.email_confirmed_at is not null
 and (u.banned_until is null or u.banned_until < now())) then
 raise exception 'Bootstrap afgebroken: user-ID en e-mailadres horen niet bij hetzelfde bevestigde account';
 end if;
 if lower(split_part(v_email, '@', 2)) <> 'horecaunited.nl' then
 raise exception 'Bootstrap afgebroken: hoofdbeheerder moet een @horecaunited.nl-account zijn';
 end if;
 if (select u.last_sign_in_at from auth.users u where u.id = v_id) is null then
 raise exception 'Bootstrap afgebroken: account heeft nog nooit ingelogd';
 end if;
 perform set_config('huos.staff_change_reason', 'Eerste hoofdbeheerder (hui@horecaunited.nl), bevestigd door eigenaar', true);
 insert into public.huos_staff (user_id, role, scope) values (v_id, 'admin', 'all');
 if (select count(*) from public.huos_staff) <> 1 then
 raise exception 'Bootstrap afgebroken: er zou meer dan één medewerker ontstaan';
 end if;
end $$;

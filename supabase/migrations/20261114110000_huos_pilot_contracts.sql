-- HUOS 2.0 — Mijn contracten (klantomgeving pilot). Additief: nieuwe tabel, raakt geen bestaande data.
-- Overgenomen uit v1: categorie, leverancier, periode, bedrag, opzegtermijn (maanden + tekst),
-- flexibel opzegbaar, automatische verlenging, geschatte datums, statuslabels en heronderhandelkansen.
-- Nieuw t.o.v. v1: elk contract is een eigen record per klantomgeving, de laatste opzegdatum wordt
-- door de database berekend, en een contract kan aan een eigen document worden gekoppeld.
-- Toegang: alleen de eigenaar van de klantomgeving (RLS). Interne medewerkers zien dit (nog) niet.
-- Rollback: drop table public.huos_pilot_contracts;

create table public.huos_pilot_contracts (
  id                     uuid primary key default gen_random_uuid(),
  organization_id        uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  created_by             uuid not null references auth.users(id) on delete cascade,
  category               text not null check (category in (
                           'bier','frisdrank','wijn','groothandel','elektra','gas','water','afval',
                           'verzekeringen','telecom','muziekrechten','betaalverkeer','schoonmaak',
                           'huur','overig')),
  supplier               text not null check (length(trim(supplier)) between 2 and 160),
  description            text check (description is null or length(description) <= 500),
  start_date             date,
  end_date               date,
  dates_estimated        boolean not null default false,
  notice_period_months   smallint check (notice_period_months is null or notice_period_months between 0 and 60),
  notice_period_text     text check (notice_period_text is null or length(notice_period_text) <= 200),
  flexible_cancellation  boolean not null default false,
  auto_renews            boolean,
  renewal_months         smallint check (renewal_months is null or renewal_months between 1 and 120),
  amount                 numeric(12,2) check (amount is null or amount >= 0),
  amount_period          text check (amount_period is null or amount_period in ('month','quarter','year','total')),
  amount_note            text check (amount_note is null or length(amount_note) <= 200),
  document_id            uuid references public.huos_pilot_documents(id) on delete set null,
  reminder_days_before   smallint not null default 60 check (reminder_days_before between 0 and 365),
  status                 text not null default 'active' check (status in ('active','terminated')),
  proposal_requested_at  timestamptz,
  cancel_by_date         date generated always as (
                           case when end_date is not null and notice_period_months is not null
                                then (end_date - make_interval(months => notice_period_months::int))::date
                           end) stored,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint huos_pilot_contracts_dates_chk check (start_date is null or end_date is null or end_date >= start_date)
);
create index huos_pilot_contracts_org_idx on public.huos_pilot_contracts (organization_id, end_date);
comment on table public.huos_pilot_contracts is 'Contracten van een klantomgeving (pilot). Alleen zichtbaar voor de eigenaar van de klantomgeving.';
comment on column public.huos_pilot_contracts.cancel_by_date is 'Berekend: einddatum min opzegtermijn (maanden). Leeg als een van beide onbekend is.';

create trigger huos_pilot_contracts_touch before update on public.huos_pilot_contracts
  for each row execute function public.huos_touch_updated_at();

alter table public.huos_pilot_contracts enable row level security;
revoke all on public.huos_pilot_contracts from anon, authenticated;
grant select, insert, update, delete on public.huos_pilot_contracts to authenticated;

-- Eigenaar van de klantomgeving: alles op eigen contracten. Document moet bij dezelfde omgeving horen.
create policy huos_pilot_contracts_owner_select on public.huos_pilot_contracts for select to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o
                 where o.id = organization_id and o.owner_id = (select auth.uid())));
create policy huos_pilot_contracts_owner_insert on public.huos_pilot_contracts for insert to authenticated
  with check (created_by = (select auth.uid())
              and exists (select 1 from public.huos_pilot_organizations o
                          where o.id = organization_id and o.owner_id = (select auth.uid()))
              and (document_id is null or exists (select 1 from public.huos_pilot_documents d
                          where d.id = document_id and d.organization_id = huos_pilot_contracts.organization_id)));
create policy huos_pilot_contracts_owner_update on public.huos_pilot_contracts for update to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o
                 where o.id = organization_id and o.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.huos_pilot_organizations o
                      where o.id = organization_id and o.owner_id = (select auth.uid()))
              and (document_id is null or exists (select 1 from public.huos_pilot_documents d
                          where d.id = document_id and d.organization_id = huos_pilot_contracts.organization_id)));
create policy huos_pilot_contracts_owner_delete on public.huos_pilot_contracts for delete to authenticated
  using (exists (select 1 from public.huos_pilot_organizations o
                 where o.id = organization_id and o.owner_id = (select auth.uid())));

-- HUOS: verdeling van een inkoopregel over productsoorten (vlees, vis, wijn, fris, …).
-- Doel: in beheer een totaaloverzicht inkoop per productsoort over alle leveranciers heen.
-- Alleen medewerkers lezen/schrijven (net als huos_cost_lines); de klant ziet deze tabel niet.
-- Schrijven kan alleen via de RPC huos_cost_line_split_set: organisatie en bedrag komen uit de kostenregel zelf,
-- niet uit de frontend. Elke wijziging komt in een append-only logboek.

create table public.huos_cost_line_splits (
  id               uuid primary key default gen_random_uuid(),
  cost_line_id     uuid not null references public.huos_cost_lines(id) on delete cascade,
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  product_type     text not null check (product_type in
                     ('vlees','vis','agf','zuivel','diepvries','brood','droog','wijn','bier','frisdrank','gedistilleerd','nonfood','overig')),
  amount           numeric(12,2) not null check (amount >= 0 and amount < 10000000),
  source           text check (source is null or length(source) <= 300),
  created_at       timestamptz not null default now(),
  created_by       uuid references auth.users(id),
  unique (cost_line_id, product_type)
);
create index on public.huos_cost_line_splits (organization_id);

create table public.huos_cost_line_split_audit (
  id               bigint generated always as identity primary key,
  cost_line_id     uuid not null,
  organization_id  uuid not null references public.huos_pilot_organizations(id) on delete cascade,
  actor_id         uuid,
  actor_role       text,
  old_rows         jsonb,
  new_rows         jsonb,
  created_at       timestamptz not null default now()
);
create index on public.huos_cost_line_split_audit (organization_id, created_at desc);
create trigger huos_cost_line_split_audit_append_only before update or delete on public.huos_cost_line_split_audit
  for each row execute function public.huos_cost_audit_guard();

alter table public.huos_cost_line_splits enable row level security;
alter table public.huos_cost_line_split_audit enable row level security;

create policy huos_cost_line_splits_staff_read on public.huos_cost_line_splits for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));
create policy huos_cost_line_split_audit_staff_read on public.huos_cost_line_split_audit for select to authenticated
  using (public.huos_staff_has('viewer') and public.huos_staff_can_access_org(organization_id));

revoke all on public.huos_cost_line_splits, public.huos_cost_line_split_audit from anon, authenticated;
grant select on public.huos_cost_line_splits, public.huos_cost_line_split_audit to authenticated;

-- Vervangt de hele verdeling van één kostenregel. p_rows = [{"type":"vlees","amount":123.45,"source":"Slagerij, Poelier"}, …]
-- Lege array = verdeling weghalen. Som moet gelijk zijn aan het bedrag van de kostenregel (± € 0,05).
create or replace function public.huos_cost_line_split_set(p_line uuid, p_rows jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_amt numeric; v_sum numeric := 0; v_old jsonb; v_new jsonb; r jsonb;
begin
  select l.organization_id, l.amount_excl_vat into v_org, v_amt from public.huos_cost_lines l where l.id = p_line;
  if v_org is null then raise exception 'Kostenregel niet gevonden'; end if;
  if not (public.huos_staff_has('reviewer') and public.huos_staff_can_access_org(v_org)) then
    raise exception 'Geen rechten';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 20 then
    raise exception 'Ongeldige verdeling';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if jsonb_typeof(r->'amount') <> 'number' or (r->>'amount')::numeric < 0 then raise exception 'Ongeldig bedrag'; end if;
    v_sum := v_sum + round((r->>'amount')::numeric, 2);
  end loop;
  if jsonb_array_length(p_rows) > 0 and abs(v_sum - v_amt) > 0.05 then
    raise exception 'Verdeling (%) wijkt af van het bedrag van de kostenregel (%)', v_sum, v_amt;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('type', s.product_type, 'amount', s.amount, 'source', s.source) order by s.product_type), '[]'::jsonb)
    into v_old from public.huos_cost_line_splits s where s.cost_line_id = p_line;
  delete from public.huos_cost_line_splits where cost_line_id = p_line;
  insert into public.huos_cost_line_splits (cost_line_id, organization_id, product_type, amount, source, created_by)
  select p_line, v_org, x->>'type', round((x->>'amount')::numeric, 2), nullif(left(btrim(coalesce(x->>'source','')), 300), ''), (select auth.uid())
  from jsonb_array_elements(p_rows) x
  where round((x->>'amount')::numeric, 2) > 0;
  select coalesce(jsonb_agg(jsonb_build_object('type', s.product_type, 'amount', s.amount, 'source', s.source) order by s.product_type), '[]'::jsonb)
    into v_new from public.huos_cost_line_splits s where s.cost_line_id = p_line;

  insert into public.huos_cost_line_split_audit (cost_line_id, organization_id, actor_id, actor_role, old_rows, new_rows)
  values (p_line, v_org, (select auth.uid()), public.huos_staff_role(), v_old, v_new);
end $$;
revoke all on function public.huos_cost_line_split_set(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.huos_cost_line_split_set(uuid, jsonb) to authenticated;

-- Rollback:
--   drop function public.huos_cost_line_split_set(uuid, jsonb);
--   drop table public.huos_cost_line_split_audit;
--   drop table public.huos_cost_line_splits;

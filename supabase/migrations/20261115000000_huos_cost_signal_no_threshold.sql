-- HUOS Mijn kosten: drempel voor signalen weggehaald (besluit eigenaar 15-11-2026).
-- Elke stijging t.o.v. begin jaar (of, als er dit jaar geen eerdere factuur is, de oudste factuur) is een signaal.
-- Alleen de view huos_cost_comparison verandert (zelfde kolommen); geen gegevens geraakt.
-- Terugdraaien: view opnieuw aanmaken met de drempelregel uit 20261114130000_huos_cost_lines.sql.

create or replace view public.huos_cost_comparison with (security_invoker = true) as
with base as (
  select c.*,
         lower(btrim(c.supplier)) as sk, lower(btrim(coalesce(c.product, ''))) as pk,
         row_number() over w_desc as rn_desc,
         row_number() over w_asc  as rn_asc,
         count(*)     over (partition by c.organization_id, c.category, lower(btrim(c.supplier)), lower(btrim(coalesce(c.product, '')))) as n_lines
  from public.huos_cost_lines c
  window w_desc as (partition by c.organization_id, c.category, lower(btrim(c.supplier)), lower(btrim(coalesce(c.product, '')))
                    order by c.period_end desc, c.period_start desc, c.created_at desc),
         w_asc  as (partition by c.organization_id, c.category, lower(btrim(c.supplier)), lower(btrim(coalesce(c.product, '')))
                    order by c.period_end asc, c.period_start asc, c.created_at asc)
), pairs as (
  select l.organization_id, l.category, l.supplier, l.product, l.n_lines,
         l.id as latest_id, l.period_start as latest_start, l.period_end as latest_end,
         l.amount_excl_vat as latest_amount, l.monthly_amount as latest_monthly, l.unit_price as latest_unit_price, l.unit as latest_unit,
         y.id as ytd_id, y.period_start as ytd_start, y.period_end as ytd_end, y.monthly_amount as ytd_monthly, y.unit_price as ytd_unit_price, y.unit as ytd_unit,
         o.id as oldest_id, o.period_start as oldest_start, o.period_end as oldest_end, o.monthly_amount as oldest_monthly, o.unit_price as oldest_unit_price, o.unit as oldest_unit,
         p.id as prev_id, p.period_start as prev_start, p.period_end as prev_end, p.monthly_amount as prev_monthly, p.unit_price as prev_unit_price, p.unit as prev_unit
  from base l
  left join lateral (select b.* from base b
                     where b.organization_id = l.organization_id and b.category = l.category and b.sk = l.sk and b.pk = l.pk
                       and b.rn_desc > 1 and b.period_start >= date_trunc('year', l.period_end)::date
                     order by b.period_end, b.period_start, b.created_at limit 1) y on true
  left join lateral (select b.* from base b
                     where b.organization_id = l.organization_id and b.category = l.category and b.sk = l.sk and b.pk = l.pk
                       and b.rn_asc = 1 and b.rn_desc > 1) o on true
  left join lateral (select b.* from base b
                     where b.organization_id = l.organization_id and b.category = l.category and b.sk = l.sk and b.pk = l.pk
                       and b.rn_desc = 2) p on true
  where l.rn_desc = 1
), pct as (
  select pairs.*,
    case when ytd_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(ytd_unit) and ytd_unit_price > 0
           then round((latest_unit_price / ytd_unit_price - 1) * 100, 1)
         when ytd_monthly > 0 then round((latest_monthly / ytd_monthly - 1) * 100, 1) end as pct_since_year_start,
    case when ytd_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(ytd_unit) then 'unit_price' else 'monthly' end as basis_year_start,
    case when oldest_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(oldest_unit) and oldest_unit_price > 0
           then round((latest_unit_price / oldest_unit_price - 1) * 100, 1)
         when oldest_monthly > 0 then round((latest_monthly / oldest_monthly - 1) * 100, 1) end as pct_since_oldest,
    case when oldest_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(oldest_unit) then 'unit_price' else 'monthly' end as basis_oldest,
    case when prev_id is null then null
         when latest_unit is not null and lower(latest_unit) = lower(prev_unit) and prev_unit_price > 0
           then round((latest_unit_price / prev_unit_price - 1) * 100, 1)
         when prev_monthly > 0 then round((latest_monthly / prev_monthly - 1) * 100, 1) end as pct_since_previous
  from pairs
)
select pct.*,
  -- referentie voor het signaal: begin van het jaar, anders de oudste factuur
  case when pct_since_year_start is not null then 'year_start' when pct_since_oldest is not null then 'oldest' end as signal_reference,
  round(latest_monthly - latest_monthly / nullif(1 + coalesce(pct_since_year_start, pct_since_oldest) / 100.0, 0), 2) as extra_per_month,
  coalesce(coalesce(pct_since_year_start, pct_since_oldest) > 0, false) as is_signal
from pct;
comment on view public.huos_cost_comparison is
  'HUOS Mijn kosten (intern): nieuwste kostenregel per categorie/leverancier/product vergeleken met begin jaar, oudste en vorige regel. Signaal: elke stijging t.o.v. begin jaar (of oudste factuur), zonder drempel.';

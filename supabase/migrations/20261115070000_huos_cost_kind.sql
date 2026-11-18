-- HUOS Mijn kosten: soort kostenregel — vaste kosten of inkoop (variabel)
-- Waarom: inkoop (wijn, bier, food, groothandel) hangt af van de omzet en hoort niet in "vaste kosten per jaar".
-- Raakt: tabel public.huos_cost_lines (1 nieuwe kolom, standaard 'vast'); bestaande regels blijven 'vast'.
-- Rechten: insert/select gelden al voor de hele tabel; update-recht op de nieuwe kolom voor authenticated
-- (RLS beperkt schrijven nog steeds tot medewerkers met toegang tot de organisatie).
-- Terugdraaien: alter table public.huos_cost_lines drop column cost_kind;

alter table public.huos_cost_lines
  add column cost_kind text not null default 'vast'
  constraint huos_cost_lines_cost_kind_check check (cost_kind in ('vast', 'inkoop'));

comment on column public.huos_cost_lines.cost_kind is
  'vast = vaste lasten (telt mee in vaste kosten per jaar); inkoop = variabele inkoop (apart getoond).';

grant update (cost_kind) on public.huos_cost_lines to authenticated;

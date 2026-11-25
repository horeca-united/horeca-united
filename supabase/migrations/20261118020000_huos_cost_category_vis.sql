-- HUOS: subgroep 'vis' voor kostenregels (bijv. de visboer), naast 'food' (vlees / food).
-- Alleen de check op huos_cost_lines.category wordt verruimd; bestaande regels blijven geldig, er verdwijnt niets.
alter table public.huos_cost_lines drop constraint if exists huos_cost_lines_category_check;
alter table public.huos_cost_lines add constraint huos_cost_lines_category_check
  check (category = any (array['bier','frisdrank','wijn','gedistilleerd','food','vis','groothandel','elektra','gas','water',
    'afval','verzekeringen','telecom','muziekrechten','betaalverkeer','schoonmaak','huur','overig']::text[]));

-- Rollback (alleen als er geen regels met category='vis' meer zijn):
--   alter table public.huos_cost_lines drop constraint huos_cost_lines_category_check;
--   alter table public.huos_cost_lines add constraint huos_cost_lines_category_check
--     check (category = any (array['bier','frisdrank','wijn','gedistilleerd','food','groothandel','elektra','gas','water',
--       'afval','verzekeringen','telecom','muziekrechten','betaalverkeer','schoonmaak','huur','overig']::text[]));

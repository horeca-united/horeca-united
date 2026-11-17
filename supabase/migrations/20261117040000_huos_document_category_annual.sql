-- HUOS: nieuwe documentsoort 'annual' (jaarafrekening energie/water) naast contract, invoice, overview, other.
-- Alleen de check-constraint wordt verruimd; bestaande rijen blijven geldig, er verdwijnt niets.
-- Grants/RLS blijven ongewijzigd (klant mag al insert(category) op eigen documenten).
alter table public.huos_pilot_documents drop constraint if exists huos_pilot_documents_category_check;
alter table public.huos_pilot_documents add constraint huos_pilot_documents_category_check
  check (category = any (array['contract'::text, 'invoice'::text, 'overview'::text, 'other'::text, 'annual'::text]));

-- Rollback (alleen als er geen rijen met category='annual' meer zijn):
--   update public.huos_pilot_documents set category = 'overview' where category = 'annual';
--   alter table public.huos_pilot_documents drop constraint if exists huos_pilot_documents_category_check;
--   alter table public.huos_pilot_documents add constraint huos_pilot_documents_category_check
--     check (category = any (array['contract'::text, 'invoice'::text, 'overview'::text, 'other'::text]));

-- HUOS 2.0 — migratie huos_beer_intake_auto_lead
-- Toegepast op project yyvzqnjumnpotawnrvfw op 13-11-2026 (na proefrun 109/109 en akkoord eigenaar).
-- Rollback-instructies: zie docs in supabase/proposals/20261112_huos_beer_lead_workflow_PROPOSAL.sql

create function public.huos_beer_intake_after_insert()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
 begin
 perform public.huos_beer_ensure_lead(new.id);
 exception when others then
 raise warning 'huos_beer_ensure_lead faalde voor inzending %: %', new.id, sqlerrm;
 end;
 return null;
end $$;
revoke all on function public.huos_beer_intake_after_insert() from public, anon, authenticated;
create trigger huos_beer_intake_create_lead
 after insert on public.huos_beer_intake_submissions
 for each row execute function public.huos_beer_intake_after_insert();

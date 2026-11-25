-- HUOS 2.0 — migratie huos_beer_least_privilege
-- Toegepast op project yyvzqnjumnpotawnrvfw op 13-11-2026 (na proefrun 109/109 en akkoord eigenaar).
-- Rollback-instructies: zie docs in supabase/proposals/20261112_huos_beer_lead_workflow_PROPOSAL.sql

revoke update (annual_volume_verified_at, annual_volume_verified_by, annual_volume_verification_note)
 on public.huos_beer_intake_submissions from authenticated;
revoke execute on function public.huos_beer_verify_hl(uuid, boolean, text) from public, anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
 on public.huos_beer_intake_admins from authenticated;
revoke all on public.huos_pilot_organizations, public.huos_pilot_documents,
 public.huos_pilot_entries, public.huos_pilot_beer_scans from anon;

# Exact Online pilot — development plan (NOT LIVE)

## Scope
Pilot only for 't Volk. Read-only import of purchase invoices, supplier identifiers, original documents where accessible, and line items where provided by Exact. Never write to Exact. Never alter existing uploads/transactions; reconcile duplicates before dashboard aggregation.

## Connection
1. Confirm whether an Exact Online developer application already exists; if not, register one in the Exact developer portal under the appropriate organization.
2. Configure the registered redirect URI and client ID; keep client secret and OAuth refresh tokens server-side only. Do not paste credentials in chat, GitHub, browser code, or SQL.
3. Implement an authenticated Supabase Edge Function for OAuth start/callback, state validation, token rotation, disconnect and scoped account ownership. Callback requires its own CSRF/state validation and cannot rely solely on browser JWT.
4. Obtain explicit account consent and select the correct Exact division for 't Volk before any import.
5. Add a scheduled worker with pagination, retries, rate-limit handling, checkpointing and idempotent upserts. Confirm exact endpoints/permissions against current Exact API docs and the pilot account before implementing; do not assume that bookkeeping lines include original PDFs or item-level prices.
6. Store original invoice attachments in a private storage bucket with owner-checked signed access, where the Exact API permits retrieval. Use existing PDF extraction only after checking its accepted inputs and access model. Record missing originals/line items as incomplete, never fabricate values.
7. Reconcile supplier, invoice number, date, total and source IDs with existing manual uploads before adding amounts to dashboard totals. Never auto-merge on invoice number alone.
8. Add audit logs, retention/deletion rules, connection health, manual sync and daily sync after pilot validation.

## Current implementation status
- GitHub feature branch created; this document and an isolated draft SQL migration are the only planned changes.
- SQL migration has NOT been applied to Supabase. No Edge Function deployed, no Exact application registered, no OAuth connection or production sync.
- Existing website, PDF processing, and dashboard remain unchanged.
- Before activation: review migration and RLS, verify data mapping and authorization, test against synthetic invoices and a controlled account, request explicit user approval.

## Security notes
Do not store plaintext access/refresh tokens in browser-accessible tables. `token_secret_ref` is only a reference to a secure server-side secret store, not the token itself. A proper per-tenant encrypted credential storage and rotation design must be implemented before OAuth is enabled. Never place service-role credentials in the frontend.

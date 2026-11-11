# HUOS 2.0 — private preview deployment checklist
Status: preview build prepared on `feature/huos-digitale-manager-v2`. **NOT deployed yet.**
The current public `main` GitHub Pages site remains unchanged.

## Why GitHub Pages is not used
The repository is public and GitHub Pages would make the preview accessible to anyone who finds the URL. A secret link or client-side login is not genuine site-access protection.

## Recommended hosting
Use a separate **Vercel project** connected to `horeca-united/horeca-united`, with production branch pinned to `feature/huos-digitale-manager-v2` **only after** deployment protection has been configured and verified. Ideally choose 'Vercel Authentication' / team login for all environments, or use Password Protection if covered by the workspace plan. If preview protection cannot be enabled, STOP: do not deploy a public preview.

## Build
`build-preview.js` runs legacy `build.js` and copies only index.html to `dist`.
`vercel.json` uses `node build-preview.js`, output `dist`, and robots noindex. The X-Robots-Tag header is NOT access control.

## Deployment safety tests
1. Verify deployment protection is enabled BEFORE copying any live data; access the URL in a private browser and assert HTTP auth challenge / Vercel login before HTML is served.
2. Check `/src/app.js`, `/build.js`, `/.mcp.json` are NOT served (only `dist/index.html` is published).
3. Verify magic link login redirect stays on the preview domain. Supabase Auth 'Site URL' is shared with v1: DO NOT overwrite it; add the precise preview callback to the allowed Redirect URLs through Supabase dashboard as needed. Use a provider-specific redirectTo from frontend only if registered; test.
4. Verify owner creates only their new `huos_pilot_organizations` record. Old `uploads` and `transactions` are never imported into pilot.
5. Upload own non-sensitive PDF, check new `huos_pilot_documents` and private bucket, then reload.
6. Second account cannot access first tenant's organization or storage paths.
7. Complete missing privacy placeholders and retention/deletion process prior to accepting real sensitive company documents.
8. Leave main public website unchanged; never merge draft PR until these conditions hold.

## Known limitations
- HUOS Auth magic links are currently configured around previous site URLs; routing may need adjustment for private preview.
- Legacy dashboard is still accessible in this feature branch and can show previous data, but the new pilot workspace is isolated.
- Private preview gate controls HTML visibility; Supabase RLS controls database and Storage data.
- A private Vercel deployment is not a separate Supabase project; current pilot tables are in the existing project, isolated by tables and RLS. Use a separate Supabase project only if a fully separate data backend is later required.
- No Vercel credentials or deployment protection have been configured using GitHub/Supabase alone.

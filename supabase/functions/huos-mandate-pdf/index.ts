// HUOS — maakt de PDF van ondertekeningen van een leveranciersmachtiging.
// Aanroep: POST {mandate_id} met de inlog van de klant (eigenaar) of van staff (reviewer/admin).
// De functie bepaalt zelf welke organisatie erbij hoort; organisatie- of bestandsgegevens
// uit de aanvraag worden niet vertrouwd. De service-sleutel blijft op de server.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { buildMandatePdf, type Signature } from "./pdf.ts";

const ACCEPTED_ORIGINS = new Set([
  "https://huos-v2-prive-pilot.vercel.app",
  "https://app.horecaunited.nl",
]);
const API = Deno.env.get("SUPABASE_URL") ?? "";
const ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const BUCKET = "huos-pilot-private";
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const db = createClient(API, SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const headers = (origin: string) => ({
  "Content-Type": "application/json; charset=utf-8",
  "Access-Control-Allow-Origin": origin,
  "Vary": "Origin",
  "Cache-Control": "no-store",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
});
const reply = (status: number, data: Record<string, unknown>, origin: string) =>
  new Response(JSON.stringify(data), { status, headers: headers(origin) });

async function sha256Hex(data: Uint8Array | string) {
  const raw = typeof data === "string" ? new TextEncoder().encode(data) : data;
  const dig = await crypto.subtle.digest("SHA-256", raw as BufferSource);
  return Array.from(new Uint8Array(dig), (b) => b.toString(16).padStart(2, "0")).join("");
}
const safeName = (s: string) =>
  String(s || "onderneming").normalize("NFKD").replace(/[\u0300-\u036f]/g, "")
    .replace(/[^A-Za-z0-9 _.-]+/g, "").replace(/\s+/g, " ").trim().slice(0, 80) || "onderneming";

Deno.serve(async (req) => {
  const origin = req.headers.get("origin") ?? "";
  if (!ACCEPTED_ORIGINS.has(origin)) return reply(403, { error: "Ongeldige herkomst." }, "null");
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: {
      "Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
      "Access-Control-Max-Age": "3600", "Vary": "Origin" } });
  }
  if (req.method !== "POST") return reply(405, { error: "Alleen POST toegestaan." }, origin);

  // 1. Wie roept aan?
  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+$/.test(auth)) return reply(401, { error: "Log opnieuw in." }, origin);
  const asUser = createClient(API, ANON, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: who, error: whoErr } = await asUser.auth.getUser(auth.replace(/^Bearer\s+/, ""));
  if (whoErr || !who?.user) return reply(401, { error: "Log opnieuw in." }, origin);
  const uid = who.user.id;

  let body: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 2000) throw Error("too large");
    body = JSON.parse(raw);
  } catch { return reply(400, { error: "Ongeldige aanvraag." }, origin); }
  const mandateId = typeof body?.mandate_id === "string" ? body.mandate_id.toLowerCase() : "";
  if (!UUID.test(mandateId)) return reply(400, { error: "Ongeldige machtiging." }, origin);

  // 2. Machtiging en organisatie opzoeken (server-side)
  const m = await db.from("huos_beer_mandates").select("id,organization_id").eq("id", mandateId).maybeSingle();
  if (m.error) { console.error("mandate lookup", m.error.code); return reply(503, { error: "Tijdelijk niet beschikbaar." }, origin); }
  if (!m.data) return reply(404, { error: "Machtiging niet gevonden." }, origin);
  if (!m.data.organization_id) {
    const st = await asUser.rpc("huos_staff_has", { p_min_role: "reviewer" });
    if (st.data !== true) return reply(404, { error: "Machtiging niet gevonden." }, origin);
    return reply(409, { error: "Koppel deze aanvraag eerst aan een pilotklant; daarna kan de PDF worden gemaakt." }, origin);
  }
  const orgId = m.data.organization_id as string;
  const o = await db.from("huos_pilot_organizations").select("id,owner_id,name").eq("id", orgId).maybeSingle();
  if (o.error || !o.data?.owner_id) return reply(404, { error: "Machtiging niet gevonden." }, origin);
  const ownerId = o.data.owner_id as string;

  // 3. Mag deze gebruiker dit? Eigenaar van de organisatie, of staff met toegang tot de organisatie.
  let actor = "klant";
  if (uid !== ownerId) {
    const [r1, r2] = await Promise.all([
      asUser.rpc("huos_staff_has", { p_min_role: "reviewer" }),
      asUser.rpc("huos_staff_can_access_org", { p_org: orgId }),
    ]);
    if (r1.data !== true || r2.data !== true) return reply(404, { error: "Machtiging niet gevonden." }, origin);
    actor = "staff";
  }

  // 4. Ondertekeningen zonder PDF
  const s = await db.from("huos_mandate_signatures")
    .select("id,kind,signer_name,signer_function,org_name,org_kvk,suppliers,periods,data_categories,text_version,text_rendered,text_sha256,method,signed_at,pdf_document_id")
    .eq("mandate_id", mandateId).order("signed_at", { ascending: true }).limit(40);
  if (s.error) { console.error("signatures", s.error.code); return reply(503, { error: "Tijdelijk niet beschikbaar." }, origin); }
  const todo = (s.data ?? []).filter((g) => !g.pdf_document_id);
  if (!todo.length) return reply(200, { ok: true, created: [], message: "Alle PDF's zijn er al." }, origin);

  const t = await db.from("huos_mandate_texts").select("version,title").in("version", [...new Set(todo.map((g) => g.text_version))]);
  const titles = Object.fromEntries((t.data ?? []).map((x) => [x.version, x.title]));

  const created: { signature_id: string; document_id: string }[] = [];
  const failed: string[] = [];
  for (const g of todo.slice(0, 10)) {
    try {
      // Tekst moet nog exact overeenkomen met de vastgelegde vingerafdruk
      if ((await sha256Hex(g.text_rendered)) !== g.text_sha256) throw Error("vingerafdruk tekst klopt niet");
      const now = new Date();
      const pdf = await buildMandatePdf(g as Signature, titles[g.text_version] || "Machtiging leveranciersgegevens", now);
      const hash = await sha256Hex(pdf);
      const stamp = now.toISOString().replace(/[-:]/g, "").slice(0, 15);
      const path = `${ownerId}/${orgId}/machtigingen/${g.id}-${stamp}.pdf`;
      const up = await db.storage.from(BUCKET).upload(path, pdf, { contentType: "application/pdf", upsert: false });
      if (up.error) throw Error("opslaan bestand: " + up.error.message);
      const day = String(g.signed_at).slice(0, 10);
      const fileName = `Machtiging ${safeName(g.org_name)} ${day}${g.kind === "initial" ? "" : " aanvulling"}.pdf`;
      const d = await db.from("huos_pilot_documents").insert({
        organization_id: orgId, uploaded_by: ownerId, storage_path: path, file_name: fileName.slice(0, 255),
        file_type: "application/pdf", category: "mandate", status: "verified", content_hash: hash,
      }).select("id").single();
      if (d.error) throw Error("registratie document: " + d.error.code);
      // Eenmalig koppelen; de database staat later wijzigen niet toe.
      const u = await db.from("huos_mandate_signatures").update({ pdf_document_id: d.data.id, pdf_sha256: hash })
        .eq("id", g.id).is("pdf_document_id", null).select("id");
      if (u.error) throw Error("koppelen: " + u.error.code);
      if (!u.data?.length) { failed.push(g.id); continue; } // tegelijk al door een andere aanroep gekoppeld
      await db.rpc("huos_mandate_log", {
        p_mandate: mandateId, p_event: "mandate_pdf_created", p_entity_id: g.id,
        p_details: { document_id: d.data.id, pdf_sha256: hash, by: actor, by_user: uid },
      });
      created.push({ signature_id: g.id, document_id: d.data.id });
    } catch (e) {
      console.error("pdf failed", g.id, (e as Error).message);
      failed.push(g.id);
    }
  }
  if (!created.length && failed.length) return reply(500, { error: "De PDF kon niet worden gemaakt. Probeer het later opnieuw.", failed }, origin);
  return reply(200, { ok: true, created, failed }, origin);
});

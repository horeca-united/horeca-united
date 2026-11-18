// Bouwt de PDF van één ondertekening van de leveranciersmachtiging.
// Puur: geen netwerk, geen database. Zo is hij lokaal te testen.
import { PDFDocument, StandardFonts, rgb, type PDFFont, type PDFPage } from "npm:pdf-lib@1.17.1";

export type Signature = {
  id: string;
  kind: string;
  signer_name: string;
  signer_function: string;
  org_name: string;
  org_kvk: string | null;
  suppliers: { name: string; role?: string }[];
  periods: { start: string; end: string; kind?: string; label?: string }[];
  data_categories: string[];
  text_version: string;
  text_rendered: string;
  text_sha256: string;
  method: string;
  signed_at: string;
};

const CAT: Record<string, string> = {
  volume: "Afnamegegevens (producten en hoeveelheden)",
  prices: "Inkoopprijzen (gefactureerd, incl. directe kortingen)",
  discounts: "Kortingen",
  bonuses: "Bonussen",
  contract_terms: "Contractvoorwaarden",
};
const KIND: Record<string, string> = {
  initial: "Ondertekening",
  addendum: "Aanvulling (extra leverancier)",
};
const METHOD: Record<string, string> = {
  huos_account_checkbox: "Akkoord gegeven in het ingelogde HUOS-account (bevestiging bevoegdheid + akkoordknop)",
};

const nlDate = (iso: string) => {
  const [y, m, d] = String(iso).slice(0, 10).split("-");
  return d && m && y ? `${d}-${m}-${y}` : String(iso);
};
export const nlDateTime = (iso: string) =>
  new Intl.DateTimeFormat("nl-NL", {
    timeZone: "Europe/Amsterdam", day: "2-digit", month: "2-digit", year: "numeric",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).format(new Date(iso)) + " (Nederlandse tijd)";

export async function buildMandatePdf(sig: Signature, title: string, generatedAt: Date): Promise<Uint8Array> {
  const doc = await PDFDocument.create();
  const reg = await doc.embedFont(StandardFonts.Helvetica);
  const bold = await doc.embedFont(StandardFonts.HelveticaBold);
  doc.setTitle(`${title} — ${sig.org_name}`);
  doc.setAuthor("Horeca United (HUOS)");
  doc.setSubject(`Ondertekening ${sig.id}`);
  doc.setCreator("HUOS");
  doc.setProducer("HUOS");
  doc.setCreationDate(generatedAt);
  doc.setModificationDate(generatedAt);

  // Standaardfonts kennen alleen WinAnsi-tekens: vervang de rest.
  const okChar = new Map<string, boolean>();
  const clean = (s: string) =>
    Array.from(String(s ?? "").replace(/\r/g, "").replace(/\t/g, " ")).map((ch) => {
      if (ch === "\n") return ch;
      if (!okChar.has(ch)) {
        try { reg.encodeText(ch); bold.encodeText(ch); okChar.set(ch, true); } catch { okChar.set(ch, false); }
      }
      return okChar.get(ch) ? ch : "?";
    }).join("");

  const W = 595.28, H = 841.89, M = 56, CW = W - 2 * M;
  const ink = rgb(0.1, 0.12, 0.14), mute = rgb(0.4, 0.43, 0.46), line = rgb(0.82, 0.84, 0.86);
  let page: PDFPage = doc.addPage([W, H]);
  let y = H - M;
  const newPage = () => { page = doc.addPage([W, H]); y = H - M; };
  const need = (h: number) => { if (y - h < M + 30) newPage(); };

  const wrap = (text: string, font: PDFFont, size: number, width: number) => {
    const out: string[] = [];
    for (const para of clean(text).split("\n")) {
      if (!para.trim()) { out.push(""); continue; }
      let cur = "";
      for (const word of para.split(/ +/)) {
        const t = cur ? cur + " " + word : word;
        if (font.widthOfTextAtSize(t, size) <= width) { cur = t; continue; }
        if (cur) out.push(cur);
        // Te lang woord: hard afbreken
        let w = word;
        while (font.widthOfTextAtSize(w, size) > width) {
          let i = w.length;
          while (i > 1 && font.widthOfTextAtSize(w.slice(0, i), size) > width) i--;
          out.push(w.slice(0, i)); w = w.slice(i);
        }
        cur = w;
      }
      out.push(cur);
    }
    return out;
  };
  const para = (text: string, o: { font?: PDFFont; size?: number; color?: ReturnType<typeof rgb>; x?: number; width?: number; gap?: number } = {}) => {
    const font = o.font ?? reg, size = o.size ?? 10.5, lh = size * 1.42, x = o.x ?? M, width = o.width ?? CW;
    for (const l of wrap(text, font, size, width)) {
      need(lh);
      if (l) page.drawText(l, { x, y: y - size, size, font, color: o.color ?? ink });
      y -= lh;
    }
    y -= o.gap ?? 0;
  };
  const rule = () => { need(14); page.drawLine({ start: { x: M, y: y - 4 }, end: { x: W - M, y: y - 4 }, thickness: 0.7, color: line }); y -= 14; };
  const heading = (t: string) => { need(34); y -= 6; para(t, { font: bold, size: 12, gap: 4 }); };
  const kv = (k: string, v: string, size = 10.5) => {
    const kw = 150, lh = Math.max(size, 10.5) * 1.42;
    const lines = wrap(v || "—", reg, size, CW - kw);
    need(lh * Math.max(1, lines.length));
    page.drawText(clean(k), { x: M, y: y - 10.5, size: 10.5, font: reg, color: mute });
    lines.forEach((l, i) => page.drawText(l, { x: M + kw, y: y - size - i * lh, size, font: reg, color: ink }));
    y -= lh * Math.max(1, lines.length) + 2;
  };

  // Kop
  para("Horeca United", { font: bold, size: 10, color: mute });
  para("Aziaat Holding B.V. (KvK 73911437), handelend onder de naam Horeca United", { size: 9, color: mute, gap: 10 });
  para(title, { font: bold, size: 18, gap: 2 });
  para(KIND[sig.kind] ?? sig.kind, { size: 11, color: mute, gap: 6 });
  rule();

  heading("Gegevens van de ondertekening");
  kv("Onderneming", sig.org_name);
  kv("KvK-nummer", sig.org_kvk || "niet ingevuld");
  kv("Ondertekend door", sig.signer_name);
  kv("Functie", sig.signer_function);
  kv("Ondertekend op", nlDateTime(sig.signed_at));
  kv("Wijze van tekenen", METHOD[sig.method] ?? sig.method);
  kv("Leverancier(s)", (sig.suppliers || []).map((s) => s.name).join(", "));
  kv("Periode(s)", (sig.periods || []).map((p) => `${p.label ? p.label + ": " : ""}${nlDate(p.start)} t/m ${nlDate(p.end)}`).join("\n"));
  kv("Gegevens", (sig.data_categories || []).map((c) => CAT[c] ?? c).join("\n"));
  kv("Tekstversie", sig.text_version);

  heading("Getekende tekst");
  para(sig.text_rendered, { size: 10.5, gap: 6 });
  rule();

  heading("Controlegegevens");
  para("Deze PDF is automatisch door HUOS gemaakt van de vastgelegde ondertekening. De ondertekening zelf kan niet worden gewijzigd. Met de vingerafdruk hieronder is te controleren dat de tekst ongewijzigd is.", { size: 9, color: mute, gap: 4 });
  kv("Kenmerk", sig.id);
  kv("Vingerafdruk (SHA-256)", sig.text_sha256, 8.5);
  kv("PDF gemaakt op", nlDateTime(generatedAt.toISOString()));

  // Voettekst op elke pagina
  const pages = doc.getPages();
  pages.forEach((p, i) => {
    const t = clean(`Machtiging ${sig.org_name} · kenmerk ${sig.id.slice(0, 8)} · pagina ${i + 1} van ${pages.length}`);
    p.drawText(t, { x: M, y: M - 24, size: 8, font: reg, color: mute });
  });
  return await doc.save({ useObjectStreams: false });
}

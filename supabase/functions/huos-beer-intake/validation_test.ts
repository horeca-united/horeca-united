import { assertEquals } from "jsr:@std/assert@1";
import { validateIntakeBody } from "./validation.ts";

const currentVersion = "huos-mandate-v3-2026-11";
const validBody = (): Record<string, unknown> => ({
  privacy_accepted: true,
  company_name: " Café de Test ",
  contact_name: " Ada Lovelace ",
  email: " ADA@example.nl ",
  phone: " 0612345678 ",
  answers: { annual_volume_hl: "120", tap_beer_brand: "Testbier" },
});

Deno.test("normalizes contact data and answer fields", async () => {
  const result = await validateIntakeBody(validBody(), async () => null);

  assertEquals(result.ok, true);
  if (!result.ok) return;
  assertEquals(result.data.company_name, "Café de Test");
  assertEquals(result.data.contact_name, "Ada Lovelace");
  assertEquals(result.data.email, "ada@example.nl");
  assertEquals(result.data.phone, "0612345678");
  assertEquals(result.data.answers, {
    annual_volume_hl: 120,
    tap_beer_brand: "Testbier",
  });
  assertEquals(result.data.data_route, "later_upload");
});

Deno.test("rejects missing consent, malformed contact details, and unknown answer fields", async () => {
  const noConsent = validBody();
  noConsent.privacy_accepted = false;
  assertEquals(
    (await validateIntakeBody(noConsent, async () => null)).ok,
    false,
  );

  const badEmail = validBody();
  badEmail.email = "not-an-email";
  assertEquals(
    (await validateIntakeBody(badEmail, async () => null)).ok,
    false,
  );

  const unknownField = validBody();
  unknownField.answers = { unexpected: "value" };
  const unknownResult = await validateIntakeBody(
    unknownField,
    async () => null,
  );
  assertEquals(unknownResult.ok, false);
  if (!unknownResult.ok) {
    assertEquals(unknownResult.error, "Onbekend antwoordveld.");
  }
});

Deno.test("enforces numeric answer bounds and text length", async () => {
  const tooLarge = validBody();
  tooLarge.answers = { annual_volume_hl: 100001 };
  const numericResult = await validateIntakeBody(tooLarge, async () => null);
  assertEquals(numericResult.ok, false);

  const longText = validBody();
  longText.answers = { tap_beer_brand: "x".repeat(161) };
  assertEquals(
    (await validateIntakeBody(longText, async () => null)).ok,
    false,
  );
});

Deno.test("requires a current mandate version and validates mandate fields", async () => {
  const stale = validBody();
  stale.data_route = "mandate";
  stale.mandate_consent = true;
  stale.mandate_authority_asserted = true;
  stale.mandate_consent_version = currentVersion;
  stale.mandate = {
    kvk: "12345678",
    signer_function: "Eigenaar",
    fiscal_month: 1,
    period: "closed",
    suppliers: [{ name: "Test leverancier", role: "brouwerij" }],
  };

  const staleResult = await validateIntakeBody(
    stale,
    async () => "old-version",
  );
  assertEquals(staleResult.ok, false);
  if (!staleResult.ok) assertEquals(staleResult.status, 409);

  const validResult = await validateIntakeBody(
    stale,
    async () => currentVersion,
  );
  assertEquals(validResult.ok, true);
  if (validResult.ok) {
    assertEquals(validResult.data.v3?.kvk, "12345678");
    assertEquals(validResult.data.v3?.suppliers[0].role, "brouwerij");
  }
});

Deno.test("does not fetch mandate version for non-mandate submissions", async () => {
  let calls = 0;
  const result = await validateIntakeBody(validBody(), async () => {
    calls += 1;
    return currentVersion;
  });
  assertEquals(result.ok, true);
  assertEquals(calls, 0);
});

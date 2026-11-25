export type DataRoute = "later_upload" | "mandate" | "none";

export type MandateSupplier = {
  name: string;
  role: string;
};

export type IntakeAnswers = Record<string, string | number>;

export type IntakeData = {
  company_name: string;
  contact_name: string;
  email: string;
  phone: string;
  data_route: DataRoute;
  has_mandate: boolean;
  version: string;
  answers: IntakeAnswers;
  v3: null | {
    kvk: string;
    fn: string;
    month: number;
    period: string;
    suppliers: MandateSupplier[];
  };
};

export type ValidationResult =
  | { ok: true; data: IntakeData }
  | { ok: false; status: 400 | 409; error: string };

const ALLOWED_ANSWER_FIELDS = new Set([
  "brewery_supplier",
  "brewery_supplier_other",
  "tap_beer_brand",
  "tap_beer_brand_other",
  "distributor",
  "distributor_other",
  "direct_delivery_brewery",
  "keg_size_l",
  "keg_size_l_other",
  "keg_price_ex_vat",
  "annual_volume_hl",
  "annual_volume_source",
  "bonus_status",
  "contract_end_status",
  "contract_end_date",
  "purchase_obligation",
  "installation_status",
  "brewery_loan_status",
  "proposal_interest",
  "willingness_to_switch",
]);

const NUMERIC_ANSWER_FIELDS = new Set(["keg_price_ex_vat", "annual_volume_hl"]);
const MANDATE_V1 = "huos-mandate-beer-v1";
const MANDATE_V3_PREFIX = "huos-mandate-v3";
const SUPPLIER_ROLES = new Set([
  "brouwerij",
  "drankleverancier",
  "groothandel",
  "vers",
  "energie",
  "verzekering",
  "overig",
]);

const text = (value: unknown, maxLength: number): string =>
  typeof value === "string" ? value.trim().slice(0, maxLength) : "";

const isRecord = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const invalid = (error: string, status: 400 | 409 = 400): ValidationResult => ({
  ok: false,
  status,
  error,
});

/**
 * Validate and normalize the public beer-intake payload.
 * The current mandate-version lookup is injected so validation remains pure
 * apart from that explicit read and does not create a Supabase client itself.
 */
export async function validateIntakeBody(
  body: Record<string, unknown>,
  getCurrentMandateVersion: () => Promise<string | null>,
): Promise<ValidationResult> {
  if (body.privacy_accepted !== true) {
    return invalid(
      "Bevestig eerst dat wij de ingevulde gegevens mogen gebruiken om je aanvraag te beoordelen.",
    );
  }

  const company_name = text(body.company_name, 161);
  const contact_name = text(body.contact_name, 121);
  const email = text(body.email, 251).toLowerCase();
  const phone = text(body.phone, 51);
  if (
    company_name.length < 2 || company_name.length > 160 ||
    contact_name.length < 2 || contact_name.length > 120 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 250 ||
    phone.length > 50
  ) {
    return invalid(
      "Vul de bedrijfsnaam, de naam van de contactpersoon en een geldig e-mailadres in.",
    );
  }

  const rawRoute = text(body.data_route, 30) || "later_upload";
  if (!(["later_upload", "mandate", "none"] as string[]).includes(rawRoute)) {
    return invalid("Kies een geldige manier om de gegevens aan te vullen.");
  }
  const data_route = rawRoute as DataRoute;
  const has_mandate = data_route === "mandate";
  const version = text(body.mandate_consent_version, 60);
  let v3: IntakeData["v3"] = null;

  if (has_mandate) {
    if (
      body.mandate_consent !== true || body.mandate_authority_asserted !== true
    ) {
      return invalid(
        "Voor een machtiging moet een bevoegde vertegenwoordiger de verklaring bevestigen.",
      );
    }

    if (version.startsWith(MANDATE_V3_PREFIX)) {
      const currentVersion = await getCurrentMandateVersion();
      if (!currentVersion || currentVersion !== version) {
        return invalid(
          "De machtigingstekst is gewijzigd. Vernieuw de pagina en probeer het opnieuw.",
          409,
        );
      }

      const mandate = isRecord(body.mandate) ? body.mandate : {};
      const kvk = text(mandate.kvk, 20).replace(/\s/g, "");
      const fn = text(mandate.signer_function, 81);
      const month = Number(mandate.fiscal_month);
      const period = text(mandate.period, 10);
      const supplierList = Array.isArray(mandate.suppliers)
        ? mandate.suppliers.slice(0, 16)
        : [];
      const suppliers = supplierList
        .map((supplier) => {
          const record = isRecord(supplier) ? supplier : {};
          return {
            name: text(record.name, 121),
            role: text(record.role, 30),
          };
        })
        .filter((supplier) =>
          supplier.name.length >= 2 && supplier.name.length <= 120
        )
        .map((supplier) => ({
          name: supplier.name,
          role: SUPPLIER_ROLES.has(supplier.role) ? supplier.role : "overig",
        }));

      if (!/^\d{8}$/.test(kvk)) {
        return invalid("Vul een geldig KvK-nummer in (8 cijfers).");
      }
      if (fn.length < 2 || fn.length > 80) return invalid("Vul je functie in.");
      if (!Number.isInteger(month) || month < 1 || month > 12) {
        return invalid("Kies de maand waarin je boekjaar begint.");
      }
      if (!(["closed", "current", "both"] as string[]).includes(period)) {
        return invalid("Kies over welke periode we gegevens mogen opvragen.");
      }
      if (!suppliers.length || suppliers.length > 15) {
        return invalid("Kies minstens één leverancier.");
      }
      v3 = { kvk, fn, month, period, suppliers };
    } else if (version !== MANDATE_V1) {
      return invalid(
        "Voor een machtiging moet een bevoegde vertegenwoordiger de verklaring bevestigen.",
      );
    }
  }

  const rawAnswers = body.answers;
  if (
    !isRecord(rawAnswers) || Object.keys(rawAnswers).length === 0 ||
    Object.keys(rawAnswers).length > 28
  ) {
    return invalid("De antwoorden ontbreken of zijn ongeldig.");
  }

  const answers: IntakeAnswers = {};
  for (const [key, value] of Object.entries(rawAnswers)) {
    if (!ALLOWED_ANSWER_FIELDS.has(key)) {
      return invalid("Onbekend antwoordveld.");
    }
    if (NUMERIC_ANSWER_FIELDS.has(key)) {
      const number = Number(value);
      if (!Number.isFinite(number) || number < 0 || number > 100000) {
        return invalid("Controleer de ingevulde aantallen en prijzen.");
      }
      answers[key] = number;
    } else if (typeof value === "string" && value.length <= 160) {
      answers[key] = value.trim();
    } else {
      return invalid("Een antwoord is te lang of ongeldig.");
    }
  }

  return {
    ok: true,
    data: {
      company_name,
      contact_name,
      email,
      phone,
      data_route,
      has_mandate,
      version,
      answers,
      v3,
    },
  };
}

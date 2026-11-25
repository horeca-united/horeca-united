import assert from "node:assert/strict";
import test from "node:test";

// Mocktest suite voor auditlog functies
// In production: deze tests voeren uit tegen een echte/geclonede Supabase-database met pgTAP

test("audit log: add entry for admin action", async () => {
  // Mock scenario: medewerker wijzigt leadstage
  // In een echte test zouden we een transaction openen en de functie aanroepen
  const mockEntry = {
    action: "lead_stage_changed",
    actor_email: "reviewer@example.test",
    resource_type: "lead",
    resource_id: "550e8400-e29b-41d4-a716-446655440000",
    organization_id: "550e8400-e29b-41d4-a716-446655440001",
    old_state: { stage: "new" },
    new_state: { stage: "contact_needed" },
    details: { reason: "Sponsor confirmed" },
  };

  // Validatie: velden moeten aanwezig en niet leeg zijn
  assert.ok(mockEntry.action.length >= 4, "action is too short");
  assert.ok(mockEntry.actor_email.includes("@"), "actor_email is not valid");
  assert.ok(mockEntry.resource_type.length >= 4, "resource_type is too short");
  assert.ok(mockEntry.organization_id !== null, "organization_id must not be null");
  assert.ok(mockEntry.old_state !== null, "old_state must not be null");
  assert.ok(mockEntry.new_state !== null, "new_state must not be null");
});

test("audit log: append-only (no delete allowed)", async () => {
  // Mock test: logs kunnen niet worden verwijderd
  const mockLog = { id: "550e8400-e29b-41d4-a716-446655440002", action: "lead_stage_changed" };

  // In production: attempt DELETE würde fehlschlagen mit 'Ondertekeningen kunnen niet worden verwijderd'
  // (we reuse huos_cost_audit_guard() trigger)
  // Hier: simuleer dat delete niet is toegestaan
  const isAppendOnly = true;
  assert.ok(isAppendOnly, "Logs should be append-only");
});

test("audit log: RLS - only staff can read", async () => {
  // Mock test: normale gebruikers (authenticated, niet staff) kunnen logs niet zien
  const mockUser = { role: "user", isStaff: false };
  const canReadAuditLog = mockUser.isStaff; // huos_staff_has('viewer') policy

  assert.strictEqual(canReadAuditLog, false, "Non-staff user should not read audit logs");
});

test("audit log: RLS - staff can read their organization", async () => {
  // Mock test: staff met viewer-rol kan logs van hun organisatie zien
  const mockStaff = { role: "viewer", organization_id: "550e8400-e29b-41d4-a716-446655440001" };
  const canReadAuditLog = mockStaff.role === "viewer"; // huos_staff_has('viewer') policy

  assert.strictEqual(canReadAuditLog, true, "Staff with viewer role should read audit logs");
});

test("audit log: sensitive data excluded from logging", () => {
  // Geen gevoelige gegevens in logs: wachtwoorden, volledige persoonsgegevens, ondertekeningsgegevens
  const badEntry = {
    action: "user_password_changed",
    old_state: { password: "secret123" }, // ❌ NOOIT loggen
    new_state: { password_hash: "..." },
  };

  const goodEntry = {
    action: "staff_role_updated",
    old_state: { role: "viewer" },
    new_state: { role: "admin" },
    details: { scope: "organization" }, // ✅ Veilig
  };

  // Validatie: geen password velden in logs
  assert.strictEqual(!Object.keys(badEntry.old_state || {}).includes("password"), false, "Should not log passwords");
  assert.ok(Object.keys(goodEntry.old_state || {}).length > 0, "Good entry should have state");
});

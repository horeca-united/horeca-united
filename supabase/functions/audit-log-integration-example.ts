// Voorbeeld: hoe auditlog-functies in Edge Functions worden gebruikt
// Dit is GEEN werkende code, maar een template voor toekomstige integratie

// Scenario: Een medewerker voert een admin-actie uit op een lead
// Bijvoorbeeld: stage wijziging van 'new' naar 'contact_needed'

/*

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

export async function changeLeadStageWithAudit(
  leadId: string,
  oldStage: string,
  newStage: string,
  changeReason?: string
) {
  // 1. Voer de eigenlijke wijziging uit
  const { data: lead, error: updateError } = await supabase
    .from("huos_beer_leads")
    .update({
      stage: newStage,
      stage_changed_at: new Date().toISOString(),
    })
    .eq("id", leadId)
    .select()
    .single();

  if (updateError) throw updateError;

  // 2. Log de actie
  const { data: logEntry, error: auditError } = await supabase.rpc(
    "huos_audit_log_add_via_lead",
    {
      p_action: "lead_stage_changed",
      p_lead_id: leadId,
      p_resource_type: "lead",
      p_resource_id: leadId,
      p_old_state: JSON.stringify({ stage: oldStage }),
      p_new_state: JSON.stringify({ stage: newStage }),
      p_details: JSON.stringify({
        reason: changeReason || "No reason provided",
        timestamp: new Date().toISOString(),
      }),
    }
  );

  if (auditError) {
    console.error("Audit log failed:", auditError);
    // Log-failure retourneert niet, want de eigenlijke wijziging slaagde
  }

  return { lead, auditLogId: logEntry };
}

// Scenario 2: Een contract wordt gearchiveerd
export async function archiveContractWithAudit(
  contractId: string,
  organizationId: string
) {
  // 1. Voer wijziging uit
  const { data: contract, error: updateError } = await supabase
    .from("huos_pilot_contracts")
    .update({
      archived_at: new Date().toISOString(),
    })
    .eq("id", contractId)
    .select()
    .single();

  if (updateError) throw updateError;

  // 2. Log
  const { data: logEntry, error: auditError } = await supabase.rpc(
    "huos_audit_log_add",
    {
      p_action: "contract_archived",
      p_resource_type: "contract",
      p_resource_id: contractId,
      p_organization_id: organizationId,
      p_old_state: JSON.stringify({ archived_at: null }),
      p_new_state: JSON.stringify({
        archived_at: new Date().toISOString(),
      }),
      p_details: JSON.stringify({ contract_name: contract.name || "Unknown" }),
    }
  );

  if (auditError) console.error("Audit log failed:", auditError);

  return contract;
}
*/

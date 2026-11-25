import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const ACCEPTED_ORIGINS = new Set(["https://huos-v2-prive-pilot.vercel.app","https://mijn.horecaunited.nl"]);
const TURNSTILE_SITE_KEY=(Deno.env.get("HUOS_TURNSTILE_SITE_KEY")??"").trim();
const TURNSTILE_SECRET=(Deno.env.get("HUOS_TURNSTILE_SECRET_KEY")??"").trim();
const TURNSTILE_ENABLED=Boolean(TURNSTILE_SITE_KEY&&TURNSTILE_SECRET);
const TURNSTILE_HOSTS=new Set(["huos-v2-prive-pilot.vercel.app","mijn.horecaunited.nl"]);
const API = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const db = createClient(API, SERVICE_KEY, {auth:{persistSession:false,autoRefreshToken:false}});
const text = (v:unknown,n:number)=>typeof v==="string"?v.trim().slice(0,n):"";
const allowedFields=new Set(["brewery_supplier","brewery_supplier_other","tap_beer_brand","tap_beer_brand_other","distributor","distributor_other","direct_delivery_brewery","keg_size_l","keg_size_l_other","keg_price_ex_vat","annual_volume_hl","annual_volume_source","bonus_status","contract_end_status","contract_end_date","purchase_obligation","installation_status","brewery_loan_status","proposal_interest","willingness_to_switch"]);
const numericFields=new Set(["keg_price_ex_vat","annual_volume_hl"]);
const MANDATE_V1="huos-mandate-beer-v1";
const ROLES=new Set(["brouwerij","drankleverancier","groothandel","vers","energie","verzekering","overig"]);
const response=(status:number,data:Record<string,unknown>,origin:string)=>new Response(JSON.stringify(data),{status,headers:{"Content-Type":"application/json; charset=utf-8","Access-Control-Allow-Origin":origin,"Vary":"Origin","Cache-Control":"no-store","X-Content-Type-Options":"nosniff","Referrer-Policy":"no-referrer","X-Frame-Options":"DENY","Cross-Origin-Resource-Policy":"same-site"}});
async function hash(value:string){
 const secret=SERVICE_KEY.slice(-48);
 const raw=new TextEncoder().encode(secret+"|"+value);
 const dig=await crypto.subtle.digest("SHA-256",raw);
 return Array.from(new Uint8Array(dig),b=>b.toString(16).padStart(2,"0")).join("");
}
// Machtigingstekst (v3) en boekjaaropties: kort in het geheugen bewaren.
let mandateCfg:{at:number;data:Record<string,unknown>|null}={at:0,data:null};
async function mandateConfig(){
 if(mandateCfg.data&&Date.now()-mandateCfg.at<5*60*1000)return mandateCfg.data;
 const r=await db.rpc("huos_intake_mandate_public_config");
 if(r.error){console.error("mandate config",r.error.code);return mandateCfg.data}
 mandateCfg={at:Date.now(),data:r.data as Record<string,unknown>};
 return mandateCfg.data;
}
Deno.serve(async(req)=>{
 const origin=req.headers.get("origin")??"";
 if(!ACCEPTED_ORIGINS.has(origin))return response(403,{error:"Ongeldige herkomst."},"null");
 if(req.method==="OPTIONS")return new Response(null,{status:204,headers:{"Access-Control-Allow-Origin":origin,"Access-Control-Allow-Methods":"GET, POST, OPTIONS","Access-Control-Allow-Headers":"content-type","Access-Control-Max-Age":"3600","Vary":"Origin"}});
 if(req.method==="GET"){const cfg=await mandateConfig();return response(200,{turnstile_enabled:TURNSTILE_ENABLED,turnstile_site_key:TURNSTILE_ENABLED?TURNSTILE_SITE_KEY:null,mandate:cfg},origin)}
 if(req.method!=="POST")return response(405,{error:"Alleen POST toegestaan."},origin);
 const size=Number(req.headers.get("content-length")??"0");
 if(size>20000)return response(413,{error:"Aanvraag te groot."},origin);
 let body:Record<string,unknown>;
 try{const raw=await req.text();if(raw.length>20000)throw Error("too large");body=JSON.parse(raw);if(!body||Array.isArray(body)||typeof body!=="object")throw Error("bad body");}
 catch{return response(400,{error:"Ongeldige aanvraag."},origin)}
 if(text(body.website,250))return response(202,{ok:true},origin); // honeypot
 // When both production keys are configured, verify the short-lived,
 // single-use Turnstile token on Cloudflare's server before accepting data.
 if(TURNSTILE_ENABLED){
  const token=text(body.turnstile_token,2049);
  if(token.length<10||token.length>2048)return response(403,{error:"Bevestig de anti-spamcontrole voordat je verstuurt."},origin);
  let check:{success?:boolean;hostname?:string;action?:string};
  try{
   const challenge=await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify",{
    method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},
    body:new URLSearchParams({secret:TURNSTILE_SECRET,response:token}),
    signal:AbortSignal.timeout(8000)
   });
   if(!challenge.ok)throw Error("siteverify HTTP failure");
   check=await challenge.json();
  }catch(err){
   console.error("Turnstile verification unavailable");
   return response(503,{error:"Anti-spamcontrole tijdelijk niet beschikbaar. Probeer opnieuw."},origin);
  }
  if(check.success!==true||!TURNSTILE_HOSTS.has(check.hostname??"")||check.action!=="beer_intake"){
   return response(403,{error:"Anti-spamcontrole mislukt of verlopen. Probeer opnieuw."},origin);
  }
 }
 if(body.privacy_accepted!==true)return response(400,{error:"Bevestig eerst dat wij de ingevulde gegevens mogen gebruiken om je aanvraag te beoordelen."},origin);
 const company_name=text(body.company_name,161),contact_name=text(body.contact_name,121),email=text(body.email,251).toLowerCase(),phone=text(body.phone,51);
 if(company_name.length<2||contact_name.length<2||company_name.length>160||contact_name.length>120||!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)||email.length>250||phone.length>50)return response(400,{error:"Vul de bedrijfsnaam, de naam van de contactpersoon en een geldig e-mailadres in."},origin);
 const data_route=text(body.data_route,30)||"later_upload";
 if(!["later_upload","mandate","none"].includes(data_route))return response(400,{error:"Kies een geldige manier om de gegevens aan te vullen."},origin);
 const has_mandate=data_route==="mandate";
 // Machtiging: oude bevestiging (v1) of volledige machtiging versie 3 met alle gegevens.
 const version=text(body.mandate_consent_version,60);
 let v3:null|{kvk:string;fn:string;month:number;period:string;suppliers:{name:string;role:string}[]}=null;
 if(has_mandate){
  if(body.mandate_consent!==true||body.mandate_authority_asserted!==true)return response(400,{error:"Voor een machtiging moet een bevoegde vertegenwoordiger de verklaring bevestigen."},origin);
  if(version.startsWith("huos-mandate-v3")){
   const cfg=await mandateConfig();
   const cur=(cfg?.text as {version?:string}|undefined)?.version;
   if(!cur||cur!==version)return response(409,{error:"De machtigingstekst is gewijzigd. Vernieuw de pagina en probeer het opnieuw."},origin);
   const m=(body.mandate&&typeof body.mandate==="object"&&!Array.isArray(body.mandate))?body.mandate as Record<string,unknown>:{};
   const kvk=text(m.kvk,20).replace(/\s/g,""),fn=text(m.signer_function,81),month=Number(m.fiscal_month),period=text(m.period,10);
   const list=Array.isArray(m.suppliers)?m.suppliers.slice(0,16):[];
   const suppliers=list.map((s)=>({name:text((s as Record<string,unknown>)?.name,121),role:text((s as Record<string,unknown>)?.role,30)})).filter(s=>s.name.length>=2&&s.name.length<=120).map(s=>({name:s.name,role:ROLES.has(s.role)?s.role:"overig"}));
   if(!/^\d{8}$/.test(kvk))return response(400,{error:"Vul een geldig KvK-nummer in (8 cijfers)."},origin);
   if(fn.length<2||fn.length>80)return response(400,{error:"Vul je functie in."},origin);
   if(!Number.isInteger(month)||month<1||month>12)return response(400,{error:"Kies de maand waarin je boekjaar begint."},origin);
   if(!["closed","current","both"].includes(period))return response(400,{error:"Kies over welke periode we gegevens mogen opvragen."},origin);
   if(!suppliers.length||suppliers.length>15)return response(400,{error:"Kies minstens één leverancier."},origin);
   v3={kvk,fn,month,period,suppliers};
  }else if(version!==MANDATE_V1){
   return response(400,{error:"Voor een machtiging moet een bevoegde vertegenwoordiger de verklaring bevestigen."},origin);
  }
 }
 const data=body.answers;
 if(!data||typeof data!=="object"||Array.isArray(data)||Object.keys(data).length===0||Object.keys(data).length>28)return response(400,{error:"De antwoorden ontbreken of zijn ongeldig."},origin);
 const answers:Record<string,string|number>={};
 for(const [key,val] of Object.entries(data)){
  if(!allowedFields.has(key))return response(400,{error:"Onbekend antwoordveld."},origin);
  if(numericFields.has(key)){
   const n=Number(val);
   if(!Number.isFinite(n)||n<0||n>100000)return response(400,{error:"Controleer de ingevulde aantallen en prijzen."},origin);
   answers[key]=n;
  }else if(typeof val==="string"&&val.length<=160)answers[key]=val.trim();
  else return response(400,{error:"Een antwoord is te lang of ongeldig."},origin);
 }
 // Only use the Cloudflare edge header. Never trust the first X-Forwarded-For
 // element; a caller can place arbitrary values there. Missing/invalid IPs
 // share a conservative bucket, while the per-email limiter still applies.
 const edgeIp=(req.headers.get("cf-connecting-ip")??"").trim();
 const ip=/^(?:[0-9a-fA-F:.]{2,45})$/.test(edgeIp)?edgeIp:"unknown";
 const [ipHash,emailHash]=await Promise.all([hash("ip:"+ip),hash("email:"+email)]);
 for(const [token,limit] of [[ipHash,10],[emailHash,4]] as const){
  const limitResponse=await db.rpc("huos_beer_intake_claim_rate_limit",{p_key_hash:token,p_max_hits:limit});
  if(limitResponse.error){console.error("Rate-limit error",limitResponse.error.code);return response(503,{error:"Aanvraag tijdelijk niet beschikbaar."},origin);}
  if(limitResponse.data!==true)return response(429,{error:"Er zijn te veel aanvragen. Probeer het later opnieuw."},origin);
 }
 const insert=await db.from("huos_beer_intake_submissions").insert({company_name,contact_name,email,phone:phone||null,answers,source:"huos_v2_private_pilot",status:"new",privacy_notice_version:"huos-beer-2026-11",data_route,mandate_status:has_mandate?"pending":"not_requested",mandate_consent_at:has_mandate?new Date().toISOString():null,mandate_consent_version:has_mandate?version:null,mandate_authority_asserted:has_mandate}).select("id").single();
 if(insert.error){console.error("Intake insert failed",insert.error.code);return response(503,{error:"De aanvraag kon niet worden opgeslagen. Probeer het opnieuw."},origin)}
 if(v3){
  const sign=await db.rpc("huos_intake_mandate_sign_v3",{p_submission:insert.data.id,p_kvk:v3.kvk,p_function:v3.fn,p_fiscal_month:v3.month,p_period_choice:v3.period,p_suppliers:v3.suppliers});
  if(sign.error){
   console.error("Mandate sign failed",sign.error.code,sign.error.message);
   return response(201,{ok:true,mandate_ok:false,message:"Aanvraag ontvangen door Horeca United. De machtiging kon niet worden vastgelegd; we nemen contact met je op om die af te ronden."},origin);
  }
  return response(201,{ok:true,mandate_ok:true,message:"Aanvraag en machtiging ontvangen door Horeca United."},origin);
 }
 return response(201,{ok:true,message:"Aanvraag ontvangen door Horeca United."},origin);
});

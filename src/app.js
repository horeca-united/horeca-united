
/* =========================================================
   Supabase
   ========================================================= */
const SUPABASE_URL = 'https://yyvzqnjumnpotawnrvfw.supabase.co';
const SUPABASE_KEY = 'sb_publishable_QDvjBPDGIgrQNcSzEw2FZg_Yj6hfIgY';
const sb = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

/* =========================================================
   Auth state
   ========================================================= */
let CURRENT_USER = null;

sb.auth.onAuthStateChange((event, session) => {
  CURRENT_USER = session?.user ?? null;
  AuthUI.updateTopbar();
  if (event === 'SIGNED_IN') {
    AuthUI.closeLogin();
    Dashboard.open();
  } else {
    const dashVisible = document.getElementById('screen-dashboard').classList.contains('active');
    if (dashVisible) {
      Dashboard.renderDocuments();
      Dashboard.renderOverzicht();
      Dashboard.renderProfiel();
      Dashboard.renderBesparingen();
      Dashboard.renderContracten();
    }
  }
});

// Restore session on page load — re-render dashboard if it's already open
sb.auth.getSession().then(({ data: { session } }) => {
  CURRENT_USER = session?.user ?? null;
  AuthUI.updateTopbar();
  const dashVisible = document.getElementById('screen-dashboard').classList.contains('active');
  if (dashVisible) {
    Dashboard.renderDocuments();
    Dashboard.renderOverzicht();
    Dashboard.renderProfiel();
  }
});

/* =========================================================
   AuthUI
   ========================================================= */
const AuthUI = {
  openLogin() {
    this.resetLoginForm();
    document.getElementById('loginModal').classList.add('active');
  },
  closeLogin() {
    document.getElementById('loginModal').classList.remove('active');
  },
  resetLoginForm() {
    document.getElementById('loginForm').style.display = 'block';
    document.getElementById('loginSent').style.display = 'none';
    document.getElementById('loginError').style.display = 'none';
    document.getElementById('loginEmail').value = '';
  },
  async sendMagicLink() {
    const email = document.getElementById('loginEmail').value.trim().toLowerCase();
    const errEl = document.getElementById('loginError');
    if (!email || !email.includes('@')) {
      errEl.textContent = 'Vul een geldig e-mailadres in.';
      errEl.style.display = 'block';
      return;
    }
    errEl.style.display = 'none';
    const btn = document.querySelector('#loginForm .btn-primary');
    btn.disabled = true;
    btn.textContent = 'Versturen…';
    const { error } = await sb.auth.signInWithOtp({
      email,
      options: { emailRedirectTo: 'https://horeca-united.github.io/horeca-united/' }
    });
    btn.disabled = false;
    btn.textContent = 'Stuur inloglink';
    if (error) {
      errEl.textContent = 'Er ging iets mis: ' + error.message;
      errEl.style.display = 'block';
      return;
    }
    document.getElementById('loginSentEmail').textContent = email;
    document.getElementById('loginForm').style.display = 'none';
    document.getElementById('loginSent').style.display = 'block';
  },
  async logout() {
    await sb.auth.signOut();
    CURRENT_USER = null;
    this.updateTopbar();
    const dashVisible = document.getElementById('screen-dashboard').classList.contains('active');
    if (dashVisible) Dashboard.renderDocuments();
  },
  updateTopbar() {
    const el = document.getElementById('topbarAuth');
    const mobileEl = document.getElementById('mobileNavAuth');
    if (CURRENT_USER) {
      const email = CURRENT_USER.email;
      el.innerHTML = `
        <span style="font-size:13px;color:var(--muted)">${email}</span>
        <button class="btn btn-ghost btn-sm" onclick="AuthUI.logout()">Uitloggen</button>`;
      if (mobileEl) mobileEl.innerHTML = `
        <span style="font-size:13px;color:var(--muted);padding:10px">${email}</span>
        <button class="mobile-nav-link" onclick="AuthUI.logout();MobileNav.close()">Uitloggen</button>`;
    } else {
      el.innerHTML = `<button class="btn btn-ghost btn-sm" onclick="AuthUI.openLogin()">Inloggen</button>`;
      if (mobileEl) mobileEl.innerHTML = `<button class="mobile-nav-link" onclick="AuthUI.openLogin();MobileNav.close()">Inloggen</button>`;
    }
  }
};

/* =========================================================
   MobileNav
   ========================================================= */
const MobileNav = {
  open() {
    document.getElementById('mobileNav').classList.add('active');
    document.getElementById('mobileNavOverlay').classList.add('active');
    document.body.style.overflow = 'hidden';
  },
  close() {
    document.getElementById('mobileNav').classList.remove('active');
    document.getElementById('mobileNavOverlay').classList.remove('active');
    document.body.style.overflow = '';
  }
};

// Close login modal on backdrop click
document.getElementById('loginModal').addEventListener('click', e => {
  if (e.target.id === 'loginModal') AuthUI.closeLogin();
});

function parseNum(id) {
  const el = document.getElementById(id);
  if (!el) return null;
  const val = el.value.trim().replace(',', '.');
  const n = parseFloat(val);
  return isNaN(n) ? null : n;
}

async function uploadToSupabase(file, name, email, subgroup) {
  const filePath = `${email}/${Date.now()}_${file.name}`;

  const { error: uploadError } = await sb.storage
    .from('client-uploads')
    .upload(filePath, file, { cacheControl: '3600', upsert: false });
  if (uploadError) throw uploadError;

  const { error: dbError } = await sb.from('uploads').insert({
    email, name: name || null, file_name: file.name, file_path: filePath,
    subgroup: subgroup || null
  });
  if (dbError) throw dbError;

  return filePath;
}

// ========== Excel parsing met SheetJS ==========
async function parseExcel(file) {
  const data = await file.arrayBuffer();
  const workbook = XLSX.read(data, { type: 'array' });

  let allText = '';
  const allCells = [];

  workbook.SheetNames.forEach(sheetName => {
    const sheet = workbook.Sheets[sheetName];
    const rows = XLSX.utils.sheet_to_json(sheet, { header: 1, defval: '' });
    rows.forEach(row => {
      row.forEach(cell => {
        if (cell !== null && cell !== undefined && cell !== '') {
          allText += ' ' + String(cell).toLowerCase();
          allCells.push(String(cell));
        }
      });
    });
  });

  function extractNumber(str) {
    if (!str) return null;
    const cleaned = String(str).replace(/[^0-9.,]/g, '').replace(',', '.');
    const num = parseFloat(cleaned);
    return isNaN(num) ? null : num;
  }

  function findValue(keywords, unitHints = []) {
    for (let i = 0; i < allCells.length; i++) {
      const cellLower = allCells[i].toLowerCase();
      if (keywords.some(k => cellLower.includes(k))) {
        // Alleen vooruit zoeken (niet terug) om verkeerde naburige waarden te vermijden
        for (let j = i + 1; j <= Math.min(allCells.length - 1, i + 3); j++) {
          const num = extractNumber(allCells[j]);
          if (num !== null) return num;
        }
      }
    }
    for (const hint of unitHints) {
      const regex = new RegExp(`([\\d.,]+)\\s*${hint}`, 'i');
      const match = allText.match(regex);
      if (match) return extractNumber(match[1]);
    }
    return null;
  }

  const found = {
    volume_bier:        findValue(['bier', 'pils', 'hectoliter', 'hl bier'], ['liter', 'l', 'hl']),
    volume_elektra_kwh: findValue(['elektra', 'elektriciteit', 'stroom', 'kwh'], ['kwh']),
    volume_gas_m3:      findValue(['gas', 'aardgas', 'm3 gas'], ['m3', 'm³']),
    volume_frisdrank:   findValue(['frisdrank', 'fris', 'soft drink', 'cola'], ['liter', 'l']),
    vuilnis_kosten:     findValue(['vuilnis', 'afval', 'restafval', 'container', 'afvalstoffen'], ['euro', '€']),
    vuilnis_type_container: null,
    verzekering_dekking: null
  };

  const missing = Object.entries(found)
    .filter(([key, val]) => val === null && key !== 'verzekering_dekking' && key !== 'vuilnis_type_container')
    .map(([key]) => key);

  return { found, missing, raw_cells_sample: allCells.slice(0, 50), sheets: workbook.SheetNames };
}

function fillFormFromExtraction(extraction) {
  if (!extraction || !extraction.found) return;
  const f = extraction.found;
  const map = {
    volume_bier: 'u_bier', volume_elektra_kwh: 'u_elektra',
    volume_gas_m3: 'u_gas', volume_frisdrank: 'u_frisdrank',
    vuilnis_kosten: 'u_vuilnis_kosten'
  };
  Object.entries(map).forEach(([key, elId]) => {
    if (f[key] !== null && f[key] !== undefined) {
      const el = document.getElementById(elId);
      if (el) el.value = f[key];
    }
  });
}

async function saveExtractedData(email, name, filePaths, excelExtraction) {
  const today = new Date().toISOString().slice(0, 10);
  let notes = '';
  if (excelExtraction) {
    if (excelExtraction.error) notes = 'Excel fout: ' + excelExtraction.error;
    else if (excelExtraction.missing && excelExtraction.missing.length)
      notes = 'Niet automatisch gevonden: ' + excelExtraction.missing.join(', ');
    else notes = 'Excel volledig uitgelezen';
  } else if (!filePaths.length) {
    notes = 'Geen bestanden geüpload';
  } else {
    notes = 'Geen Excel-bestand of parsing overgeslagen';
  }

  const { data: inserted, error } = await sb.from('extracted_data').insert({
    email,
    name: name || null,
    volume_bier:            parseNum('u_bier'),
    volume_elektra_kwh:     parseNum('u_elektra'),
    volume_gas_m3:          parseNum('u_gas'),
    volume_frisdrank:       parseNum('u_frisdrank'),
    vuilnis_kosten:         parseNum('u_vuilnis_kosten'),
    vuilnis_type_container: (document.getElementById('u_vuilnis_container')?.value.trim() || null),
    verzekering_dekking:    (document.getElementById('u_verzekering')?.value.trim() || null),
    raw_data: { file_paths: filePaths, excel_extraction: excelExtraction || null },
    status: excelExtraction && excelExtraction.missing?.length === 0 ? 'processed' : 'partial',
    submitted_at: today,
    notes
  }).select('id').single();
  if (error) throw error;
  return inserted?.id || null;
}

// ========== Excel → transactions parser ==========
const FALLBACK_CATEGORY_ID = '724b56db-25b6-4c93-8d04-08c83247480f'; // Inkoop (overig)

function findCol(header, names) {
  return header.findIndex(c => names.some(n => String(c).toLowerCase().includes(n)));
}

function matchCategory(text, keywords) {
  if (!text) return FALLBACK_CATEGORY_ID;
  const lower = text.toLowerCase();
  for (const kw of keywords) {
    if (lower.includes(kw.keyword.toLowerCase())) return kw.category_id;
  }
  return FALLBACK_CATEGORY_ID;
}

async function parseAndSaveExcel(file, email, name) {
  const buffer = await file.arrayBuffer();
  const workbook = XLSX.read(buffer, { type: 'array' });
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  const rows = XLSX.utils.sheet_to_json(sheet, { header: 1, defval: '' });

  // Type herkennen
  const headerText = rows.slice(0, 25).flat().join(' ').toLowerCase();
  let type = 'excel';
  if (headerText.includes('artikelnr') || headerText.includes('artikelnummer') || headerText.includes('art.nr')) {
    type = 'sligro';
  } else if (headerText.includes('hanos')) {
    type = 'hanos';
  }

  // Load keywords & supplier once — never repeated per row
  const { data: keywords } = await sb.from('category_keywords')
    .select('category_id, keyword, priority')
    .order('priority', { ascending: false });
  const { data: supplierRow } = await sb.from('suppliers')
    .select('id').ilike('name', type === 'sligro' ? 'Sligro' : type === 'hanos' ? 'Hanos' : 'Overig')
    .maybeSingle();
  const supplierId = supplierRow?.id || null;
  const kws = keywords || [];

  // Header zoeken (eerste 30 rijen)
  let headerIdx = rows.findIndex(r =>
    r.some(c => /artikel|omschrijving|bedrag|product/i.test(String(c)))
  );
  if (headerIdx === -1) headerIdx = 0;

  const header = rows[headerIdx].map(c => String(c).toLowerCase());
  const colArt    = findCol(header, ['artikel', 'art.nr', 'artnr']);
  const colProd   = findCol(header, ['omschrijving', 'product', 'benaming', 'naam']);
  const colBedrag = findCol(header, ['bedrag', 'totaal', 'prijs', '€']);
  const colAantal = findCol(header, ['aantal', 'qty', 'hoeveelheid']);

  const toInsert = [];
  const today = new Date().toISOString().slice(0, 10);

  for (let i = headerIdx + 1; i < rows.length; i++) {
    const row = rows[i];
    const artikel   = colArt >= 0    ? String(row[colArt] || '').trim() : '';
    const product   = colProd >= 0   ? String(row[colProd] || '').trim() : '';
    const bedragStr = colBedrag >= 0 ? String(row[colBedrag] || '0') : '0';
    const bedrag    = parseFloat(bedragStr.replace(/[^0-9,.-]/g, '').replace(',', '.'));
    const aantal    = colAantal >= 0 ? parseFloat(String(row[colAantal] || '').replace(',', '.')) || null : null;

    if (!product && !artikel) continue;
    if (!bedrag || isNaN(bedrag)) continue;

    const categoryId = matchCategory(product || artikel, kws);
    toInsert.push({
      category_id: categoryId,
      supplier_id: supplierId,
      email,
      name: name || null,
      transaction_date: today,
      article_number: artikel || null,
      product_name: product || null,
      amount: bedrag,
      quantity: aantal,
      source: type,
      notes: categoryId === FALLBACK_CATEGORY_ID ? 'Categorie niet automatisch gevonden – later indelen' : null
    });
  }

  if (toInsert.length === 0) throw new Error('Geen bruikbare regels gevonden in dit bestand');

  const { error } = await sb.from('transactions').insert(toInsert);
  if (error) throw error;

  return { aantal: toInsert.length, type };
}

/* =========================================================
   Horeca United demo — data, state, rendering
   ========================================================= */

const SUBGROUPS = [
  {id:"bier", group:"Dranken", name:"Bier"},
  {id:"wijn", group:"Dranken", name:"Wijn"},
  {id:"frisdrank", group:"Dranken", name:"Frisdrank"},
  {id:"foodgroothandel", group:"Food en dagelijkse inkoop", name:"Foodgroothandel"},
  {id:"vis", group:"Food en dagelijkse inkoop", name:"Vis"},
  {id:"vlees", group:"Food en dagelijkse inkoop", name:"Vlees"},
  {id:"gas", group:"Nutsvoorzieningen en vaste lasten", name:"Gas"},
  {id:"energie", group:"Nutsvoorzieningen en vaste lasten", name:"Energie"},
  {id:"afval", group:"Nutsvoorzieningen en vaste lasten", name:"Afval"},
  {id:"internet", group:"Nutsvoorzieningen en vaste lasten", name:"Internet en telefonie"},
  {id:"muzieklicentie", group:"Nutsvoorzieningen en vaste lasten", name:"Muzieklicentie"},
  {id:"verzekeringen", group:"Financiële diensten", name:"Verzekeringen"},
];
const GROUP_ORDER = ["Dranken","Food en dagelijkse inkoop","Nutsvoorzieningen en vaste lasten","Financiële diensten"];
function subgroupName(id){ const s=SUBGROUPS.find(x=>x.id===id); return s?s.name:id; }
function primarySubgroupId(){ return STATE.primary?.subgroupId || STATE.selectedSubgroups[0] || ""; }

const STORAGE_KEY = "huos_demo_state_v1";

function euro(n){ return new Intl.NumberFormat("nl-NL",{style:"currency",currency:"EUR",maximumFractionDigits:0}).format(Math.max(0,Math.round(n))); }

function defaultState(){
  return {
    profile: { businessType:"Restaurant", businessTypeOther:"", city:"" },
    selectedSubgroups: [],
    primary: { subgroupId:"", supplier:"", annualSpend:null, annualSpendUnknown:true, contractStatus:"Onbekend", contractEnd:"Onbekend", willingness:"misschien" },
    method: "upload",
    uploadFileName: "",
    uploadFileNames: [],
    authorization: { signName:"", signRole:"", kvk:"", btw:"", validity:"60 dagen", consent:false },
    account: { companyName:"", contactPerson:"", email:"", phone:"" },
    consents: { privacy:false, processing:false, marketing:false, benchmark:false },
    result: null,
    completed: false
  };
}

let STATE = loadState();

function loadState(){
  try{
    const raw = localStorage.getItem(STORAGE_KEY);
    if(!raw) return defaultState();
    const parsed = JSON.parse(raw);
    return Object.assign(defaultState(), parsed);
  }catch(e){ return defaultState(); }
}
function saveState(){
  try{ localStorage.setItem(STORAGE_KEY, JSON.stringify(STATE)); }catch(e){}
}

/* ---------------- Router ---------------- */
const SCREENS = ["landing","scan","result","dashboard","admin","privacy"];
const Router = {
  go(id){
    SCREENS.forEach(s=>document.getElementById("screen-"+s).classList.remove("active"));
    document.getElementById("screen-"+id).classList.add("active");
    window.scrollTo({top:0, behavior:"smooth"});
  }
};

/* ---------------- Landing: subgroup overview ---------------- */
function renderSubgroupOverview(){
  const box = document.getElementById("subgroupOverview");
  box.innerHTML = GROUP_ORDER.map(g=>{
    const items = SUBGROUPS.filter(s=>s.group===g);
    return `<div class="panel subgroup-group"><h3>${g}</h3><ul>${items.map(i=>`<li>${i.name}</li>`).join("")}</ul></div>`;
  }).join("");
}

/* ---------------- Quick Scan ---------------- */
const QuickScan = {
  step: 1,
  start(){
    this.step = 1;
    this.renderCategoryTiles();
    this.render();
    Router.go("scan");
  },
  render(){
    document.querySelectorAll(".scan-step").forEach(el=>el.style.display="none");
    document.getElementById("scanStep"+this.step).style.display="block";
    document.getElementById("scanStepNr").textContent = this.step;
    document.getElementById("scanProgressBar").style.width = (this.step*20)+"%";
    const titles = ["Over jouw zaak","Waar wil je op besparen?","Jouw kostenposten & contracten","Gegevens aanleveren","Account en privacy"];
    document.getElementById("scanStepTitle").textContent = titles[this.step-1];
    if(this.step===3) this.fillPrimarySelect();
    if(this.step===4) this.applyMethodUI();
  },
  async next(){
    if(this.step===1){
      const city = document.getElementById("f_city").value.trim();
      document.getElementById("err_city").style.display = city ? "none":"block";
      if(!city){ document.getElementById("f_city").focus(); return; }
      STATE.profile = {
        businessType: document.getElementById("f_businessType").value,
        businessTypeOther: document.getElementById("f_businessTypeOther").value.trim(),
        city
      };
    }
    if(this.step===2){
      if(this.selected.size===0){ document.getElementById("err_subgroups").style.display="block"; return; }
      document.getElementById("err_subgroups").style.display="none";
      STATE.selectedSubgroups = [...this.selected];
    }
    if(this.step===3){
      const annualValue = document.getElementById("f_annualSpendUnknown").checked
        ? null
        : (parseFloat(document.getElementById("f_annualSpend").value.replace(",", ".")) || null);
      STATE.primary = {
        subgroupId: document.getElementById("f_primarySubgroup").value,
        supplier: document.getElementById("f_supplier").value.trim(),
        annualSpend: annualValue,
        annualSpendUnknown: document.getElementById("f_annualSpendUnknown").checked,
        contractStatus: document.getElementById("f_contractStatus").value,
        contractEnd: document.getElementById("f_contractEndPreset").value === "Anders"
          ? document.getElementById("f_contractEndOther").value.trim()
          : document.getElementById("f_contractEndPreset").value,
        willingness: this.willingness || "misschien"
      };
    }
    if(this.step===4){
      const m = this.method;
      if(!m){ document.getElementById("err_method").style.display="block"; return; }
      if(m==="upload" && !this._stagedFiles.length){
        document.getElementById("err_method").textContent = "Selecteer minimaal één document voor je gekozen kostenposten.";
        document.getElementById("err_method").style.display="block"; return;
      }
      if(m==="request" && !document.getElementById("f_authConsent").checked){
        document.getElementById("err_method").textContent = "Bevestig de machtiging om verder te gaan.";
        document.getElementById("err_method").style.display="block"; return;
      }
      document.getElementById("err_method").style.display="none";
      STATE.method = m;
      if(m==="request"){
        STATE.authorization = {
          signName: document.getElementById("f_signName").value.trim(),
          signRole: document.getElementById("f_signRole").value.trim(),
          kvk: document.getElementById("f_kvk").value.trim(),
          btw: document.getElementById("f_btw").value.trim(),
          consent: true
        };
      }
    }
    if(this.step<5){ this.step++; this.render(); saveState(); }
  },
  prev(){ if(this.step>1){ this.step--; this.render(); } },
  toggleOtherBusinessType(){
    const field = document.getElementById("scanBusinessTypeOtherField");
    if(field) field.style.display = document.getElementById("f_businessType").value === "Overig" ? "" : "none";
  },

  selected: new Set(),
  renderCategoryTiles(){
    this.selected = new Set(STATE.selectedSubgroups);
    const box = document.getElementById("subgroupChoices");
    box.innerHTML = GROUP_ORDER.map(g=>{
      const items = SUBGROUPS.filter(s=>s.group===g);
      return `<div class="choice-group"><h4>${g}</h4><div class="choices">${items.map(i=>`
        <div class="tile ${this.selected.has(i.id)?'selected':''}" data-id="${i.id}" onclick="QuickScan.toggle('${i.id}')">
          <span class="box"></span>${i.name}
        </div>`).join("")}</div></div>`;
    }).join("");
  },
  toggle(id){
    if(this.selected.has(id)) this.selected.delete(id); else this.selected.add(id);
    const tile = document.querySelector(`#subgroupChoices .tile[data-id="${id}"]`);
    tile.classList.toggle("selected");
  },
  toggleAll(){
    const all = SUBGROUPS.map(s=>s.id);
    const selectingAll = this.selected.size !== all.length;
    this.selected = new Set(selectingAll ? all : []);
    document.querySelectorAll("#subgroupChoices .tile").forEach(tile=>{
      tile.classList.toggle("selected", selectingAll);
    });
  },
  toggleAnnualSpendUnknown(){
    const unknown = document.getElementById("f_annualSpendUnknown").checked;
    const input = document.getElementById("f_annualSpend");
    input.disabled = unknown;
    if(unknown) input.value = "";
  },
  toggleContractEndOther(){
    const isOther = document.getElementById("f_contractEndPreset").value === "Anders";
    document.getElementById("f_contractEndOther").style.display = isOther ? "" : "none";
  },
  fillPrimarySelect(){
    const sel = document.getElementById("f_primarySubgroup");
    const current = STATE.primary.subgroupId;
    sel.innerHTML = `<option value="">— Geen prioriteit —</option>` +
      [...this.selected].map(id=>`<option value="${id}" ${id===current?'selected':''}>${subgroupName(id)}</option>`).join("");
    const summary = document.getElementById("selectedSubgroupSummary");
    if(summary) summary.innerHTML = [...this.selected].map(id=>`<span class="selected-subgroup-pill">${subgroupName(id)}</span>`).join("");
    document.getElementById("f_supplier").value = STATE.primary.supplier||"";
    const spendUnknown = STATE.primary.annualSpendUnknown || !STATE.primary.annualSpend;
    document.getElementById("f_annualSpendUnknown").checked = spendUnknown;
    document.getElementById("f_annualSpend").value = spendUnknown ? "" : STATE.primary.annualSpend;
    document.getElementById("f_annualSpend").disabled = spendUnknown;
    document.getElementById("f_contractStatus").value = STATE.primary.contractStatus||"Onbekend";
    const end = STATE.primary.contractEnd || "Onbekend";
    const endPreset = ["Onbekend","Maandelijks opzegbaar","Binnen 3 maanden","Binnen 6 maanden","Binnen 12 maanden","Langer dan 12 maanden"].includes(end) ? end : "Anders";
    document.getElementById("f_contractEndPreset").value = endPreset;
    document.getElementById("f_contractEndOther").value = endPreset === "Anders" ? end : "";
    this.toggleContractEndOther();
    this.willingness = STATE.primary.willingness || "misschien";
    const updateWillingnessHint = (val) => {
      const hint = document.getElementById("willingnessHintMisschien");
      if(hint) hint.style.display = val==="misschien" ? "block" : "none";
    };
    updateWillingnessHint(this.willingness);
    document.querySelectorAll("#switchWillingness .tile").forEach(t=>{
      t.classList.toggle("selected", t.dataset.val===this.willingness);
      t.onclick = ()=>{
        this.willingness = t.dataset.val;
        document.querySelectorAll("#switchWillingness .tile").forEach(x=>x.classList.remove("selected"));
        t.classList.add("selected");
        updateWillingnessHint(t.dataset.val);
      };
    });
  },
  method: null,
  selectMethod(m){
    this.method = m;
    document.querySelectorAll(".method-card").forEach(c=>c.classList.toggle("selected", c.dataset.method===m));
    this.applyMethodUI();
  },
  applyMethodUI(){
    ["upload","request","later"].forEach(m=>{
      document.getElementById("method"+m.charAt(0).toUpperCase()+m.slice(1)).style.display = (this.method===m)?"block":"none";
    });
    if(this.method){
      document.querySelectorAll(".method-card").forEach(c=>c.classList.toggle("selected", c.dataset.method===this.method));
    }
    if(this.method==="upload"){
      const introEl = document.getElementById("uploadSubgroupIntro");
      if(introEl && this.selected.size>0){
        const names = [...this.selected].map(id=>subgroupName(id)).join(", ");
        introEl.textContent = `Fijn dat je het zelf wilt uploaden! Je hebt aangegeven te willen besparen op: ${names}. Upload hieronder de bijbehorende jaarafrekening of termijnfactuur. Heb je niet alles bij de hand? Geen zorgen — je kunt dit later toevoegen in je dashboard.`;
        introEl.style.display = "block";
      }
    }
  },
  _excelExtraction: null,
  _stagedFiles: [],
  renderQuickUploadStaging(){
    const area = document.getElementById("quickUploadStagingArea");
    const body = document.getElementById("quickUploadStagingBody");
    if(!area || !body) return;
    const selected = [...this.selected];
    const options = selected.map(id=>`<option value="${id}">${subgroupName(id)}</option>`).join("");
    body.innerHTML = this._stagedFiles.map((file, i)=>`
      <tr>
        <td style="font-size:13px">${file.name}</td>
        <td><select id="quickUploadSg_${i}" class="quick-upload-select">${options}</select></td>
        <td><input type="text" id="quickUploadSupplier_${i}" class="quick-upload-input" placeholder="Bijv. leverancier"></td>
      </tr>`).join("");
    this._stagedFiles.forEach((_, i)=>{
      document.getElementById(`quickUploadSg_${i}`).value = primarySubgroupId() || selected[0] || "";
      document.getElementById(`quickUploadSupplier_${i}`).value = STATE.primary.supplier || "";
    });
    area.style.display = this._stagedFiles.length ? "block" : "none";
  },
  async handleFiles(fileList){
    const files = Array.from(fileList || []).filter(f => f && f.size > 0);
    if(!files.length) return;
    this._stagedFiles = [...this._stagedFiles, ...files];
    const box = document.getElementById("uploadBox");
    box.classList.add("filled");
    document.getElementById("uploadBoxText").innerHTML = `Sleep bestanden hierheen of klik om toe te voegen<br><span class="hint">Factuur, contract, jaarafrekening of offerte (Excel, PDF, Word)</span>`;
    const listEl = document.getElementById("uploadFileList");
    listEl.innerHTML = this._stagedFiles.map(file=>`<div><span class="file-name">${file.name}</span> <span class="hint">(${(file.size/1024).toFixed(1)} KB)</span></div>`).join("");
    this.renderQuickUploadStaging();
  },
  async uploadStagedFiles(){
    const email = (document.getElementById("f_email").value.trim() || "onbekend@demo.nl").toLowerCase();
    const name = document.getElementById("f_companyName").value.trim() || "Onbekend bedrijf";
    const uploadedPaths = [];
    const statusEl = document.getElementById("err_method");
    this._excelExtraction = null;
    for(let i=0; i<this._stagedFiles.length; i++){
      const file = this._stagedFiles[i];
      const subgroup = document.getElementById(`quickUploadSg_${i}`)?.value || primarySubgroupId();
      try{
        const path = await uploadToSupabase(file, name, email, subgroup);
        uploadedPaths.push(path);
        STATE.uploadFileNames = [...new Set([...(STATE.uploadFileNames || []), file.name])];
        STATE.uploadDetails = [...(STATE.uploadDetails || []), { fileName:file.name, subgroup, supplier:document.getElementById(`quickUploadSupplier_${i}`)?.value.trim() || "" }];
      }catch(err){
        statusEl.textContent = `Upload van ${file.name} mislukt: ${err.message}`;
        statusEl.style.display = "block";
        return false;
      }
    }
    if(uploadedPaths.length){
      const excelFile = this._stagedFiles.find(f => /\.xlsx?$/i.test(f.name));
      if(excelFile){
        try{
          this._excelExtraction = await parseExcel(excelFile);
          fillFormFromExtraction(this._excelExtraction);
          await saveExtractedData(email, name, uploadedPaths, this._excelExtraction);
        }catch(err){ console.warn("Excel kon niet worden verwerkt:", err); }
      }
      // Finish extraction before showing the dashboard so the year check can run.
      const pdfFiles = this._stagedFiles.filter(f => /\.pdf$/i.test(f.name));
      for(let i = 0; i < pdfFiles.length; i++){
        const pdfPath = uploadedPaths[this._stagedFiles.indexOf(pdfFiles[i])];
        if(pdfPath){
          const { error } = await sb.functions.invoke('extract-pdf', { body: { file_path: pdfPath, email, name } });
          if(error) console.warn('Documentverwerking vraagt controle:', error);
        }
      }
    }
    this._stagedFiles = [];
    document.getElementById("uploadFileList").innerHTML = `<span class="hint" style="color:var(--positive-ink)">Documenten opgeslagen.</span>`;
    document.getElementById("quickUploadStagingArea").style.display = "none";
    return true;
  },
  async complete(){
    const company = document.getElementById("f_companyName").value.trim();
    const email = document.getElementById("f_email").value.trim();
    if(!company || !email){ document.getElementById("err_account").style.display="block"; return; }
    if(!document.getElementById("f_consentPrivacy").checked){
      document.getElementById("err_account").textContent = "Bevestig de privacyverklaring en verwerkingstoestemming om verder te gaan.";
      document.getElementById("err_account").style.display="block"; return;
    }
    document.getElementById("err_account").style.display="none";
    STATE.account = {
      companyName: company,
      contactPerson: document.getElementById("f_contactPerson").value.trim(),
      email, phone: document.getElementById("f_phone").value.trim()
    };
    if(STATE.method === "upload" && this._stagedFiles.length){
      const uploaded = await this.uploadStagedFiles();
      if(!uploaded){
        document.getElementById("err_account").textContent = "De documenten konden niet worden opgeslagen. Probeer het opnieuw.";
        document.getElementById("err_account").style.display = "block";
        return;
      }
    }
    STATE.consents = {
      privacy: true, processing: true, marketing: true,
      benchmark: document.getElementById("f_consentBenchmark").checked
    };
    STATE.completed = true;
    Engine.computeResult();
    saveState();
    Engine.renderResult();
    // Save authorization to Supabase if method is 'request'
    if (STATE.method === 'request' && STATE.authorization.consent) {
      QuickScan._saveAuthorization(email, company).catch(()=>{});
    }
    Router.go("result");
  },

  async _saveAuthorization(email, company) {
    const auth = STATE.authorization;
    const sourceId = primarySubgroupId();
    const now = new Date();
    const seq = String(Math.floor(Math.random()*99999)).padStart(5,'0');
    const authId = `AUTH-${sourceId.toUpperCase()}-${now.getFullYear()}${String(now.getMonth()+1).padStart(2,'0')}${String(now.getDate()).padStart(2,'0')}-${seq}`;
    const validityDays = parseInt(STATE.authorization.validity) || 60;

    const { data: source } = await sb.from('data_sources').select('permissions,purpose').eq('id', sourceId).maybeSingle();

    await sb.from('authorizations').insert({
      id: authId,
      user_id: CURRENT_USER?.id || null,
      email,
      company_name: company,
      kvk_number: auth.kvk || null,
      signatory_name: auth.signName || null,
      signatory_role: auth.signRole || null,
      data_source_id: sourceId,
      permissions: source?.permissions || [],
      purpose: source?.purpose || null,
      status: 'active',
      document_version: 'v1.1',
      validity_days: validityDays
    });

    await sb.from('authorization_events').insert({
      authorization_id: authId,
      email,
      event_type: 'GRANTED',
      actor: 'user',
      new_values: { company_name: company, signatory_name: auth.signName, data_source_id: sourceId },
      note: `Machtiging verleend via Quick Scan voor ${sourceId}`
    });
  }
};

/* ---------------- Calculation engine ---------------- */
const Engine = {
  computeResult(){
    const spend = STATE.primary.annualSpend || 6000;
    const n = STATE.selectedSubgroups.length;
    let low = spend*0.04 + n*180;
    let high = spend*0.10 + n*420;
    if(STATE.primary.contractStatus === "Onbekend" || STATE.primary.contractStatus === "Geen vast contract"){
      high *= 1.15;
    }
    STATE.result = {
      low: Math.round(low), high: Math.round(high),
      profilePct: Engine.profileCompletion()
    };
  },
  profileCompletion(){
    let score = 0;
    const total = 6;
    if(STATE.profile.city) score++;
    if(STATE.selectedSubgroups.length>0) score++;
    if(STATE.primary.supplier) score++;
    if(STATE.method) score++;
    if(STATE.account.companyName) score++;
    if(STATE.selectedSubgroups.length>=3) score++;
    return Math.round((score/total)*100);
  },
  statusLabel(){
    if(STATE.method==="upload") return "Document ontvangen";
    if(STATE.method==="request") return "Gegevensopvraag klaar";
    return "Later aanleveren";
  },
  recommendedNext(){
    return STATE.selectedSubgroups.filter(id=>id!==primarySubgroupId()).slice(0,3).map(subgroupName);
  },
  renderResult(){
    if(!STATE.result) this.computeResult();
    document.getElementById("resultRange").textContent = `${euro(STATE.result.low)} – ${euro(STATE.result.high)}`;
    document.getElementById("resultPrimary").textContent = subgroupName(primarySubgroupId()) || "Alle gekozen subgroepen";
    document.getElementById("resultStatus").textContent = this.statusLabel();
    document.getElementById("resultCount").textContent = STATE.selectedSubgroups.length;
    document.getElementById("resultProfilePct").textContent = STATE.result.profilePct + "%";
    const recs = this.recommendedNext();
    document.getElementById("resultRecommendations").textContent = recs.length
      ? "Op basis van je bedrijfsprofiel zien we mogelijke kansen bij " + recs.join(", ") + "."
      : "Open in je dashboard extra subgroepen om meer aanbevelingen te ontvangen.";
    document.getElementById("resultSummary").innerHTML = `Je Quick Scan voor <strong>${STATE.selectedSubgroups.length} gekozen kostenposten</strong> staat klaar. Horeca United gebruikt deze uitkomst om de meest kansrijke besparingskansen te adviseren.`;
  }
};

/* ---------------- Subgroup status simulation (deterministic per company) ---------------- */
const STATUS_LIST = ["Niet van toepassing","Nog niet ingevuld","Basisgegevens ingevuld","Documenten ontbreken","Klaar voor analyse","Analyse in behandeling","Besparingskans gevonden","Collectief voorstel beschikbaar","Voorstel geaccepteerd","Overstap in uitvoering","Besparing gerealiseerd","Huidige afspraak is marktconform"];

function hashStr(s){ let h=0; for(let i=0;i<s.length;i++){ h = (h*31 + s.charCodeAt(i)) >>> 0; } return h; }

// Maps Supabase category names to SUBGROUPS ids
const CATEGORY_TO_SUBGROUP = {
  "Elektra": "energie", "Gas": "gas", "Verzekeringen": "verzekeringen",
  "Afval & milieu": "afval", "Telecom": "internet", "Muzieklicentie": "muzieklicentie",
  "Muziekrechten": "muzieklicentie",
  "Bier": "bier", "Wijn": "wijn", "Fris": "frisdrank", "Vlees": "vlees",
  "Inkoop (overig)": "foodgroothandel"
};

function buildSubgroupRows(uploadedSubgroups = new Set(), spendBySubgroup = {}, yearBySubgroup = {}, detailBySubgroup = {}){
  const subgroupIds = [...new Set([...STATE.selectedSubgroups, ...uploadedSubgroups, ...Object.keys(spendBySubgroup)])];
  return subgroupIds.map(id=>{
    const isPrimary = id === primarySubgroupId();
    let status, badge;
    if(isPrimary){
      status = Engine.statusLabel(); badge="b-green";
    } else if(uploadedSubgroups.has(id)){
      status = "Klaar voor analyse"; badge="b-yellow";
    } else {
      status = "Nog niet ingevuld"; badge="b-grey";
    }
    const kans = isPrimary ? "Hoog" : "Onbekend";
    const realSpend = spendBySubgroup[id];
    const cost = CURRENT_USER ? (realSpend ?? null)
      : (isPrimary ? (STATE.primary.annualSpend || realSpend || 0) : (realSpend || 0));
    const suppliers = detailBySubgroup[id]?.suppliers || [];
    const supplier = suppliers.length > 1 ? `${suppliers.length} leveranciers`
      : (suppliers[0]?.name || detailBySubgroup[id]?.supplier || (isPrimary ? (STATE.primary.supplier || "Onbekende leverancier") : "—"));
    const contractEnd = isPrimary ? (STATE.primary.contractEnd || "Onbekend") : "Onbekend";
    const missing = isPrimary && STATE.method==="later" ? "Factuur of contract" : "—";
    return {id, name: subgroupName(id), status, badge, kans, cost, sourceYear:yearBySubgroup[id] || null,
      nextYearAmount:detailBySubgroup[id]?.nextYearAmount || null,
      contractYears:detailBySubgroup[id]?.contractYears || null, supplier, suppliers, contractEnd, missing, isPrimary};
  });
}

// Use the document's coverage period, never its upload date, for book year 2025.
const DASHBOARD_BOOK_YEAR = 2025;
function bookYearTransaction(row, year = DASHBOARD_BOOK_YEAR){
  const start = row.period_start;
  const end = row.period_end;
  const firstDay = `${year}-01-01`;
  const lastDay = `${year}-12-31`;
  if(start || end){
    if(!start || !end) return { included:false, reason:'periode niet volledig bekend' };
    // An annual statement ending January 1 uses an exclusive end date.
    const effectiveEnd = end === `${year + 1}-01-01` ? lastDay : end;
    return start >= firstDay && effectiveEnd <= lastDay && start <= effectiveEnd
      ? { included:true }
      : { included:false, reason:'valt buiten boekjaar 2025' };
  }
  // Itemized purchases can use their transaction date; policy dates cannot.
  if(!row.is_contract && row.transaction_date?.slice(0,4) === String(year)){
    return { included:true };
  }
  return { included:false, reason:'boekjaar niet bevestigd' };
}

function dashboardCategory(row){
  return row.categories?.name === 'Muziekrechten' ? 'Muzieklicentie' : (row.categories?.name || 'Overig');
}
function policyYear(row){
  if(dashboardCategory(row) !== 'Verzekeringen' || !row.is_contract || !(Number(row.monthly_amount) > 0)) return null;
  const year = (row.transaction_date || row.renewal_date || '').slice(0, 4);
  return year === '2025' || year === '2026' ? Number(year) : null;
}
function firstTelecomYear(row){
  const summary = row.raw_data?.contract_summary;
  if(dashboardCategory(row) !== 'Telecom' || !row.is_contract || summary?.verified_from_source !== true || !(Number(summary.annual_amount) > 0)) return null;
  const year = (row.transaction_date || '').slice(0, 4);
  return year === '2025' || year === '2026' ? Number(year) : null;
}
function telecomContractYears(row){
  if(!firstTelecomYear(row)) return null;
  // The order date is explicitly an estimate until the activation date is known.
  const start = row.raw_data?.contract_summary?.period_start || row.period_start;
  if(!/^\d{4}-\d{2}-\d{2}$/.test(start || '')) return null;
  const date = new Date(`${start}T00:00:00Z`);
  if(Number.isNaN(date.getTime()) || date.toISOString().slice(0,10) !== start) return null;
  const boundary = n => new Date(Date.UTC(date.getUTCFullYear() + n, date.getUTCMonth(), date.getUTCDate()));
  const dayBefore = d => new Date(d.getTime() - 86400000).toISOString().slice(0,10);
  const secondStart = boundary(1);
  return { firstStart:start, firstEnd:dayBefore(secondStart),
    secondStart:secondStart.toISOString().slice(0,10), secondEnd:dayBefore(boundary(2)),
    estimated:row.raw_data?.estimated_from === 'order_date' || row.raw_data?.date_confidence === 'estimated' };
}
function dashboardAmount(row){
  const summary = row.raw_data?.contract_summary;
  if(firstTelecomYear(row)) return Number(summary.annual_amount); // Only months 1–12; never add months 13–24.
  if(policyYear(row) && !row.period_end) return Math.round(Number(row.monthly_amount) * 1200) / 100;
  return Number(row.amount);
}

// 2025 sources win per subgroup. Verified 2026 music, policy and first-contract-
// year telecom amounts serve as temporary references only when 2025 is absent.
function dashboardCostSelection(rows){
  const selected = new Map();
  const source2025 = row => bookYearTransaction(row).included || policyYear(row) === 2025 || firstTelecomYear(row) === 2025;
  const categoriesWith2025 = new Set(rows.filter(source2025).map(dashboardCategory));
  rows.forEach(row => {
    const category = dashboardCategory(row);
    if(source2025(row)) selected.set(row.id, 2025);
    else if(categoriesWith2025.has(category)) return;
    else if(category === 'Muzieklicentie' && row.period_start && row.period_end && bookYearTransaction(row, 2026).included){
      selected.set(row.id, 2026);
    } else if(policyYear(row) === 2026 || firstTelecomYear(row) === 2026){
      selected.set(row.id, 2026);
    }
  });
  return { selected, categoriesWith2025 };
}

// Annualise only distinct, documented 2025 waste billing periods. This is an
// indicative run-rate, never a claim about actual full-year expenditure.
function wasteAnnualEstimate(rows){
  const periods = new Map();
  rows.filter(t => dashboardCategory(t) === 'Afval & milieu' && bookYearTransaction(t).included).forEach(t => {
    const start = t.period_start, end = t.period_end;
    if(!start || !end) return;
    const a = new Date(start+'T00:00:00Z'), b = new Date(end+'T00:00:00Z');
    if(!Number.isFinite(+a) || !Number.isFinite(+b) || b < a) return;
    const endExclusive = new Date(b);
    // Some annual statements use the first day of the next period as end.
    const isExclusive = end.slice(5) === '01-01' && end > start;
    if(!isExclusive) endExclusive.setUTCDate(endExclusive.getUTCDate()+1);
    const days = Math.round((endExclusive-a)/86400000);
    const amount = dashboardAmount(t);
    if(days < 1 || !Number.isFinite(amount)) return;
    const key = start+'|'+end;
    if(!periods.has(key)) periods.set(key,{days,amount});
    else periods.get(key).amount += amount;
  });
  const values = [...periods.values()];
  if(!values.length) return null;
  const coveredDays = values.reduce((sum,p)=>sum+p.days,0);
  const actual = values.reduce((sum,p)=>sum+p.amount,0);
  return {actual, coveredDays, estimate:Math.round(actual*365/coveredDays*100)/100, periods:values.length};
}

/* ---------------- Klantdashboard ---------------- */
const Dashboard = {
  async open(){
    if(!STATE.completed){
      STATE.account.companyName = STATE.account.companyName || "Voorbeeld Horecazaak";
      Engine.computeResult();
      STATE.completed = true;
      saveState();
    }
    // Pre-fill upload email if logged in
    if (CURRENT_USER) {
      const emailEl = document.getElementById('docUploadEmail');
      if (emailEl && !emailEl.value) emailEl.value = CURRENT_USER.email;
      // Load profile from Supabase before render so company name is correct immediately
      const { data } = await sb.from('profiles')
        .select('company_name,contact_person,phone,business_type,city')
        .eq('email', CURRENT_USER.email).maybeSingle();
      if (data) {
        if (data.company_name)   STATE.account.companyName   = data.company_name;
        STATE.account.contactPerson = data.contact_person || '';
        if (data.phone)          STATE.account.phone         = data.phone;
        if (data.business_type)  STATE.profile.businessType  = data.business_type;
        if (data.city)           STATE.profile.city          = data.city;
      }
      const nameEl = document.getElementById('docUploadName');
      if (nameEl) nameEl.value = STATE.account.contactPerson;
    }
    this.render();
    Router.go("dashboard");
  },
  async render(){
    let uploadedSubgroups = new Set();
    let spendBySubgroup = {};
    let yearBySubgroup = {};
    let detailBySubgroup = {};
    let wineSourceRows = [];
    let txRows = [];
    if(CURRENT_USER){
      const [{ data: uploads }, { data: loadedTxRows }] = await Promise.all([
        sb.from('uploads').select('subgroup').eq('email', CURRENT_USER.email),
        sb.from('transactions')
          .select('id, amount, monthly_amount, renewal_date, raw_data, transaction_date, period_start, period_end, is_contract, categories(name), suppliers(name)')
          .eq('email', CURRENT_USER.email)
      ]);
      txRows = loadedTxRows || [];
      if(uploads) uploads.forEach(u => { if(u.subgroup) uploadedSubgroups.add(u.subgroup); });
      const { selected } = dashboardCostSelection(txRows || []);
      wineSourceRows = (txRows || []).filter(t => CATEGORY_TO_SUBGROUP[t.categories?.name] === 'wijn' && selected.has(t.id) && Array.isArray(t.raw_data?.wine_article_statistics?.lines));
      if(txRows) txRows.filter(t => selected.has(t.id)).forEach(t => {
        const catName = t.categories?.name;
        const sgId = CATEGORY_TO_SUBGROUP[catName];
        const amount = dashboardAmount(t);
        if(sgId && Number.isFinite(amount)) {
          spendBySubgroup[sgId] = (spendBySubgroup[sgId] || 0) + amount;
          yearBySubgroup[sgId] = selected.get(t.id);
          const details = detailBySubgroup[sgId] || {};
          details.supplier = t.suppliers?.name || (sgId === 'muzieklicentie' ? 'Buma/Sena' : details.supplier);
          if(sgId === 'wijn'){
            const supplierName = t.suppliers?.name || t.raw_data?.supplier || 'Leverancier onbekend';
            const suppliers = details.suppliers || [];
            const existing = suppliers.find(s => s.name === supplierName);
            if(existing) existing.amount += amount;
            else suppliers.push({name:supplierName, amount});
            details.suppliers = suppliers;
          }
          const secondYearMonthly = Number(t.raw_data?.contract_summary?.standard_monthly_total);
          if(sgId === 'internet' && firstTelecomYear(t) && secondYearMonthly > 0){
            details.nextYearAmount = Math.round(secondYearMonthly * 1200) / 100;
            details.contractYears = telecomContractYears(t);
          }
          detailBySubgroup[sgId] = details;
        }
      });
    }
    const wasteEstimate = CURRENT_USER ? wasteAnnualEstimate(txRows || []) : null;
    if(wasteEstimate){
      spendBySubgroup.afval = wasteEstimate.estimate;
      detailBySubgroup.afval = {...(detailBySubgroup.afval || {}), wasteEstimate};
    }
    const rows = buildSubgroupRows(uploadedSubgroups, spendBySubgroup, yearBySubgroup, detailBySubgroup);
    document.getElementById("dashCompanyName").textContent =
      CURRENT_USER ? (STATE.account.companyName || CURRENT_USER.email) : (STATE.account.companyName || "Voorbeeld Horecazaak");
    const pct = CURRENT_USER ? null : (STATE.result ? STATE.result.profilePct : Engine.profileCompletion());
    const progressLabel = pct == null ? '—' : `${pct}%`;
    document.getElementById("dashProfilePct2").textContent = pct == null ? 'Documenten laden…' : `${pct}% voltooid`;
    document.getElementById("dashProfileBar").style.width = pct == null ? '0%' : `${pct}%`;
    for (const id of ['dashProfilePct', 'dashProfilePctSummary', 'dashProfilePctDemo']) {
      const el = document.getElementById(id);
      if (el) el.textContent = progressLabel;
    }
    // demo summary shown when no real transactions
    document.getElementById("dashRealSummary").style.display = "none";
    document.getElementById("dashDemoSummary").style.display = "block";
    const potDemo = document.getElementById("dashPotentialDemo");
    const pctDemo = document.getElementById("dashProfilePctDemo");
    if (potDemo) potDemo.textContent = STATE.result ? `${euro(STATE.result.low)} – ${euro(STATE.result.high)}` : "—";
    if (pctDemo) pctDemo.textContent = progressLabel;

    // Demo banner
    document.getElementById("dashDemoBanner").style.display = CURRENT_USER ? "none" : "block";

    // Demo values for stats that are otherwise 0/blank when not logged in
    if (!CURRENT_USER) {
      const realizedEl = document.getElementById("dashRealized");
      if (realizedEl) realizedEl.textContent = "€ 1.240";
      const docsEl = document.getElementById("dashDocsCount");
      if (docsEl) docsEl.textContent = "3";
      // Keep top-row "Profiel voltooid" in sync with the subgroep block
      const pctEl = document.getElementById("dashProfilePct");
      if (pctEl) pctEl.textContent = pct + "%";
    }

    const shortBody = rows.slice(0,5).map(r=>`
      <tr><td><strong>${r.name}</strong></td><td><span class="badge ${r.badge}">${r.status}</span></td>
      <td>${r.kans}</td><td><button class="btn btn-ghost btn-sm" onclick="Dashboard.showTab('subgroepen')">Bekijk</button></td></tr>`).join("");
    document.getElementById("dashSubgroupTableShort").innerHTML = shortBody || `<tr><td colspan="4" class="empty-state">Nog geen subgroepen geselecteerd.</td></tr>`;

    const nlDate = date => date ? date.split('-').reverse().join('-') : 'onbekend';
    const safe = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const fullBody = rows.map(r=>`
      <tr><td><strong>${r.name}</strong></td><td>${safe(r.supplier)}${r.id === 'afval' && r.cost != null ? `<br><details style="margin-top:7px"><summary class="btn btn-ghost btn-sm" style="display:inline-block;cursor:pointer">Prijsontwikkeling ↗</summary><div style="margin-top:12px;max-width:330px;min-width:220px;font-size:12px;line-height:1.45"><div style="display:flex;justify-content:space-between;gap:8px;margin-bottom:5px"><strong>Q4 2025</strong><span>€ 428,16</span></div><div role="img" aria-label="Q4 2025: 428 euro en 16 cent exclusief btw" style="height:13px;background:var(--border,#e7e9e7);border-radius:8px;overflow:hidden"><div style="width:87.43%;height:100%;background:#659c87;border-radius:8px"></div></div><div style="display:flex;justify-content:space-between;gap:8px;margin:12px 0 5px"><strong>Q2 2026</strong><span>€ 489,75</span></div><div role="img" aria-label="Q2 2026: 489 euro en 75 cent exclusief btw, waarvan 61 euro en 59 cent meer dan in Q4 2025" style="display:flex;height:13px;background:var(--border,#e7e9e7);border-radius:8px;overflow:hidden"><div style="width:87.43%;height:100%;background:#659c87"></div><div style="width:12.57%;height:100%;background:#d79543"></div></div><div style="display:flex;justify-content:space-between;gap:8px;align-items:center;margin-top:9px"><span style="color:var(--muted)">Extra kosten <span style="display:inline-block;width:8px;height:8px;border-radius:2px;background:#d79543"></span></span><strong style="color:#a96618">+ € 61,59 · 14,39%</strong></div><p style="margin:9px 0 0;color:var(--muted)">Per kwartaal · excl. btw. 2026 is een benchmark en telt niet mee in het kostentotaal van 2025.</p><details style="margin-top:7px"><summary style="cursor:pointer;color:var(--muted)">Opbouw prijsstijging</summary><p style="margin:6px 0 0;color:var(--muted)">Abonnement per maand: € 142,72 → € 152,57 (+6,90%). In Q2 2026 is daarnaast € 32,04 CO₂- en brandstofheffing berekend. Beide facturen betreffen een 1.100L-restafvalcontainer met wekelijkse lediging.</p></details></div></details>` : ''}</td><td>${r.cost == null ? '—' : new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR'}).format(r.cost)}${r.id === 'afval' && wasteEstimate ? '<br><small style="color:var(--muted)">Indicatie per jaar · '+new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR'}).format(wasteEstimate.actual)+' werkelijk over '+wasteEstimate.coveredDays+' dagen</small>' : ''}${r.id === 'wijn' ? `<br><button class="btn btn-ghost btn-sm" style="margin-top:7px" onclick="Dashboard.openWineDetail()">Bekijk inkoop per leverancier →</button>` : ''}</td><td>${r.sourceYear || '—'}${r.id === 'afval' && r.sourceYear === 2025 ? ' · Q4' : ''}${r.sourceYear === 2026 ? ' · tijdelijk' : ''}</td>
      <td><span class="badge ${r.badge}">${r.status}</span></td><td>${r.kans}</td><td>${r.contractEnd}</td>
      <td><button class="btn btn-ghost btn-sm" onclick="alert('In deze demo start dit de analyse-flow voor ${r.name}.')">${r.status==="Nog niet ingevuld"?"Start analyse":"Bekijk"}</button></td></tr>`).join("");
    document.getElementById("dashSubgroupTableFull").innerHTML = fullBody || `<tr><td colspan="8" class="empty-state">Nog geen subgroepen geselecteerd.</td></tr>`;

    // De wijnartikelregels blijven gekoppeld aan hun brontransactie; totalen niet opnieuw optellen.
    const wineArticleGroups = new Map();
    wineSourceRows.forEach(t => {
      const stats = t.raw_data.wine_article_statistics;
      const supplier = t.suppliers?.name || t.raw_data?.supplier || 'Leverancier onbekend';
      stats.lines.forEach(line => {
        const key = supplier + '|' + line.sku;
        const item = wineArticleGroups.get(key) || {...line, supplier, quantity:0, net:0, source:stats.source, period:stats.period_start+' t/m '+stats.period_end, priceDate:stats.current_price_as_of};
        item.quantity += Number(line.quantity)||0;
        item.net += Number(line.net)||0;
        wineArticleGroups.set(key,item);
      });
    });
    const wineArticles = [...wineArticleGroups.values()];
    const wineProductBox = document.getElementById('wineProductAnalysis');
    if (wineArticles.length) {
      const money = n => new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR'}).format(n);
      const itemRow = item => '<tr><td>'+safe(item.name)+'<br><small>'+safe(item.supplier)+' · '+safe(item.sku)+'</small></td><td>'+item.quantity+'</td><td>'+money(item.net)+'</td></tr>';
      const ranked = wineArticles.filter(item => item.quantity > 0);
      const top = [...ranked].sort((a,b)=>b.quantity-a.quantity).slice(0,3);
      const bottom = ranked.filter(item => item.net > 0 && item.quantity >= 12).sort((a,b)=>a.quantity-b.quantity || a.net-b.net || String(a.sku).localeCompare(String(b.sku))).slice(0,3);
      const table = items => '<div class="table-wrap"><table class="table"><thead><tr><th>Wijn</th><th>Flessen</th><th>Netto inkoop</th></tr></thead><tbody>'+items.map(itemRow).join('')+'</tbody></table></div>';
      const articleTotal = wineArticles.reduce((sum,item)=>sum+item.net,0);
      const bottles = wineArticles.reduce((sum,item)=>sum+item.quantity,0);
      const sources = [...new Set(wineArticles.map(item=>item.source))];
      wineProductBox.classList.remove('note');
      wineProductBox.innerHTML =
        '<p><strong>'+wineArticles.length+' artikelregels · '+bottles+' stuks · '+money(articleTotal)+'</strong><br><small>Bron: '+sources.map(safe).join(', ')+' · inkoopperiode 2025. Het artikeloverzicht is een uitsplitsing van het bestaande leverancierstotaal, geen extra inkoop.</small></p>'+
        '<h4>Top 3 ingekochte wijnen</h4>'+table(top)+
        '<h4>Bottom 3 – laagste afname met volume</h4><p style="font-size:12px;color:var(--muted)"><strong>Voorlopige berekening:</strong> alleen wijnartikelregels met minimaal 12 ingekochte flessen en een netto inkoopbedrag boven € 0 in de bronperiode. Vervolgens sorteren we op het laagste aantal flessen; bij gelijke aantallen op het laagste netto inkoopbedrag. De grens van 12 flessen is een praktische aanname om losse proefbestellingen grotendeels buiten beeld te houden. Betaalde samples van 12 flessen of meer kunnen nog voorkomen. Lage inkoop is niet hetzelfde als lage verkoop; kaartstatus en kassaverkoop zijn niet geverifieerd.</p>'+table(bottom)+
        '<h4>Alle wijnen van Bart en andere verwerkte leveranciers</h4>'+
        '<div class="table-wrap" style="max-height:380px;overflow:auto"><table class="table"><thead><tr><th>Wijn / leverancier</th><th>Flessen</th><th>Inkoop netto</th><th>Actuele stukprijs*</th></tr></thead><tbody>'+
        [...wineArticles].sort((a,b)=>b.quantity-a.quantity).map(item=>'<tr><td>'+safe(item.name)+'<br><small>'+safe(item.supplier)+' · '+safe(item.sku)+'</small></td><td>'+item.quantity+'</td><td>'+money(item.net)+'</td><td>'+money(item.current_price)+'</td></tr>').join('')+
        '</tbody></table></div><p style="font-size:12px;color:var(--muted)">* Actuele stukprijs zoals vermeld in de bron (Bart: rapport van 1 september 2026); dit is niet noodzakelijk de betaalde prijs in 2025. Een betrouwbare prijsontwikkeling per periode vereist meerdere gedateerde facturen of prijslijsten van hetzelfde product. Artikelen met € 0 netto kunnen bijvoorbeeld gratis verstrekte flessen bevatten.</p>';
    } else {
      wineProductBox.classList.add('note');
      wineProductBox.textContent = 'Voor deze selectie zijn nog geen verwerkte wijnartikelregels beschikbaar. Voeg een gespecificeerde leveranciersfactuur of artikelstatistiek toe om aantallen en productprijzen te kunnen analyseren.';
    }

    // Volledige wijnpagina: gebruik exact dezelfde geselecteerde transacties als het subgroepoverzicht.
    this._wineDetail = detailBySubgroup.wijn || {suppliers:[]};
    this._wineYear = yearBySubgroup.wijn;
    const wine = this._wineDetail;
    const wineSuppliers = [...(wine.suppliers || [])].sort((a,b)=>b.amount-a.amount);
    const wineTotal = wineSuppliers.reduce((sum,item)=>sum+item.amount,0);
    const wineCurrency = amount => new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR'}).format(amount);
    document.getElementById('wineTotal').textContent = wineSuppliers.length ? wineCurrency(wineTotal) : '—';
    document.getElementById('wineSupplierCount').textContent = wineSuppliers.length;
    document.getElementById('winePeriod').textContent = 'Bronjaar: ' + (this._wineYear || 'niet vastgesteld; controleer documenten');
    document.getElementById('wineSupplierRows').innerHTML = wineSuppliers.length
      ? wineSuppliers.map(item => '<tr><td><strong>'+safe(item.name)+'</strong></td><td>'+wineCurrency(item.amount)+'</td><td>'+(wineTotal ? new Intl.NumberFormat('nl-NL',{maximumFractionDigits:1}).format(item.amount/wineTotal*100)+'%' : '—')+'</td></tr>').join('')
      : '<tr><td colspan="3">Nog geen verwerkte wijninkoop per leverancier beschikbaar.</td></tr>';
    const next = STATE.selectedSubgroups.filter(id=>id!==primarySubgroupId())[0];
    document.getElementById("dashNextAction").textContent = next
      ? `Upload je ${subgroupName(next).toLowerCase()}-document om je volgende analyse te starten.${pct == null ? '' : ` Je profiel is voor ${pct}% voltooid.`}`
      : `Open extra subgroepen om je volledige benchmark te ontgrendelen.${pct == null ? '' : ` Je profiel is voor ${pct}% voltooid.`}`;

    // contracts tab renders lazily via showTab('contracten')

    // savings
    document.getElementById("dashSavingsTable").innerHTML = rows.map(r=>{
      const est = r.isPrimary && STATE.result ? `${euro(STATE.result.low)} – ${euro(STATE.result.high)}` : (r.badge==="b-green" ? euro(r.cost*0.06)+" – "+euro(r.cost*0.12) : "Nog te bepalen");
      return `<tr><td>${r.name}</td><td>${est}</td><td><span class="badge ${r.badge}">${r.status}</span></td></tr>`;
    }).join("");

    // authorizations
    renderAuthTable();

    // profile
    const p = STATE.profile;
    document.getElementById("dashProfileKv").innerHTML = `
      <div><span>Bedrijfsnaam</span>${STATE.account.companyName||"—"}</div>
      <div><span>Contactpersoon</span>${STATE.account.contactPerson||"—"}</div>
      <div><span>E-mail</span>${CURRENT_USER ? CURRENT_USER.email : (STATE.account.email||"—")}</div>
      <div><span>Telefoon</span>${STATE.account.phone||"—"}</div>
      <div><span>Type horecazaak</span>${p.businessType||"—"}</div>
      <div><span>Vestigingsplaats</span>${p.city||"—"}</div>
    `;

    // async tabs that update independently
    this.renderDocuments();
    this.renderProfiel();
    this.renderOverzicht();
  },

  async renderDocuments(){
    const el = document.getElementById("dashDocuments");
    const loginNote = document.getElementById("docsLoginNote");
    const docsCountEl = document.getElementById("dashDocsCount");

    if (CURRENT_USER) {
      loginNote.style.display = "none";
      el.innerHTML = `<div class="empty-state" style="padding:20px">Documenten laden…</div>`;
      const [{ data: uploads, error }, { data: transactions }] = await Promise.all([
        sb.from('uploads')
          .select('id, file_name, subgroup, uploaded_at, file_path')
          .eq('email', CURRENT_USER.email)
          .order('uploaded_at', { ascending: false }),
        sb.from('transactions')
          .select('id, raw_data, monthly_amount, renewal_date, period_start, period_end, transaction_date, is_contract, categories(name)')
          .eq('email', CURRENT_USER.email)
      ]);
      if (error) {
        el.innerHTML = `<div class="empty-state" style="color:var(--danger-ink)">Fout bij laden: ${error.message}</div>`;
        return;
      }
      const safeDoc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
      const { selected } = dashboardCostSelection(transactions || []);
      const byPath = new Map(), bySourceName = new Map();
      (transactions || []).forEach(t => {
        const record = { year: selected.get(t.id) || null, category: CATEGORY_TO_SUBGROUP[t.categories?.name], role: t.raw_data?.comparison_role, period: t.raw_data?.period_label };
        if(t.raw_data?.file_path){
          const entries = byPath.get(t.raw_data.file_path) || [];
          entries.push(record);
          byPath.set(t.raw_data.file_path, entries);
        }
        if(t.raw_data?.source_file && t.raw_data?.source_verified === true){
          const entries = bySourceName.get(t.raw_data.source_file) || [];
          entries.push(record);
          bySourceName.set(t.raw_data.source_file, entries);
        }
      });
      const statusFor = records => {
        if(!records.length) return 'Nog niet verwerkt';
        if(records.some(x => x.role === 'benchmark')) return 'Prijsbenchmark 2026 · niet opgeteld';
        if(records.some(x => x.year === 2025)) return records.some(x => x.period === '2025 Q4') ? 'Kosten 2025 · Q4' : 'Kosten 2025';
        if(records.some(x => x.year === 2026)) return 'Tijdelijke referentie 2026';
        return 'Gegevens verwerkt · niet in kostentotaal';
      };
      const sourceEntries = [...bySourceName.entries()].filter(([fileName]) => !uploads.some(u => u.file_name === fileName));
      if(docsCountEl) docsCountEl.textContent = uploads.length + sourceEntries.length;
      this.updateDocumentProgress(uploads.length + sourceEntries.length);
      if(!uploads.length && !sourceEntries.length){
        el.innerHTML = '<div class="empty-state">Nog geen documenten of verwerkte brongegevens beschikbaar.</div>';
        return;
      }
      const fileCell = name => '<span class="file-name" title="'+safeDoc(name)+'" style="display:block;max-width:300px;overflow-wrap:anywhere;line-height:1.4">'+safeDoc(name)+'</span>';
      el.innerHTML = '<p style="font-size:12px;color:var(--muted);margin:0 0 12px">Ook brongegevens die rechtstreeks zijn verwerkt staan hieronder. “Brongegevens verwerkt” betekent niet dat het originele bestand in je documentenopslag is geüpload.</p><div class="table-wrap"><table class="table">'+
        '<thead><tr><th>Bestand</th><th>Subgroep</th><th>Gebruik</th><th>Beschikbaarheid</th><th>Actie</th></tr></thead><tbody>'+
        uploads.map(u => {
          const records = byPath.get(u.file_path) || bySourceName.get(u.file_name) || [];
          const subgroup = u.subgroup ? subgroupName(u.subgroup) : records[0]?.category ? subgroupName(records[0].category) : 'Nog niet gekoppeld';
          const date = u.uploaded_at ? new Date(u.uploaded_at).toLocaleDateString('nl-NL') : 'Datum onbekend';
          return '<tr><td>'+fileCell(u.file_name)+'</td><td>'+safeDoc(subgroup)+'</td><td>'+safeDoc(statusFor(records))+'</td><td>Geüpload · '+safeDoc(date)+'</td><td><button class="btn btn-ghost btn-sm" style="color:var(--danger-ink);border-color:var(--danger-ink)" onclick="Dashboard.deleteUpload(\''+u.id+'\',\''+u.file_path.replace(/'/g,"\\'")+'\')">Verwijderen</button></td></tr>';
        }).join('')+
        sourceEntries.map(([fileName,records]) => {
          const first = records[0] || {};
          const category = first.category;
          const isWaste2025 = category === 'afval' && records.some(x => x.period === '2025 Q4');
          const isWaste2026 = category === 'afval' && records.some(x => x.role === 'benchmark');
          const usage = isWaste2025 ? 'Kostenbasis · Q4 2025' : isWaste2026 ? 'Prijsbenchmark · Q2 2026 (niet opgeteld)' : category === 'energie' ? 'Kostenbasis · 2025' : category === 'wijn' ? 'Wijninkoop · 2025' : statusFor(records);
          const action = category === 'wijn'
            ? '<button class="btn btn-ghost btn-sm" onclick="Dashboard.openWineDetail()">Bekijk wijnanalyse</button>'
            : category === 'afval' || category === 'energie'
            ? '<button class="btn btn-ghost btn-sm" onclick="Dashboard.showTab(\'subgroepen\')">Bekijk subgroepen</button>'
            : '—';
          return '<tr><td>'+fileCell(fileName)+'</td><td>'+safeDoc(category ? subgroupName(category) : 'Nog niet gekoppeld')+'</td><td>'+safeDoc(usage)+'</td><td>Brongegevens verwerkt; origineel niet opgeslagen</td><td>'+action+'</td></tr>';
        }).join('')+
        '</tbody></table></div>';
    } else {
      // Not logged in: show demo names from localStorage + login nudge
      loginNote.style.display = "inline";
      const uploadedNames = STATE.uploadFileNames?.length ? STATE.uploadFileNames : (STATE.uploadFileName ? [STATE.uploadFileName] : []);
      if (docsCountEl) docsCountEl.textContent = uploadedNames.length || "—";
      if (!uploadedNames.length) {
        el.innerHTML = `<div class="empty-state">Nog geen documenten geüpload.</div>`;
        return;
      }
      el.innerHTML = `<table class="table">
        <thead><tr><th>Bestand</th><th>Subgroep</th><th>Status</th></tr></thead>
        <tbody>${uploadedNames.map(n => `<tr>
          <td>${n}</td>
          <td>${subgroupName(primarySubgroupId())}</td>
          <td><span class="badge b-green">Ontvangen</span></td>
        </tr>`).join('')}</tbody>
      </table>`;
    }
  },

  updateDocumentProgress(documentCount){
    const pct = Math.min(100, documentCount * 10);
    for (const id of ['dashProfilePct', 'dashProfilePctSummary', 'dashProfilePctDemo']) {
      const el = document.getElementById(id);
      if (el) el.textContent = `${pct}%`;
    }
    document.getElementById('dashProfilePct2').textContent = `${pct}% voltooid`;
    document.getElementById('dashProfileBar').style.width = `${pct}%`;
    const actionEl = document.getElementById('dashNextAction');
    if (actionEl) {
      const next = STATE.selectedSubgroups.find(id => id !== primarySubgroupId());
      actionEl.textContent = next
        ? `Upload je ${subgroupName(next).toLowerCase()}-document om je volgende analyse te starten. Je profiel is voor ${pct}% voltooid.`
        : `Upload je volgende document om je profiel aan te vullen. Je profiel is voor ${pct}% voltooid.`;
    }
  },

  async deleteUpload(uploadId, filePath){
    if (!CURRENT_USER) return;
    if (!confirm('Weet je zeker dat je dit document wilt verwijderen?')) return;
    // Remove from storage
    await sb.storage.from('client-uploads').remove([filePath]);
    // Remove from database
    const { error } = await sb.from('uploads').delete().eq('id', uploadId);
    if (error) { alert('Verwijderen mislukt: ' + error.message); return; }
    this.render();
  },
  openWineDetail(){
    this.showTab('wijn-detail');
    const heading = document.querySelector('#dashTab-wijn-detail h2');
    if (heading) heading.scrollIntoView({block:'start'});
  },
  showTab(tab){
    document.querySelectorAll(".dash-tab").forEach(el=>el.style.display="none");
    document.getElementById("dashTab-"+tab).style.display="block";
    document.querySelectorAll(".side-nav a[data-dash]").forEach(a=>a.classList.toggle("active", a.dataset.dash===tab));
    if (tab === 'documenten' && CURRENT_USER) {
      const emailEl = document.getElementById('docUploadEmail');
      if (emailEl && !emailEl.value) emailEl.value = CURRENT_USER.email;
    }
    if (tab === 'machtigingen') AuthModule.loadAndRender();
    if (tab === 'besparingen') this.renderBesparingen();
    if (tab === 'contracten') this.renderContracten();
    if (tab === 'profiel') this.renderProfiel();
    if (tab === 'overzicht') this.renderOverzicht();
  },
  async renderBesparingen(){
    const el = document.getElementById('dashSpendChart');
    if (!el) return;

    const DEMO_SPEND = [
      {category:'Inkoop (overig)', total: 4820},
      {category:'Vlees', total: 3150},
      {category:'Dranken', total: 2640},
      {category:'Energie', total: 1980},
      {category:'Schoonmaak', total: 870},
    ];

    let rows = [];
    let unitRows = []; // rows with quantity+unit for price-per-unit card
    if (CURRENT_USER) {
      const { data, error } = await sb
        .from('transactions')
        .select('amount, quantity, unit, categories(name)')
        .eq('email', CURRENT_USER.email);
      if (!error && data && data.length) {
        const agg = {}, unitAgg = {};
        data.forEach(r => {
          const cat = r.categories?.name || 'Overig';
          agg[cat] = (agg[cat] || 0) + parseFloat(r.amount || 0);
          if (r.quantity && r.unit) {
            if (!unitAgg[cat]) unitAgg[cat] = { totalAmount: 0, totalQty: 0, unit: r.unit };
            unitAgg[cat].totalAmount += parseFloat(r.amount || 0);
            unitAgg[cat].totalQty   += parseFloat(r.quantity || 0);
          }
        });
        rows = Object.entries(agg)
          .map(([category, total]) => ({category, total}))
          .sort((a,b) => b.total - a.total);
        unitRows = Object.entries(unitAgg).map(([category, v]) => ({
          category,
          unitPrice: v.totalQty > 0 ? v.totalAmount / v.totalQty : null,
          unit: v.unit,
          totalQty: v.totalQty,
        }));
      }
    }

    const isDemo = rows.length === 0;
    if (isDemo) rows = DEMO_SPEND;

    const max = rows[0]?.total || 1;
    const fmt  = v => new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(v);
    const fmtU = v => new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',minimumFractionDigits:2,maximumFractionDigits:2}).format(v);
    const COLORS = ['#163829','#2f6b4c','#4a9b71','#7ec8a0','#b2dfc3'];

    el.innerHTML = (isDemo ? `<p style="font-size:12px;color:var(--muted);margin:0 0 12px;font-style:italic">Voorbeelddata — log in en upload facturen om jouw eigen uitgaven te zien.</p>` : '') +
      rows.map((r, i) => `
        <div style="margin-bottom:10px">
          <div style="display:flex;justify-content:space-between;font-size:13px;margin-bottom:4px">
            <span style="color:var(--ink)">${r.category}</span>
            <span style="font-family:'IBM Plex Mono',monospace;font-size:12px;color:var(--muted)">${fmt(r.total)}</span>
          </div>
          <div style="background:var(--line);border-radius:4px;height:20px;overflow:hidden">
            <div style="height:100%;width:${Math.round(r.total/max*100)}%;background:${COLORS[i%COLORS.length]};border-radius:4px;transition:width .4s ease"></div>
          </div>
        </div>`).join('');

    // Unit price card
    const upCard = document.getElementById('dashUnitPriceCard');
    const upList = document.getElementById('dashUnitPriceList');
    if (!upCard || !upList || !unitRows.length) { if (upCard) upCard.style.display = 'none'; return; }

    const { data: benchRows } = await sb.from('benchmark_data')
      .select('category_name, avg_unit_price, unit, unit_label')
      .not('avg_unit_price', 'is', null);
    const benchByCategory = {};
    (benchRows || []).forEach(r => { benchByCategory[r.category_name] = r; });

    const upItems = unitRows.filter(r => r.unitPrice !== null);
    if (!upItems.length) { upCard.style.display = 'none'; return; }

    upCard.style.display = 'block';

    // Find best savings opportunity (highest absolute overspend vs benchmark)
    let bestOpportunity = null;
    let totalOverspend = 0;

    upList.innerHTML = `<table class="table">
      <thead><tr><th>Categorie</th><th>Jouw prijs</th><th>Groepsgemiddelde</th><th>Verschil</th><th>Volume</th></tr></thead>
      <tbody>${upItems.map(r => {
        const bench = benchByCategory[r.category];
        const avgPrice = bench?.avg_unit_price;
        const unitLabel = bench?.unit_label || `per ${r.unit}`;
        const diff = avgPrice ? ((r.unitPrice - avgPrice) / avgPrice * 100) : null;
        const diffHtml = diff !== null
          ? `<span style="font-weight:600;color:${diff > 0 ? 'var(--danger-ink)' : 'var(--positive-ink)'}">${diff > 0 ? '+' : ''}${diff.toFixed(1)}%</span>`
          : `<span style="color:var(--muted)">—</span>`;
        const volFmt = new Intl.NumberFormat('nl-NL',{maximumFractionDigits:0});
        // Track overspend for CTA
        if (diff !== null && diff > 5 && avgPrice) {
          const annualOverspend = (r.unitPrice - avgPrice) * r.totalQty;
          totalOverspend += annualOverspend;
          if (!bestOpportunity || annualOverspend > bestOpportunity.saving) {
            bestOpportunity = { category: r.category, diff, saving: annualOverspend, unitPrice: r.unitPrice, avgPrice, unitLabel };
          }
        }
        return `<tr>
          <td><strong>${r.category}</strong></td>
          <td style="font-family:'IBM Plex Mono',monospace">${fmtU(r.unitPrice)} <span style="font-size:11px;color:var(--muted)">${unitLabel}</span></td>
          <td style="font-family:'IBM Plex Mono',monospace;color:var(--muted)">${avgPrice ? fmtU(avgPrice) + ` <span style="font-size:11px">${unitLabel}</span>` : '—'}</td>
          <td>${diffHtml}</td>
          <td style="font-size:12px;color:var(--muted)">${volFmt.format(r.totalQty)} ${r.unit}</td>
        </tr>`;
      }).join('')}</tbody>
    </table>`;

    // Show proposal CTA if overspend found
    Proposals.showCTA(bestOpportunity, totalOverspend);

    // Vleesprijs-over-tijd grafiek
    await this.renderVleesPrijsGrafiek();
  },

  async renderVleesPrijsGrafiek(){
    const card = document.getElementById('dashVleesPrijsCard');
    if (!card) return;
    if (!CURRENT_USER) { card.style.display = 'none'; return; }

    const { data, error } = await sb
      .from('transactions')
      .select('transaction_date, amount, quantity, unit, product_name')
      .eq('email', CURRENT_USER.email)
      .not('quantity', 'is', null)
      .not('transaction_date', 'is', null)
      .order('transaction_date', { ascending: true });
    if (error || !data) { card.style.display = 'none'; return; }

    // Filter op vlees-categorie via join is al gedaan in renderBesparingen,
    // maar hier halen we vlees op via categorie join
    const { data: vleesRows } = await sb
      .from('transactions')
      .select('transaction_date, amount, quantity, unit, product_name, categories(name)')
      .eq('email', CURRENT_USER.email)
      .not('quantity', 'is', null)
      .not('transaction_date', 'is', null)
      .order('transaction_date', { ascending: true });

    const pts = (vleesRows || [])
      .filter(r => r.categories?.name === 'Vlees' && parseFloat(r.quantity) > 0)
      .map(r => ({
        date: r.transaction_date,
        price: parseFloat(r.amount) / parseFloat(r.quantity),
        qty: parseFloat(r.quantity),
        label: r.product_name || 'Vlees',
      }));

    if (pts.length < 2) { card.style.display = 'none'; return; }

    card.style.display = 'block';

    const minP = Math.min(...pts.map(p => p.price));
    const maxP = Math.max(...pts.map(p => p.price));
    const padded = { min: minP * 0.92, max: maxP * 1.08 };
    const range = padded.max - padded.min || 1;

    const W = 560, H = 160, PL = 48, PR = 16, PT = 12, PB = 32;
    const chartW = W - PL - PR;
    const chartH = H - PT - PB;

    const xOf = (i) => PL + (i / (pts.length - 1)) * chartW;
    const yOf = (p) => PT + chartH - ((p - padded.min) / range) * chartH;

    const polyline = pts.map((p, i) => `${xOf(i).toFixed(1)},${yOf(p.price).toFixed(1)}`).join(' ');
    const area = `${xOf(0).toFixed(1)},${(PT + chartH).toFixed(1)} ` +
      pts.map((p, i) => `${xOf(i).toFixed(1)},${yOf(p.price).toFixed(1)}`).join(' ') +
      ` ${xOf(pts.length-1).toFixed(1)},${(PT + chartH).toFixed(1)}`;

    const fmtEur = v => `€${v.toFixed(2).replace('.', ',')}`;
    const fmtDate = s => { const d = new Date(s); return d.toLocaleDateString('nl-NL', {month:'short', day:'numeric'}); };

    // Y-axis ticks
    const ticks = 4;
    const yTicks = Array.from({length: ticks + 1}, (_, i) => padded.min + (range * i / ticks));

    // X-axis labels (max 6 spread)
    const xIdxs = pts.length <= 6
      ? pts.map((_, i) => i)
      : [0, Math.floor(pts.length/4), Math.floor(pts.length/2), Math.floor(pts.length*3/4), pts.length - 1];

    // Trend kleur
    const trend = pts[pts.length-1].price - pts[0].price;
    const trendColor = trend > 0.5 ? 'var(--danger-ink)' : trend < -0.5 ? 'var(--positive-ink)' : 'var(--muted)';
    const trendLabel = trend > 0.5 ? `+${fmtEur(trend)}/kg stijging` : trend < -0.5 ? `${fmtEur(trend)}/kg daling` : 'Stabiel';

    const el = document.getElementById('dashVleesPrijsChart');
    if (!el) return;
    el.innerHTML = `
      <div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px">
        <span style="font-size:13px;font-weight:600;color:var(--ink)">Inkoopprijs vlees per kg</span>
        <span style="font-size:12px;color:${trendColor}">${trendLabel}</span>
      </div>
      <svg viewBox="0 0 ${W} ${H}" style="width:100%;height:auto;display:block;overflow:visible">
        <defs>
          <linearGradient id="vleesFill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#163829" stop-opacity="0.18"/>
            <stop offset="100%" stop-color="#163829" stop-opacity="0.02"/>
          </linearGradient>
        </defs>
        <!-- Grid lines -->
        ${yTicks.map(t => `<line x1="${PL}" y1="${yOf(t).toFixed(1)}" x2="${W-PR}" y2="${yOf(t).toFixed(1)}"
          stroke="var(--line)" stroke-width="1"/>`).join('')}
        <!-- Area fill -->
        <polygon points="${area}" fill="url(#vleesFill)"/>
        <!-- Line -->
        <polyline points="${polyline}" fill="none" stroke="#163829" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>
        <!-- Data points -->
        ${pts.map((p, i) => `<circle cx="${xOf(i).toFixed(1)}" cy="${yOf(p.price).toFixed(1)}" r="3.5"
          fill="white" stroke="#163829" stroke-width="2">
          <title>${fmtDate(p.date)}: ${fmtEur(p.price)}/kg (${p.label})</title>
        </circle>`).join('')}
        <!-- Y-axis labels -->
        ${yTicks.map(t => `<text x="${PL - 6}" y="${(yOf(t) + 4).toFixed(1)}"
          text-anchor="end" font-size="10" fill="var(--muted)" font-family="IBM Plex Mono,monospace">${fmtEur(t)}</text>`).join('')}
        <!-- X-axis labels -->
        ${xIdxs.map(i => `<text x="${xOf(i).toFixed(1)}" y="${(PT + chartH + 18).toFixed(1)}"
          text-anchor="middle" font-size="10" fill="var(--muted)">${fmtDate(pts[i].date)}</text>`).join('')}
      </svg>`;
  },

  async renderOverzicht(){
    if (!CURRENT_USER) return; // demo summary already shown by render()
    const [{ data, error }, { data: uploads }] = await Promise.all([
      sb.from('transactions')
        .select('id, amount, monthly_amount, renewal_date, transaction_date, period_start, period_end, is_contract, raw_data, categories(name)')
        .eq('email', CURRENT_USER.email),
      sb.from('uploads').select('file_name, file_path').eq('email', CURRENT_USER.email)
    ]);
    const notice = document.getElementById('dashBookYearNotice');
    if (error || !data) {
      notice.style.display = 'block';
      notice.textContent = 'Uitgaven voor 2025 konden niet worden geladen. Probeer het later opnieuw.';
      return;
    }

    // Prefer 2025 sources; use selected 2026 references for missing subgroups.
    const agg = {};
    const reviewByPath = new Map();
    const processedPaths = new Set();
    const includedPaths = new Set();
    const { selected, categoriesWith2025 } = dashboardCostSelection(data);
    const temporaryReferences = new Set();
    data.forEach(r => {
      const path = r.raw_data?.file_path;
      if(path) processedPaths.add(path);
      const sourceYear = selected.get(r.id);
      const cat = dashboardCategory(r);
      if(!sourceYear){
        const is2026Reference = (cat === 'Muzieklicentie' && bookYearTransaction(r, 2026).included)
          || policyYear(r) === 2026 || firstTelecomYear(r) === 2026;
        const reason = categoriesWith2025.has(cat) && is2026Reference
          ? '2025 beschikbaar; 2026 niet dubbel meegeteld'
          : bookYearTransaction(r).reason;
        if(path && !reviewByPath.has(path)) reviewByPath.set(path, reason);
        return;
      }
      if(path) includedPaths.add(path);
      if(sourceYear === 2026) temporaryReferences.add(cat);
      const amount = dashboardAmount(r);
      if(Number.isFinite(amount)) agg[cat] = (agg[cat] || 0) + amount;
    });
    const wasteEstimate = wasteAnnualEstimate(data);
    if(wasteEstimate) agg['Afval & milieu'] = wasteEstimate.estimate;
    const total = Object.values(agg).reduce((a,b) => a+b, 0);
    const catCount = Object.keys(agg).length;
    const review = (uploads || []).flatMap(u => {
      if(includedPaths.has(u.file_path)) return [];
      if(reviewByPath.has(u.file_path)) return [`${u.file_name}: ${reviewByPath.get(u.file_path)}`];
      if(!processedPaths.has(u.file_path)) return [`${u.file_name}: verwerking of boekjaar nog niet bevestigd`];
      return [];
    });
    notice.replaceChildren();
    notice.style.display = review.length || temporaryReferences.size ? 'block' : 'none';
    const referenceDescriptions = {
      Muzieklicentie: 'Buma/Sena: 2026 telt tijdelijk mee als referentie totdat een bedrag uit 2025 beschikbaar is.',
      Verzekeringen: 'De Goudse: maandpremie uit de polis van 2026 × 12, inclusief assurantiebelasting. Dit is een jaarindicatie, geen uitgave over 2025.',
      Telecom: 'Odido: voorlopige start 15-04-2026 op basis van de besteldatum. Het eerste contractjaar (t/m 14-04-2027) telt mee. Het tweede (15-04-2027 t/m 14-04-2028) staat apart en telt niet dubbel mee. De echte activatiedatum kan dit wijzigen.'
    };
    if(wasteEstimate){
      notice.style.display = 'block';
      const note = document.createElement('p');
      note.style.margin = '0 0 8px';
      note.textContent = 'Afval & milieu: in Bekende kosten is een indicatie van de jaarkosten opgenomen op basis van '+wasteEstimate.coveredDays+' dagen aan facturen uit 2025 (€ '+wasteEstimate.actual.toLocaleString('nl-NL',{minimumFractionDigits:2,maximumFractionDigits:2})+' werkelijk). Dit is geen vastgesteld jaartotaal.';
      notice.append(note);
    }
    temporaryReferences.forEach(category => {
      const reference = document.createElement('p');
      reference.style.margin = '0 0 8px';
      reference.textContent = referenceDescriptions[category] || `${category}: 2026 wordt tijdelijk gebruikt totdat 2025 beschikbaar is.`;
      notice.append(reference);
    });
    if(review.length){
      const title = document.createElement('strong');
      title.textContent = 'Overige documenten niet meegenomen in dit totaal:';
      notice.append(title);
      const list = document.createElement('ul');
      list.style.margin = '6px 0 0';
      review.forEach(message => {
        const item = document.createElement('li');
        item.textContent = message;
        list.append(item);
      });
      notice.append(list);
    }

    // Show real summary tiles
    document.getElementById('dashRealSummary').style.display = 'block';
    document.getElementById('dashDemoSummary').style.display = 'none';
    document.getElementById('dashTotalSpend').textContent = new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR'}).format(total);
    document.getElementById('dashCatCount').textContent = catCount;
    // Savings estimate: 8-14% of total spend
    document.getElementById('dashPotential').textContent =
      `${new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(total*0.08)} – ${new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(total*0.14)}`;

    // Benchmark chart — fetch from Supabase
    const { data: benchRows } = await sb.from('benchmark_data').select('category_name, avg_amount, sample_size');
    const BENCHMARK = {};
    (benchRows || []).forEach(r => { BENCHMARK[r.category_name] = { avg: parseFloat(r.avg_amount), n: r.sample_size }; });

    const benchCats = Object.keys(agg).filter(c => BENCHMARK[c]);
    if (!benchCats.length) return;

    const fmt = v => new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(v);
    const maxVal = Math.max(...benchCats.flatMap(c => [agg[c], BENCHMARK[c]?.avg || 0]));

    const card = document.getElementById('dashBenchmarkCard');
    const chartEl = document.getElementById('dashBenchmarkChart');
    card.style.display = 'block';
    chartEl.innerHTML = `
      <div style="display:flex;gap:16px;font-size:12px;margin-bottom:12px">
        <span style="display:flex;align-items:center;gap:6px"><span style="width:12px;height:12px;border-radius:2px;background:var(--brand);display:inline-block"></span>Jouw uitgave</span>
        <span style="display:flex;align-items:center;gap:6px"><span style="width:12px;height:12px;border-radius:2px;background:#c8d8c0;display:inline-block"></span>Groepsgemiddelde</span>
      </div>` +
      benchCats.map(cat => {
        const mine = agg[cat];
        const avg = BENCHMARK[cat].avg;
        const n = BENCHMARK[cat].n;
        const diff = mine - avg;
        const diffPct = Math.round((diff / avg) * 100);
        const diffColor = diff > 0 ? 'var(--danger-ink)' : 'var(--positive-ink)';
        const diffLabel = diff > 0 ? `+${diffPct}% boven gemiddelde` : `${diffPct}% onder gemiddelde`;
        return `
          <div style="margin-bottom:14px">
            <div style="display:flex;justify-content:space-between;align-items:baseline;font-size:13px;margin-bottom:4px">
              <span style="color:var(--ink);font-weight:500">${cat}</span>
              <span style="font-size:11px;color:${diffColor}">${diffLabel}${n ? ` (n=${n})` : ''}</span>
            </div>
            <div style="position:relative;height:20px;background:var(--line);border-radius:4px;overflow:hidden;margin-bottom:3px">
              <div style="height:100%;width:${Math.round(mine/maxVal*100)}%;background:var(--brand);border-radius:4px"></div>
            </div>
            <div style="position:relative;height:14px;background:var(--line);border-radius:4px;overflow:hidden">
              <div style="height:100%;width:${Math.round(avg/maxVal*100)}%;background:#c8d8c0;border-radius:4px"></div>
            </div>
            <div style="display:flex;justify-content:space-between;font-size:11px;color:var(--muted);margin-top:3px">
              <span>${fmt(mine)}</span><span>gem. ${fmt(avg)}</span>
            </div>
          </div>`;
      }).join('');
  },

  async renderContracten(){
    const el = document.getElementById('dashContractBody');
    if (!el) return;

    const DEMO_CONTRACTS = [
      {category:'Verzekeringen', supplier:'De Goudse', period_start:'2021-07-01', period_end:null, amount:5208, notes:'Horeca all-risk polis', notice_period_text:'Dagelijks opzegbaar vanaf een jaar na ingangsdatum', has_contract:true},
      {category:'Elektra', supplier:'Hezelaer Energy', period_start:'2025-01-01', period_end:'2026-01-01', amount:11233, notes:'Jaarafrekening elektriciteit 2025', has_contract:true},
      {category:'Gas', supplier:'Hezelaer Energy', period_start:'2025-01-01', period_end:'2026-01-01', amount:2394, notes:'Jaarafrekening gas 2025', has_contract:true},
      {category:'Muziekrechten', supplier:'Buma/Sena', period_start:'2026-01-01', period_end:'2026-12-31', amount:1122, notes:'Buma + Sena licentie 2026', has_contract:true},
      {category:'Afval & milieu', supplier:'Milieu Service NL', period_start:'2026-07-01', period_end:'2026-09-30', amount:604, notes:'Afvalcontract kwartaal Q3', has_contract:true},
      {category:'Telecom', supplier:'Odido', period_start:'2026-04-15', period_end:'2028-04-15', date_confidence:'estimated', cancel_by_date:'2028-03-15', amount:417.50, amount_note:'eerste 12 maanden; daarna € 498,00 per jaar', notes:'Internet 100/30 Mbit/s: € 30,00 p/m in de eerste 12 maanden, daarna € 36,50 p/m. Vast Bellen Start: € 2,50 p/m. Thuis Veilig Online: alleen de eerste maand gratis, daarna € 2,50 p/m.', notice_period_months:1, notice_period_text:'1 maand', has_contract:true},
      {category:'Inkoop (overig)', supplier:'—', period_start:null, period_end:null, amount:null, notes:'', has_contract:false},
    ];

    const fmt = v => v != null ? new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',minimumFractionDigits:2,maximumFractionDigits:2}).format(v) : '—';
    const fmtDate = s => s ? new Date(s).toLocaleDateString('nl-NL',{year:'numeric',month:'short',day:'numeric'}) : null;
    const safe = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
    const isFlexibleCancellation = r => /dagelijks|maandelijks/i.test(r.notice_period_text || '');
    const contractBadge = r => {
      if (r.is_supplier_relation) return isFlexibleCancellation(r)
        ? '<span class="badge b-green">Dagelijks opzegbaar</span>'
        : '<span class="badge b-grey">Looptijd onbekend</span>';
      if (!r.has_contract && r.has_expense) return '<span class="badge b-grey">Contract niet aangeleverd</span>';
      if (!r.has_contract) return '<span class="badge b-grey">Geen contract</span>';
      if (isFlexibleCancellation(r)) return '<span class="badge b-green">Opzegbaar</span>';
      if (!r.period_end) return '<span class="badge b-grey">Onbekend</span>';
      const days = (new Date(r.period_end) - new Date()) / 86400000;
      if (days < 0)   return '<span class="badge b-grey">Verlopen</span>';
      if (days < 60)  return '<span class="badge b-red">Binnenkort</span>';
      if (days < 180) return '<span class="badge b-yellow">Let op</span>';
      return '<span class="badge b-green">Lopend</span>';
    };
    const cancellationHtml = r => {
      if (r.is_supplier_relation) return r.notice_period_text
        ? `<strong style="font-size:12px">${r.notice_period_text}</strong>`
        : '<span style="color:var(--muted);font-size:12px">Niet bekend</span>';
      if (!r.has_contract) return '<span style="color:var(--muted);font-size:12px">—</span>';
      if (isFlexibleCancellation(r)) {
        return `<strong style="font-size:12px">${r.notice_period_text}</strong>`;
      }
      if (r.cancel_by_date) {
        return `<strong style="font-size:12px">Uiterlijk ${fmtDate(r.cancel_by_date)}</strong>${r.notice_period_text ? `<br><span style="font-size:11px;color:var(--muted)">Opzegtermijn: ${r.notice_period_text}</span>` : ''}`;
      }
      if (r.notice_period_text) return `<span style="font-size:12px">${r.notice_period_text}</span>`;
      return '<span style="color:var(--muted);font-size:12px">Nog aanvullen</span>';
    };

    let rows = [];
    let isDemo = false;

    if (CURRENT_USER) {
      // Haal alle contracteerbare categorieën op
      const { data: cats } = await sb
        .from('categories')
        .select('id, name')
        .eq('is_active', true)
        .or('is_contracteerbaar.eq.true,name.eq.Wijn');

      // Haal contractregels op
      const { data: contractRows } = await sb
        .from('transactions')
        .select('category_id, amount, period_start, period_end, notes, notice_period_months, notice_period_text, auto_renews, raw_data, categories(name), suppliers(name)')
        .eq('email', CURRENT_USER.email)
        .eq('is_contract', true);

      // Haal alle transacties op voor bedrag-totaal per categorie (ook zonder contract)
      const { data: allTx } = await sb
        .from('transactions')
        .select('id, category_id, amount, monthly_amount, transaction_date, period_start, period_end, is_contract, raw_data, categories(name), suppliers(name)')
        .eq('email', CURRENT_USER.email);

      const totalByCat = {};
      const { selected: selectedCosts } = dashboardCostSelection(allTx || []);
      const selectedByCat = {};
      (allTx || []).filter(r => selectedCosts.has(r.id)).forEach(r => {
        const amount = dashboardAmount(r);
        if (!Number.isFinite(amount)) return;
        totalByCat[r.category_id] = (totalByCat[r.category_id] || 0) + amount;
        (selectedByCat[r.category_id] ||= []).push(r);
      });

      const contractByCat = {};
      (contractRows || []).forEach(r => {
        const summary = r.raw_data?.contract_summary;
        const current = contractByCat[r.category_id];

        // Eén overeenkomst kan uit meerdere productregels bestaan. Geef een
        // gecontroleerde contractsamenvatting voorrang, zodat een losse add-on
        // niet de omschrijving en het bedrag van het hele contract overschrijft.
        if (!current || (summary && !current.raw_data?.contract_summary)) {
          contractByCat[r.category_id] = r;
        }
      });

      // Wijn is vaak een inkooprelatie zonder getekend contract. Toon de
      // leverancier toch, maar geef een jaarstatistiek nooit een contracteinddatum.
      const categories = (cats || []).filter(cat => cat.name !== 'Wijn' ||
        (allTx || []).some(t => t.category_id === cat.id));
      if (categories.length) {
        rows = categories.flatMap(cat => {
          const c = contractByCat[cat.id];
          const summary = c?.raw_data?.contract_summary;
          const expenses = selectedByCat[cat.id] || [];
          const supplierNames = [...new Set(expenses.map(t => t.suppliers?.name || t.raw_data?.supplier).filter(Boolean))];
          if(cat.name === 'Wijn' && expenses.length){
            // Een wijnsubgroep heeft één totaal, maar elke leverancier heeft
            // zijn eigen afspraken en mag dus geen gezamenlijke opzegstatus krijgen.
            const bySupplier = new Map();
            expenses.forEach(t => {
              const supplier = t.suppliers?.name || t.raw_data?.supplier || 'Leverancier onbekend';
              if(!bySupplier.has(supplier)) bySupplier.set(supplier, []);
              bySupplier.get(supplier).push(t);
            });
            return [...bySupplier].map(([supplier, entries]) => {
              const contract = (contractRows || []).find(t => t.category_id === cat.id && t.suppliers?.name === supplier);
              const notice = contract?.notice_period_text || entries.find(t => t.raw_data?.notice_period_text)?.raw_data.notice_period_text || '';
              const isBart = supplier.includes('Beemster');
              return {
                category: 'Wijn', supplier, period_start:contract?.period_start || null,
                period_end:contract?.period_end || null,
                period_text: contract ? '' : 'Inkoop 2025 · geen contracteinddatum',
                amount: entries.reduce((sum, t) => sum + dashboardAmount(t), 0),
                amount_note: isBart ? 'Nettobedrag; btw niet vermeld in de bron' : '',
                notes: `${isBart ? 'J. Bart wijnen — ' : ''}Inkoop bij ${supplier}. ${contract ? 'Overeenkomst geregistreerd.' : 'Geen lopend contract aangeleverd.'}`,
                notice_period_text: notice, has_contract:!!contract, has_expense:true,
                is_supplier_relation:!contract, auto_renews:contract?.auto_renews ?? null,
              };
            });
          }
          const supplierRelation = cat.name === 'Wijn' && !c && expenses.length > 0;
          return [{
            category: cat.name,
            supplier: c?.suppliers?.name || (supplierNames.length === 1 ? supplierNames[0] : supplierNames.length ? `${supplierNames.length} leveranciers` : '—'),
            period_start: summary?.period_start || c?.period_start || null,
            period_end: summary?.period_end || c?.period_end || null,
            period_text: supplierRelation ? 'Inkoop 2025 · contractperiode onbekend'
              : (!c && expenses.length ? 'Afrekening 2025 · contractperiode onbekend' : (summary?.period_text || '')),
            amount: summary?.annual_amount ?? (c ? parseFloat(c.amount || 0) : (totalByCat[cat.id] || null)),
            amount_note: supplierRelation ? 'Nettobedrag; btw niet vermeld in de bron' : (summary?.amount_note || ''),
            notes: supplierRelation ? `${supplierNames.length === 1 && supplierNames[0].includes('Beemster') ? 'J. Bart wijnen — ' : ''}Inkoopoverzicht 2025 van ${supplierNames.join(', ')}. Een contract en opzegtermijn zijn nog niet aangeleverd.` : (summary?.description || c?.notes || ''),
            notice_period_text: summary?.notice_period_text || c?.notice_period_text || '',
            notice_period_months: c?.notice_period_months || null,
            auto_renews: c?.auto_renews ?? null,
            date_confidence: c?.raw_data?.date_confidence || '',
            cancel_by_date: summary?.cancel_by_date || c?.raw_data?.cancel_by_date || null,
            has_contract: !!c,
            has_expense: expenses.length > 0,
            is_supplier_relation: supplierRelation,
          }];
        }).sort((a, b) => {
          // Contracten met naderende einddatum bovenaan, daarna geen contract
          if (a.has_contract && !b.has_contract) return -1;
          if (!a.has_contract && b.has_contract) return 1;
          if (a.period_end && b.period_end) return new Date(a.period_end) - new Date(b.period_end);
          return a.category.localeCompare(b.category);
        });
      }

      if (!rows.length) { isDemo = true; rows = DEMO_CONTRACTS; }
    } else {
      isDemo = true; rows = DEMO_CONTRACTS;
    }

    // Bepaal of er heronderhandelkansen zijn (contract aflopend of geen contract)
    const kansen = rows.filter(r => {
      if (r.is_supplier_relation) return false;
      if (!r.has_contract) return true;
      if (isFlexibleCancellation(r)) return true;
      const actionDate = r.cancel_by_date || r.period_end;
      if (!actionDate) return false;
      const days = (new Date(actionDate) - new Date()) / 86400000;
      return days < 120;
    });

    const kansenBanner = !isDemo && kansen.length
      ? `<div id="dashContractenKansenBanner" style="background:var(--warn-bg);border:1px solid var(--warn-ink);border-radius:8px;padding:14px 16px;margin-bottom:16px;display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
          <div>
            <strong style="color:var(--warn-ink);font-size:13px">${kansen.length} heronderhandelkans${kansen.length > 1 ? 'en' : ''} gevonden</strong>
            <p style="margin:2px 0 0;font-size:12px;color:var(--ink)">${kansen.map(r => r.category).join(', ')} — opzegbaar, binnenkort opzeggen of nog geen contract. Wij onderhandelen collectief voor betere voorwaarden.</p>
          </div>
          <button class="btn btn-primary btn-sm" onclick="Proposals.registerInterestContracts(${JSON.stringify(kansen.map(r => r.category))}, this)">Stuur mij een voorstel</button>
        </div>`
      : '';

    el.innerHTML = (isDemo ? `<p style="font-size:12px;color:var(--muted);font-style:italic;margin:0 0 12px">Voorbeelddata — log in en upload facturen om jouw eigen overzicht te zien.</p>` : '') +
      kansenBanner +
      `<table class="table"><thead><tr><th>Categorie</th><th>Leverancier</th><th>Periode</th><th>Bedrag</th><th>Opzegging</th><th>Status</th></tr></thead><tbody>` +
      rows.map(r => {
        const startStr = fmtDate(r.period_start);
        const endStr   = fmtDate(r.period_end);
        const periodeHtml = startStr || endStr
          ? `<span style="font-size:12px">${startStr ? startStr + ' –<br>' : ''}${endStr || ''}${r.date_confidence === 'estimated' ? `<br><em style="color:var(--warn-ink)">${r.category === 'Telecom' ? 'voorlopig: besteldatum als start' : 'geschat'}</em>` : ''}</span>`
          : r.period_text
            ? `<span style="font-size:12px">${safe(r.period_text)}</span>`
            : `<span style="color:var(--muted);font-size:12px">—</span>`;
        const actionDate = r.cancel_by_date || r.period_end;
        const days = actionDate ? (new Date(actionDate) - new Date()) / 86400000 : null;
        const isKans = !r.is_supplier_relation && (!r.has_contract || isFlexibleCancellation(r) || (days !== null && days < 120));
        const onderhandelBtn = !isDemo && isKans
          ? `<button class="btn btn-ghost btn-sm" style="font-size:11px;padding:2px 8px;margin-left:6px"
               data-category="${r.category}"
               onclick="Proposals.registerInterestContracts(['${r.category}'], this)">Voorstel</button>`
          : '';
        return `<tr${isKans ? ' style="background:rgba(var(--warn-rgb,251,191,36),0.07)"' : ''}>
          <td><strong>${safe(r.category)}</strong>${r.notes ? `<br><span style="font-size:11px;color:var(--muted)">${safe(r.notes)}</span>` : ''}</td>
          <td>${safe(r.supplier)}</td>
          <td>${periodeHtml}</td>
          <td style="font-family:'IBM Plex Mono',monospace;font-size:12.5px">${fmt(r.amount)}${r.amount_note ? `<br><span style="font-family:inherit;font-size:10px;color:var(--muted)">${safe(r.amount_note)}</span>` : ''}</td>
          <td>${cancellationHtml(r)}</td>
          <td style="white-space:nowrap">${contractBadge(r)}${onderhandelBtn}</td>
        </tr>`;
      }).join('') +
      `</tbody></table>`;
  },

  async renderProfiel(){
    const statsCard = document.getElementById('dashProfileStats');
    const statsKv = document.getElementById('dashProfileStatsKv');
    const kvEl = document.getElementById('dashProfileKv');
    const editBtn = document.getElementById('dashProfileEditBtn');

    if (!CURRENT_USER) {
      if (editBtn) editBtn.style.display = 'none';
      return;
    }
    if (editBtn) editBtn.style.display = '';

    // Load profile from Supabase (preferred) or fall back to STATE
    const { data: prof } = await sb.from('profiles').select('*').eq('email', CURRENT_USER.email).maybeSingle();
    const p = prof || {};
    const sp = STATE.profile || {};
    const acc = STATE.account || {};
    const uploadName = document.getElementById('docUploadName');
    if (uploadName && p.contact_person && !uploadName.value.trim()) uploadName.value = p.contact_person;

    if (kvEl) kvEl.innerHTML = `
      <div><span>Bedrijfsnaam</span>${p.company_name || acc.companyName || '—'}</div>
      <div><span>Contactpersoon</span>${p.contact_person || acc.contactPerson || '—'}</div>
      <div><span>E-mail</span>${CURRENT_USER.email}</div>
      <div><span>Telefoon</span>${p.phone || acc.phone || '—'}</div>
      <div><span>Type horecazaak</span>${p.business_type || sp.businessType || '—'}</div>
      <div><span>Vestigingsplaats</span>${p.city || sp.city || '—'}</div>
      ${p.kvk_number ? `<div><span>KVK-nummer</span>${p.kvk_number}</div>` : ''}
    `;

    // Also store loaded profile for edit form
    this._loadedProfile = p;

    // Extracted stats
    if (!statsCard || !statsKv) return;
    const { data: exData } = await sb.from('extracted_data')
      .select('volume_bier, volume_elektra_kwh, volume_gas_m3, volume_frisdrank, vuilnis_kosten, verzekering_dekking')
      .eq('email', CURRENT_USER.email);

    if (!exData || !exData.length) { statsCard.style.display = 'none'; return; }
    const sum = key => exData.reduce((acc, r) => acc + (parseFloat(r[key]) || 0), 0);
    const fmt = v => new Intl.NumberFormat('nl-NL',{maximumFractionDigits:0}).format(v);
    const gas = sum('volume_gas_m3'), kwh = sum('volume_elektra_kwh'),
          bier = sum('volume_bier'), fris = sum('volume_frisdrank'),
          afval = sum('vuilnis_kosten');
    const dekking = exData.map(r => r.verzekering_dekking).filter(Boolean).join('; ') || null;
    const items = [
      gas   ? `<div><span>Gasverbruik (m³)</span>${fmt(gas)} m³</div>` : '',
      kwh   ? `<div><span>Elektraverbruik (kWh)</span>${fmt(kwh)} kWh</div>` : '',
      bier  ? `<div><span>Biervolume (liter)</span>${fmt(bier)} L</div>` : '',
      fris  ? `<div><span>Frisdrankvolume (liter)</span>${fmt(fris)} L</div>` : '',
      afval ? `<div><span>Afvalkosten</span>€${fmt(afval)}</div>` : '',
      dekking ? `<div><span>Verzekeringsdekking</span>${dekking}</div>` : '',
    ].filter(Boolean);
    if (!items.length) { statsCard.style.display = 'none'; return; }
    statsKv.innerHTML = items.join('');
    statsCard.style.display = 'block';
  },

  _loadedProfile: {},
  openProfileEdit(){
    const p = this._loadedProfile || {};
    const sp = STATE.profile || {};
    const acc = STATE.account || {};
    document.getElementById('pf_company').value  = p.company_name   || acc.companyName   || '';
    document.getElementById('pf_contact').value  = p.contact_person || acc.contactPerson || '';
    document.getElementById('pf_email').value    = CURRENT_USER?.email || '';
    document.getElementById('pf_phone').value    = p.phone          || acc.phone         || '';
    const storedType = p.business_type || sp.businessType || '';
    const storedOther = storedType.match(/^Overig\s*[—-]\s*(.+)$/);
    document.getElementById('pf_type').value = storedOther ? 'Overig' : storedType;
    document.getElementById('pf_type_other').value = storedOther ? storedOther[1] : '';
    document.getElementById('pf_city').value     = p.city           || sp.city           || '';
    this.toggleOtherBusinessType();
    document.getElementById('pf_kvk').value      = p.kvk_number     || acc.kvkNumber     || '';
    document.getElementById('dashProfileSaveStatus').textContent = '';
    document.getElementById('dashProfileView').style.display = 'none';
    document.getElementById('dashProfileEdit').style.display = 'block';
  },
  closeProfileEdit(){
    document.getElementById('dashProfileView').style.display = 'block';
    document.getElementById('dashProfileEdit').style.display = 'none';
  },
  async saveProfile(){
    if (!CURRENT_USER) return;
    const statusEl = document.getElementById('dashProfileSaveStatus');
    statusEl.style.color = 'var(--ink)';
    statusEl.textContent = 'Opslaan…';
    const payload = {
      email:          CURRENT_USER.email,
      company_name:   document.getElementById('pf_company').value.trim(),
      contact_person: document.getElementById('pf_contact').value.trim(),
      phone:          document.getElementById('pf_phone').value.trim(),
       business_type:  document.getElementById('pf_type').value === 'Overig' && document.getElementById('pf_type_other').value.trim()
         ? `Overig — ${document.getElementById('pf_type_other').value.trim()}`
         : document.getElementById('pf_type').value,
      city:           document.getElementById('pf_city').value.trim(),
      kvk_number:     document.getElementById('pf_kvk').value.trim(),
      updated_at:     new Date().toISOString(),
    };
    const { error } = await sb.from('profiles').upsert(payload, { onConflict: 'email' });
    if (error) {
      statusEl.style.color = 'var(--danger-ink)';
      statusEl.textContent = 'Opslaan mislukt: ' + error.message;
      return;
    }
    this._loadedProfile = payload;
    // Also update STATE for consistency
    STATE.account.companyName   = payload.company_name;
    STATE.account.contactPerson = payload.contact_person;
    STATE.account.phone         = payload.phone;
    STATE.profile.businessType  = payload.business_type;
    STATE.profile.city          = payload.city;
    saveState();
    const uploadName = document.getElementById('docUploadName');
    if (uploadName) uploadName.value = payload.contact_person;
    this.closeProfileEdit();
    this.renderProfiel();
    // Update company name in header
    const nameEl = document.getElementById('dashCompanyName');
    if (nameEl && payload.company_name) nameEl.textContent = payload.company_name;
  },
  toggleOtherBusinessType(){
    const field = document.getElementById('pfTypeOtherField');
    const type = document.getElementById('pf_type')?.value;
    if (field) field.style.display = type === 'Overig' ? '' : 'none';
  },

  _stagedFiles: [],
  _subgroupOptions(){
    return `<option value="">— Geen / onbekend —</option>` +
      SUBGROUPS.map(s=>`<option value="${s.id}">${s.name}</option>`).join("");
  },
  stageFiles(input){
    const files = Array.from(input.files || []);
    if(!files.length) return;
    this._stagedFiles = files;
    const defaultSg = primarySubgroupId() || "";
    const opts = this._subgroupOptions();
    document.getElementById("docStagingBody").innerHTML = files.map((f, i) => `
      <tr>
        <td style="font-size:13px">${f.name}</td>
        <td><select id="docStagingSg_${i}" style="width:100%;padding:8px 10px;border:1px solid #cfd3c6;border-radius:var(--r-sm);font-size:13px">${opts}</select></td>
      </tr>`).join("");
    files.forEach((_, i) => {
      document.getElementById(`docStagingSg_${i}`).value = defaultSg;
    });
    document.getElementById("docStagingArea").style.display = "block";
    document.getElementById("docUploadBox").classList.add("filled");
    document.getElementById("docUploadBoxText").textContent = `${files.length} bestand(en) geselecteerd`;
    document.getElementById("docUploadStatus").textContent = "";
  },
  clearStaging(){
    this._stagedFiles = [];
    document.getElementById("docStagingArea").style.display = "none";
    document.getElementById("docUploadBox").classList.remove("filled");
    document.getElementById("docUploadBoxText").textContent = "Klik om bestand(en) te selecteren (factuur, contract, jaarafrekening of offerte)";
    document.getElementById("docFileInput").value = "";
    document.getElementById("docUploadStatus").textContent = "";
  },
  async submitStagedFiles(){
    const name = document.getElementById("docUploadName").value.trim();
    const email = document.getElementById("docUploadEmail").value.trim().toLowerCase();
    const statusEl = document.getElementById("docUploadStatus");

    if(!email){
      statusEl.style.color = "var(--danger-ink)";
      statusEl.textContent = "Vul je e-mailadres in voordat je uploadt.";
      return;
    }

    statusEl.style.color = "var(--ink)";
    statusEl.textContent = "Bezig met uploaden…";

    try {
      let totalTransactions = 0;
      let processingIssues = 0;
      const { data: verifiedRows } = await sb.from('transactions')
        .select('raw_data').eq('email', email);
      const verifiedNames = new Set((verifiedRows || [])
        .filter(row => row.raw_data?.source_verified === true && row.raw_data?.source_file)
        .map(row => row.raw_data.source_file));
      for(let i = 0; i < this._stagedFiles.length; i++){
        const file = this._stagedFiles[i];
        const subgroup = document.getElementById(`docStagingSg_${i}`).value || null;
        const filePath = await uploadToSupabase(file, name || null, email, subgroup);
        if(!STATE.uploadFileName) STATE.uploadFileName = file.name;
        if (/\.xlsx?$/i.test(file.name)) {
          const result = await parseAndSaveExcel(file, email, name);
          totalTransactions += result.aantal;
        } else if (/\.pdf$/i.test(file.name) && !verifiedNames.has(file.name)) {
          try {
            const { error } = await sb.functions.invoke('extract-pdf', { body: { file_path: filePath, email, name: name || null } });
            if(error) processingIssues++;
          } catch (_) { processingIssues++; }
        }
      }
      const txMsg = totalTransactions > 0 ? ` ${totalTransactions} transactieregels opgeslagen.` : '';
      // Capture before clearStaging empties the list
      const uploadedNames = this._stagedFiles.map(f => f.name);
      const uploadedCount = this._stagedFiles.length;
      statusEl.style.color = "var(--positive-ink)";
      statusEl.textContent = `${uploadedCount} bestand(en) succesvol geüpload.${txMsg}${processingIssues ? ' Bij enkele documenten moet de verwerking nog worden gecontroleerd.' : ' Bekijk het overzicht voor de controle op boekjaar 2025.'}`;
      this.clearStaging();
      saveState();
      await this.render();
      sb.functions.invoke('send-upload-confirmation', { body: { email, name, fileNames: uploadedNames, fileCount: uploadedCount } });
    } catch(err) {
      statusEl.style.color = "var(--danger-ink)";
      statusEl.textContent = "Upload mislukt: " + err.message;
    }
  }
};

function renderAuthTable(){ /* legacy — vervangen door AuthModule */ }

/* =========================================================
   AuthModule — machtigingen per databron
   ========================================================= */
const AuthModule = {
  _sources: [],
  _authorizations: [],

  async loadAndRender() {
    const grid = document.getElementById('authSourceGrid');
    const histCard = document.getElementById('authHistoryCard');
    if (!grid) return;

    // Load data sources
    const { data: sources } = await sb.from('data_sources')
      .select('*').eq('is_active', true).order('sort_order');
    this._sources = sources || [];

    if (!CURRENT_USER) {
      grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1">
        <a onclick="AuthUI.openLogin()" style="cursor:pointer;text-decoration:underline;color:var(--brand2)">Log in</a> om je machtigingen te beheren.
      </div>`;
      if (histCard) histCard.style.display = 'none';
      return;
    }

    // Load active authorizations for this user
    const { data: auths } = await sb.from('authorizations')
      .select('*')
      .eq('email', CURRENT_USER.email)
      .order('granted_at', { ascending: false });
    this._authorizations = auths || [];

    // Render source cards
    grid.innerHTML = this._sources.map(s => {
      const auth = this._authorizations.find(a => a.data_source_id === s.id && a.status === 'active');
      const revoked = this._authorizations.find(a => a.data_source_id === s.id && a.status === 'revoked');
      if (auth) {
        const until = new Date(auth.expires_at).toLocaleDateString('nl-NL');
        return `<div class="auth-source-card active">
          <div class="auth-source-info">
            <strong>${s.name}</strong>
            <p style="color:var(--positive-ink)">${s.description}</p>
            <div class="auth-source-meta">Verleend op ${new Date(auth.granted_at).toLocaleDateString('nl-NL')} · Geldig tot ${until}</div>
            <div class="auth-id">${auth.id}</div>
          </div>
          <div style="display:flex;flex-direction:column;gap:8px;flex-shrink:0">
            <span class="badge b-green">Actief</span>
            <button class="btn btn-ghost btn-sm" style="color:var(--danger-ink);border-color:var(--danger-ink);font-size:12px" onclick="AuthModule.openRevoke('${auth.id}','${s.name}')">Intrekken</button>
          </div>
        </div>`;
      } else if (revoked) {
        return `<div class="auth-source-card revoked">
          <div class="auth-source-info">
            <strong>${s.name}</strong>
            <p>${s.description}</p>
            <div class="auth-source-meta">Ingetrokken op ${new Date(revoked.revoked_at).toLocaleDateString('nl-NL')}</div>
          </div>
          <div style="display:flex;flex-direction:column;gap:8px;flex-shrink:0">
            <span class="badge b-grey">Ingetrokken</span>
            <button class="btn btn-primary btn-sm" onclick="AuthModule.openGrant('${s.id}')">Opnieuw machtigen</button>
          </div>
        </div>`;
      } else {
        return `<div class="auth-source-card">
          <div class="auth-source-info">
            <strong>${s.name}</strong>
            <p>${s.description}</p>
            <div class="auth-source-meta">${s.permissions.map(p=>`<span class="tag">${p}</span>`).join(' ')}</div>
          </div>
          <div style="flex-shrink:0">
            <button class="btn btn-primary btn-sm" onclick="AuthModule.openGrant('${s.id}')">Machtigen</button>
          </div>
        </div>`;
      }
    }).join('');

    // Render audit trail
    const { data: events } = await sb.from('authorization_events')
      .select('*')
      .eq('email', CURRENT_USER.email)
      .order('created_at', { ascending: false })
      .limit(30);

    if (events && events.length) {
      histCard.style.display = 'block';
      document.getElementById('authEventList').innerHTML = events.map(e => {
        const dotClass = e.event_type.toLowerCase();
        const date = new Date(e.created_at).toLocaleString('nl-NL');
        const labels = { GRANTED:'Machtiging verleend', REVOKED:'Machtiging ingetrokken', UPDATED:'Machtiging gewijzigd', EXPIRED:'Machtiging verlopen', SUPERSEDED:'Vervangen door nieuwe machtiging' };
        return `<div class="audit-row">
          <div class="audit-dot ${dotClass}"></div>
          <div>
            <strong style="font-size:13px">${labels[e.event_type]||e.event_type}</strong>
            ${e.authorization_id ? `<span class="auth-id" style="margin-left:6px">${e.authorization_id}</span>` : ''}
            ${e.note ? `<div style="color:var(--muted);font-size:12px;margin-top:2px">${e.note}</div>` : ''}
            <div style="color:var(--muted);font-size:12px;margin-top:2px">${date}</div>
          </div>
        </div>`;
      }).join('');
    } else {
      histCard.style.display = 'none';
    }
  },

  openGrant(sourceId) {
    const source = this._sources.find(s => s.id === sourceId);
    if (!source) return;
    const el = document.getElementById('authGrantContent');
    el.innerHTML = `
      <h2 style="font-size:20px;margin-bottom:4px">Machtigen — ${source.name}</h2>
      <p style="margin-bottom:18px;font-size:13.5px">Horeca United mag namens jouw onderneming de onderstaande gegevens opvragen bij <strong>${source.name}</strong> voor: <em>${source.purpose}</em>.</p>
      <div class="note" style="margin-bottom:18px;font-size:13px">
        <strong>Wat wordt opgehaald:</strong> ${source.permissions.join(', ')}<br>
        <strong>Doel:</strong> ${source.purpose}<br>
        <strong>Reikwijdte:</strong> facturen, inkoop- en afnamegegevens, jaaroverzichten, prijs- en kortingsafspraken, lopende contracten, abonnementen, contractvoorwaarden, looptijden, einddata en opzegtermijnen, voor zover deze binnen de hierboven genoemde gegevens en het doel van deze specifieke machtiging vallen.<br><strong>Bevoegdheid:</strong> alleen gegevens opvragen, ontvangen en verwerken; geen overeenkomsten aangaan, wijzigen of opzeggen, leveranciers wijzigen, betalingen uitvoeren of bestellingen plaatsen zonder afzonderlijke toestemming.<br><strong>Geldigheid:</strong> maximaal 365 dagen · op elk moment intrekbaar
      </div>
      <div class="grid2">
        <div class="field"><label for="grantName">Naam tekenbevoegde</label><input type="text" id="grantName" placeholder="Bijv. Jan de Vries" value="${STATE.account.contactPerson||''}"></div>
        <div class="field"><label for="grantRole">Functie</label><input type="text" id="grantRole" placeholder="Bijv. eigenaar" value=""></div>
        <div class="field"><label for="grantCompany">Bedrijfsnaam</label><input type="text" id="grantCompany" placeholder="Bijv. Restaurant 't Volk B.V." value="${STATE.account.companyName||''}"></div>
        <div class="field"><label for="grantKvk">KvK-nummer</label><input type="text" id="grantKvk" placeholder="8 cijfers" value="${STATE.authorization?.kvk||''}"></div>
      </div>
      <div class="consent-row" style="margin-top:8px">
        <input type="checkbox" id="grantConsent">
        <label for="grantConsent">Ik verklaar tekenbevoegd te zijn en machtig Horeca United B.V. om namens mijn onderneming gegevens op te vragen bij <strong>${source.name}</strong>, uitsluitend voor de hierboven omschreven gegevens en het doel van deze specifieke machtiging. Ik kan deze machtiging op elk moment intrekken; zij eindigt uiterlijk na 365 dagen. <span class="req">verplicht</span></label>
      </div>
      <div class="error-text" id="grantError" style="display:none;margin-top:8px"></div>
      <div class="actions" style="margin-top:16px">
        <button class="btn btn-primary" onclick="AuthModule.confirmGrant('${sourceId}')">Bevestigen en machtigen</button>
        <button class="btn btn-ghost" onclick="AuthModule.closeGrant()">Annuleren</button>
      </div>`;
    document.getElementById('authGrantModal').classList.add('active');
  },

  async confirmGrant(sourceId) {
    const name = document.getElementById('grantName').value.trim();
    const role = document.getElementById('grantRole').value.trim();
    const company = document.getElementById('grantCompany').value.trim();
    const kvk = document.getElementById('grantKvk').value.trim();
    const consent = document.getElementById('grantConsent').checked;
    const errEl = document.getElementById('grantError');

    if (!name || !company || !kvk || !consent) {
      errEl.textContent = 'Vul alle verplichte velden in en bevestig de machtiging.';
      errEl.style.display = 'block';
      return;
    }
    if (!/^\d{8}$/.test(kvk.replace(/\s/g,''))) {
      errEl.textContent = 'KvK-nummer moet 8 cijfers zijn.';
      errEl.style.display = 'block';
      return;
    }
    errEl.style.display = 'none';

    const btn = document.querySelector('#authGrantContent .btn-primary');
    btn.disabled = true; btn.textContent = 'Opslaan…';

    const now = new Date();
    const seq = String(Math.floor(Math.random()*99999)).padStart(5,'0');
    const authId = `AUTH-${sourceId.toUpperCase()}-${now.getFullYear()}${String(now.getMonth()+1).padStart(2,'0')}${String(now.getDate()).padStart(2,'0')}-${seq}`;
    const source = this._sources.find(s => s.id === sourceId);
    const email = CURRENT_USER.email;

    const { error } = await sb.from('authorizations').insert({
      id: authId,
      user_id: CURRENT_USER.id,
      email,
      company_name: company,
      kvk_number: kvk,
      signatory_name: name,
      signatory_role: role,
      data_source_id: sourceId,
      permissions: source.permissions,
      purpose: source.purpose,
      status: 'active',
      document_version: 'v1.0',
      validity_days: 365
    });

    if (error) {
      errEl.textContent = 'Opslaan mislukt: ' + error.message;
      errEl.style.display = 'block';
      btn.disabled = false; btn.textContent = 'Bevestigen en machtigen';
      return;
    }

    await sb.from('authorization_events').insert({
      authorization_id: authId,
      email,
      event_type: 'GRANTED',
      actor: 'user',
      new_values: { company_name: company, kvk_number: kvk, signatory_name: name, data_source_id: sourceId },
      note: `Machtiging verleend voor ${source.name} door ${name} (${role||'—'})`
    });

    this.closeGrant();
    await this.loadAndRender();
  },

  closeGrant() {
    document.getElementById('authGrantModal').classList.remove('active');
  },

  openRevoke(authId, sourceName) {
    document.getElementById('authRevokeContent').innerHTML = `
      <h2 style="font-size:20px;margin-bottom:8px">Machtiging intrekken</h2>
      <p>Weet je zeker dat je de machtiging voor <strong>${sourceName}</strong> wilt intrekken?</p>
      <div class="note-strong" style="margin:14px 0;font-size:13px">
        Intrekking betekent dat Horeca United geen nieuwe gegevens meer mag opvragen bij ${sourceName}. Reeds ontvangen gegevens blijven bewaard conform de bewaartermijnen.
      </div>
      <div class="field">
        <label for="revokeReason">Reden <span class="hint">(optioneel)</span></label>
        <input type="text" id="revokeReason" placeholder="Bijv. niet meer relevant">
      </div>
      <div class="actions" style="margin-top:16px">
        <button class="btn btn-ghost btn-sm" style="color:var(--danger-ink);border-color:var(--danger-ink)" onclick="AuthModule.confirmRevoke('${authId}','${sourceName}')">Ja, intrekken</button>
        <button class="btn btn-ghost" onclick="AuthModule.closeRevoke()">Annuleren</button>
      </div>`;
    document.getElementById('authRevokeModal').classList.add('active');
  },

  async confirmRevoke(authId, sourceName) {
    const reason = document.getElementById('revokeReason')?.value.trim() || null;
    const email = CURRENT_USER.email;

    const { error } = await sb.from('authorizations').update({
      status: 'revoked',
      revoked_at: new Date().toISOString(),
      revoked_reason: reason
    }).eq('id', authId).eq('email', email);

    if (error) { alert('Intrekken mislukt: ' + error.message); return; }

    await sb.from('authorization_events').insert({
      authorization_id: authId,
      email,
      event_type: 'REVOKED',
      actor: 'user',
      note: reason ? `Reden: ${reason}` : `Machtiging voor ${sourceName} ingetrokken`
    });

    this.closeRevoke();
    await this.loadAndRender();
  },

  closeRevoke() {
    document.getElementById('authRevokeModal').classList.remove('active');
  }
};

// Close modals on backdrop click
document.getElementById('authGrantModal').addEventListener('click', e => { if(e.target.id==='authGrantModal') AuthModule.closeGrant(); });
document.getElementById('authRevokeModal').addEventListener('click', e => { if(e.target.id==='authRevokeModal') AuthModule.closeRevoke(); });

/* ---------------- Lead scoring ---------------- */
function leadScore(company){
  let score = 0;
  score += Math.min(30, (company.annualCosts/2000));
  score += Math.min(15, company.subgroupCount*2);
  score += company.hasDocument ? 12 : 0;
  score += company.contractSoon ? 10 : 0;
  score += company.willingness==="ja" ? 12 : (company.willingness==="misschien" ? 6 : 0);
  score += company.multiAnalysis ? 6 : 0;
  return Math.max(0, Math.min(100, Math.round(score)));
}
function leadLabel(score){
  if(score>=85) return ["Conversieklaar","b-green"];
  if(score>=70) return ["Hoge prioriteit","b-green"];
  if(score>=50) return ["Kansrijk","b-yellow"];
  if(score>=30) return ["Nieuw","b-grey"];
  return ["Koud","b-grey"];
}

/* ---------------- Proposals (voorstel-flow) ---------------- */
const Proposals = {
  _opportunity: null,
  _totalOverspend: 0,

  showCTA(opportunity, totalOverspend) {
    const card = document.getElementById('dashProposalCard');
    if (!card) return;
    if (!opportunity || totalOverspend < 100) { card.style.display = 'none'; return; }
    this._opportunity = opportunity;
    this._totalOverspend = totalOverspend;
    const fmt = v => new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',maximumFractionDigits:0}).format(v);
    document.getElementById('dashProposalTitle').textContent =
      `Wij kunnen jou ${fmt(totalOverspend)} besparen op ${opportunity.category}`;
    document.getElementById('dashProposalDesc').textContent =
      `Je betaalt ${opportunity.diff.toFixed(0)}% meer dan het groepsgemiddelde voor ${opportunity.category} (${opportunity.unitLabel}). ` +
      `Via Horeca United onderhandelen we collectief voor betere tarieven.`;
    document.getElementById('dashProposalSaving').textContent = fmt(totalOverspend);
    document.getElementById('dashProposalStatus').style.display = 'none';
    card.style.display = 'block';
  },

  async registerInterest() {
    if (!CURRENT_USER || !this._opportunity) return;
    const btn = document.querySelector('#dashProposalCard .btn-primary');
    if (btn) { btn.disabled = true; btn.textContent = 'Bezig…'; }
    const { error } = await sb.from('proposals').insert({
      email: CURRENT_USER.email,
      category: this._opportunity.category,
      user_unit_price: this._opportunity.unitPrice,
      benchmark_unit_price: this._opportunity.avgPrice,
      estimated_saving: Math.round(this._totalOverspend),
      status: 'interested',
    });
    const statusEl = document.getElementById('dashProposalStatus');
    statusEl.style.display = 'block';
    if (error) {
      statusEl.style.color = 'var(--danger-ink)';
      statusEl.textContent = 'Er ging iets mis: ' + error.message;
      if (btn) { btn.disabled = false; btn.textContent = 'Ja, stuur mij een voorstel'; }
    } else {
      statusEl.style.color = 'var(--positive-ink)';
      statusEl.textContent = 'Geregistreerd! Wij nemen binnen 2 werkdagen contact met je op.';
      if (btn) btn.remove();
      sb.functions.invoke('notify-proposal', { body: {
        email: CURRENT_USER.email,
        categories: [this._opportunity.category],
        type: 'benchmark_interest',
        estimatedSaving: Math.round(this._totalOverspend),
      }});
    }
  },

  async registerInterestContracts(categories, triggerBtn) {
    if (!CURRENT_USER) return;
    const rows = Array.isArray(categories) ? categories : [categories];
    if (triggerBtn) { triggerBtn.disabled = true; triggerBtn.textContent = 'Bezig…'; }
    const inserts = rows.map(cat => ({
      email: CURRENT_USER.email,
      category: cat,
      status: 'contract_interest',
    }));
    const { error } = await sb.from('proposals').insert(inserts);
    if (error) {
      if (triggerBtn) { triggerBtn.disabled = false; triggerBtn.textContent = 'Voorstel'; }
      alert('Er ging iets mis: ' + error.message);
    } else {
      if (triggerBtn) { triggerBtn.textContent = 'Aangevraagd ✓'; }
      sb.functions.invoke('notify-proposal', { body: {
        email: CURRENT_USER.email,
        categories: rows,
        type: 'contract_interest',
      }});
      const kansenBanner = document.getElementById('dashContractenKansenBanner');
      if (kansenBanner) {
        let note = kansenBanner.querySelector('.kansen-note');
        if (!note) { note = document.createElement('p'); note.className = 'kansen-note'; kansenBanner.appendChild(note); }
        note.style.cssText = 'margin:8px 0 0;font-size:13px;color:var(--positive-ink)';
        note.textContent = `Interesse geregistreerd voor: ${rows.join(', ')}. We nemen contact op!`;
      }
    }
  },
};

/* ---------------- Admin demo dataset ---------------- */
const DEMO_COMPANIES = [
  {name:"Restaurant Het Stadshuis", type:"Restaurant", city:"Arnhem", locations:"1", firstSubgroup:"Energie", subgroupCount:4, annualCosts:64000, potentialLow:3000, potentialHigh:8000, willingness:"ja", hasDocument:true, contractSoon:true, multiAnalysis:true, phase:"Actieve pilotklant"},
  {name:"Brasserie De Kade", type:"Café", city:"Nijmegen", locations:"1", firstSubgroup:"Wijn", subgroupCount:1, annualCosts:9500, potentialLow:1200, potentialHigh:3000, willingness:"misschien", hasDocument:false, contractSoon:false, multiAnalysis:false, phase:"Nieuwe lead"},
  {name:"Hotel Stadspoort", type:"Hotel", city:"Utrecht", locations:"2", firstSubgroup:"Afval", subgroupCount:6, annualCosts:142000, potentialLow:8000, potentialHigh:18000, willingness:"ja", hasDocument:true, contractSoon:true, multiAnalysis:true, phase:"Multi-subgroepklant"},
  {name:"Café De Hoek", type:"Café", city:"Apeldoorn", locations:"1", firstSubgroup:"Bier", subgroupCount:2, annualCosts:21000, potentialLow:1500, potentialHigh:4200, willingness:"nee", hasDocument:false, contractSoon:false, multiAnalysis:false, phase:"Quick Scan gestart"},
  {name:"Lunchroom Aan Tafel", type:"Lunchroom", city:"Zwolle", locations:"1", firstSubgroup:"Foodgroothandel", subgroupCount:3, annualCosts:38000, potentialLow:2200, potentialHigh:5600, willingness:"misschien", hasDocument:true, contractSoon:false, multiAnalysis:false, phase:"Kansrijke lead"},
  {name:"Bistro Noord", type:"Restaurant", city:"Amsterdam", locations:"1", firstSubgroup:"Verzekeringen", subgroupCount:5, annualCosts:97000, potentialLow:5000, potentialHigh:12500, willingness:"ja", hasDocument:true, contractSoon:true, multiAnalysis:true, phase:"Conversieklaar"},
  {name:"Grand Café Marktzicht", type:"Café", city:"Breda", locations:"1", firstSubgroup:"Internet en telefonie", subgroupCount:2, annualCosts:26000, potentialLow:1400, potentialHigh:3400, willingness:"misschien", hasDocument:false, contractSoon:false, multiAnalysis:false, phase:"Nieuwe lead"},
  {name:"Eetcafé De Brug", type:"Café", city:"Deventer", locations:"1", firstSubgroup:"Schoonmaak", subgroupCount:1, annualCosts:14000, potentialLow:900, potentialHigh:2600, willingness:"nee", hasDocument:false, contractSoon:false, multiAnalysis:false, phase:"Quick Scan gestart"},
  {name:"Hotel Van Der Linde", type:"Hotel", city:"Groningen", locations:"3 – 5", firstSubgroup:"Energie", subgroupCount:8, annualCosts:210000, potentialLow:12000, potentialHigh:26000, willingness:"ja", hasDocument:true, contractSoon:true, multiAnalysis:true, phase:"Actieve Horeca United-klant"},
  {name:"Cafetaria 't Pleintje", type:"Cafetaria / fastservice", city:"Enschede", locations:"1", firstSubgroup:"Diepvries", subgroupCount:1, annualCosts:31000, potentialLow:1800, potentialHigh:4400, willingness:"misschien", hasDocument:false, contractSoon:false, multiAnalysis:false, phase:"Nieuwe lead"},
];

const AdminApp = {
  open(){ this.buildLeads(); this.renderKpis(); this.renderLeads(); this.showTab('leads'); Router.go("admin"); },
  showTab(tab) {
    document.getElementById('admTab-machtigingen').style.display = tab === 'machtigingen' ? 'block' : 'none';
    // leads tab elements are always shown unless machtigingen is active
    const leadsEls = ['admLeadTable','admEmpty'].map(id => document.getElementById(id)).filter(Boolean);
    leadsEls.forEach(el => el.closest('.panel') && (el.closest('.panel').style.display = tab === 'leads' ? '' : 'none'));
    document.querySelectorAll('#screen-admin .side-nav a').forEach(a => a.classList.remove('active'));
    const idx = tab === 'leads' ? 0 : 1;
    document.querySelectorAll('#screen-admin .side-nav a')[idx]?.classList.add('active');
    if (tab === 'machtigingen') this.loadAuthorizationsTab();
  },
  async loadAuthorizationsTab() {
    const el = document.getElementById('admAuthContent');
    el.innerHTML = '<div class="empty-state">Laden…</div>';
    const { data: auths, error } = await sb.from('authorizations')
      .select('*, data_sources(name)')
      .order('granted_at', { ascending: false })
      .limit(200);
    if (error) { el.innerHTML = `<div class="empty-state" style="color:var(--danger-ink)">Fout: ${error.message}</div>`; return; }
    if (!auths || !auths.length) { el.innerHTML = '<div class="empty-state">Geen machtigingen gevonden.</div>'; return; }
    const statusBadge = s => ({ active:'b-green', revoked:'b-grey', expired:'b-red', superseded:'b-yellow' }[s]||'b-grey');
    const statusLabel = s => ({ active:'Actief', revoked:'Ingetrokken', expired:'Verlopen', superseded:'Vervangen' }[s]||s);
    el.innerHTML = `<table class="table">
      <thead><tr><th>Bedrijf</th><th>E-mail</th><th>Databron</th><th>Machtigings-ID</th><th>Verleend op</th><th>Geldig tot</th><th>Status</th></tr></thead>
      <tbody>${auths.map(a => `<tr>
        <td>${a.company_name||'—'}</td>
        <td style="font-size:12.5px;color:var(--muted)">${a.email}</td>
        <td>${a.data_sources?.name||a.data_source_id}</td>
        <td><span class="auth-id">${a.id}</span></td>
        <td style="font-size:12.5px">${new Date(a.granted_at).toLocaleDateString('nl-NL')}</td>
        <td style="font-size:12.5px">${a.expires_at ? new Date(a.expires_at).toLocaleDateString('nl-NL') : '—'}</td>
        <td><span class="badge ${statusBadge(a.status)}">${statusLabel(a.status)}</span></td>
      </tr>`).join('')}</tbody>
    </table>`;
  },
  leads: [],
  buildLeads(){
    // merge demo companies with the user's own quick-scan entry, so it's visible in admin
    const rows = DEMO_COMPANIES.map(c=>({...c}));
    if(STATE.completed && STATE.account.companyName){
      rows.unshift({
        name: STATE.account.companyName, type: STATE.profile.businessType||"Overig", city: STATE.profile.city||"Onbekend",
        firstSubgroup: subgroupName(primarySubgroupId()),
        subgroupCount: STATE.selectedSubgroups.length, annualCosts: STATE.primary.annualSpend||6000,
        potentialLow: STATE.result?STATE.result.low:1500, potentialHigh: STATE.result?STATE.result.high:4000,
        willingness: STATE.primary.willingness||"misschien", hasDocument: STATE.method==="upload",
        contractSoon: !!STATE.primary.contractEnd, multiAnalysis: STATE.selectedSubgroups.length>1,
        phase: "Actieve pilotklant", self:true
      });
    }
    this.leads = rows.map(r=>({...r, score: leadScore(r)}));
  },
  renderKpis(){
    const totalCosts = this.leads.reduce((a,c)=>a+c.annualCosts,0);
    const avgProfile = Math.round(this.leads.reduce((a,c)=>a+Math.min(100, 30+c.subgroupCount*8),0)/this.leads.length);
    document.getElementById("admKpiTotalCosts").textContent = euro(totalCosts);
    document.getElementById("admKpiContracts").textContent = this.leads.filter(c=>c.contractSoon).length;
    document.getElementById("admKpiAvgProfile").textContent = avgProfile + "%";
    document.getElementById("admKpiActive").textContent = this.leads.filter(c=>c.phase.includes("Actieve")).length;
  },
  renderLeads(){
    const q = (document.getElementById("admSearch").value||"").toLowerCase();
    const phaseFilter = document.getElementById("admFilterPhase").value;
    const sort = document.getElementById("admSort").value;
    let rows = this.leads.filter(c=>{
      const matchQ = !q || c.name.toLowerCase().includes(q) || c.city.toLowerCase().includes(q);
      const matchPhase = !phaseFilter || c.phase===phaseFilter;
      return matchQ && matchPhase;
    });
    if(sort==="score_desc") rows.sort((a,b)=>b.score-a.score);
    if(sort==="potential_desc") rows.sort((a,b)=>b.potentialHigh-a.potentialHigh);
    if(sort==="name_asc") rows.sort((a,b)=>a.name.localeCompare(b.name));

    const willMap = {ja:"Ja", misschien:"Misschien", nee:"Nee"};
    const phaseColor = { "Quick Scan gestart":"b-grey","Nieuwe lead":"b-grey","Actieve pilotklant":"b-green","Kansrijke lead":"b-yellow","Multi-subgroepklant":"b-green","Conversieklaar":"b-green","Actieve Horeca United-klant":"b-green" };
    const tbody = document.getElementById("admLeadTable");
    tbody.innerHTML = rows.map((c,i)=>{
      const [label] = leadLabel(c.score);
      const nextAction = c.hasDocument ? "Analyse controleren" : (c.contractSoon ? "Contractmoment opvolgen" : "Uploadherinnering sturen");
      return `<tr class="clickable" onclick="AdminApp.openDetail('${encodeURIComponent(c.name)}')">
        <td><strong>${c.name}</strong>${c.self?' <span class="tag" style="margin-left:4px">jouw invoer</span>':''}</td>
        <td>${c.type}<br><span class="hint">${c.city}</span></td>
        <td>${c.firstSubgroup}</td>
        <td>${c.subgroupCount}</td>
        <td>${euro(c.annualCosts)}</td>
        <td>${euro(c.potentialLow)} – ${euro(c.potentialHigh)}</td>
        <td>${willMap[c.willingness]}</td>
        <td><span class="leadscore"><span class="leadscore-bar"><div style="width:${c.score}%"></div></span>${c.score} · ${label}</span></td>
        <td><span class="badge ${phaseColor[c.phase]||'b-grey'}">${c.phase}</span></td>
        <td>${nextAction}</td>
      </tr>`;
    }).join("");
    document.getElementById("admEmpty").style.display = rows.length ? "none":"block";
  },
  openDetail(nameEncoded){
    const name = decodeURIComponent(nameEncoded);
    const c = this.leads.find(x=>x.name===name);
    if(!c) return;
    const [label] = leadLabel(c.score);
    document.getElementById("detailModalContent").innerHTML = `
      <span class="pill">${c.phase}</span>
      <h2 style="margin-top:12px">${c.name}</h2>
      <p>${c.type} · ${c.city}</p>
      <div class="detail-grid">
        <div>
          <h3 style="font-size:15px">Bedrijfsprofiel</h3>
          <div class="kv">
            <div><span>Jaarlijkse kosten</span>${euro(c.annualCosts)}</div>
            <div><span>Besparingspotentieel</span>${euro(c.potentialLow)} – ${euro(c.potentialHigh)}</div>
            <div><span>Eerste subgroep</span>${c.firstSubgroup}</div>
            <div><span>Aantal subgroepen</span>${c.subgroupCount}</div>
            <div><span>Overstapbereidheid</span>${({ja:"Ja",misschien:"Misschien, bij voordeel",nee:"Nee, alleen benchmarken"})[c.willingness]}</div>
            <div><span>Document geüpload</span>${c.hasDocument?"Ja":"Nee"}</div>
          </div>
          <h3 style="font-size:15px;margin-top:18px">Interne notities</h3>
          <p style="font-size:13px">${c.self ? "Eigen invoer uit deze demo-sessie." : "Voorbeeldnotitie: contactmoment gepland, wacht op documentatie van de klant."}</p>
          <h3 style="font-size:15px">Taken</h3>
          <div class="tag-list"><span class="tag">Document opvolgen</span><span class="tag">Contractdatum verifiëren</span>${c.multiAnalysis?'<span class="tag">Collectief voorstel voorbereiden</span>':''}</div>
        </div>
        <div>
          <div class="panel stat" style="margin-bottom:10px"><span>Leadscore</span><strong>${c.score} · ${label}</strong></div>
          <div class="panel stat" style="margin-bottom:10px"><span>Geschatte commissie</span><strong>${euro((c.potentialHigh)*0.15)}</strong></div>
          <div class="panel stat"><span>Voorgestelde vervolgstap</span><strong style="font-size:14px">${c.hasDocument?"Analyse afronden":"Documenten opvragen"}</strong></div>
        </div>
      </div>
    `;
    document.getElementById("detailModal").classList.add("active");
  },
  closeDetail(){ document.getElementById("detailModal").classList.remove("active"); }
};
document.getElementById("detailModal").addEventListener("click", e=>{ if(e.target.id==="detailModal") AdminApp.closeDetail(); });

/* ---------------- Demo data controls ---------------- */
const DemoData = {
  reset(){
    if(!confirm("Weet je zeker dat je alle demo-invoer wilt resetten?")) return;
    localStorage.removeItem(STORAGE_KEY);
    STATE = defaultState();
    Router.go("landing");
  }
};

/* ---------------- Init ---------------- */
renderSubgroupOverview();
if(STATE.completed){ Engine.computeResult(); }

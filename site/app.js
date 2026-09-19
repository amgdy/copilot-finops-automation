const scopeMeta = {
  all_users: ["All users", "A hard-stop per-user cap for every licensed user."],
  user: ["Specific users", "A hard-stop per-user cap for one or more GitHub logins."],
  cost_center: ["Cost center", "An existing cost center, either with per-user caps or one collective metered cap."],
  team: ["Enterprise team", "A team resolved through its cost center; it can be per-user or collective."],
  organization: ["Organization", "A direct collective metered cap for one organization."],
  enterprise: ["Enterprise", "One collective metered cap across the enterprise."],
};
const groupedScopes = [
  ["Individual coverage", ["all_users", "user"]],
  ["Group coverage", ["cost_center", "team", "organization"]],
  ["Enterprise coverage", ["enterprise"]],
];
let config = { version: 3, budgets: [] };
let selected = -1;

const $ = (id) => document.getElementById(id);
const form = $("policy-form");

function policyLabel(policy, index) {
  return policy.name || scopeMeta[policy.scope]?.[0] || `Policy ${index + 1}`;
}

function clone(value) { return JSON.parse(JSON.stringify(value)); }

function addPolicy() {
  config.budgets.push({ scope: "all_users", amount: 0 });
  selected = config.budgets.length - 1;
  render();
}

function removePolicy() {
  config.budgets.splice(selected, 1);
  selected = Math.min(selected, config.budgets.length - 1);
  render();
}

function currentPolicy() { return config.budgets[selected]; }

function render() {
  renderList();
  renderEditor();
  renderInsights();
  renderMap();
  $("yaml-preview").textContent = toYaml(config);
}

function renderList() {
  $("policy-count").textContent = `${config.budgets.length} ${config.budgets.length === 1 ? "policy" : "policies"}`;
  $("policy-list").innerHTML = config.budgets.map((p, index) => `
    <button class="policy-item ${index === selected ? "active" : ""}" data-index="${index}">
      <strong>${escapeHtml(policyLabel(p, index))}</strong><span>${escapeHtml(scopeMeta[p.scope]?.[0] || "Unknown scope")} · $${Number.isInteger(p.amount) ? p.amount : "—"}</span>
    </button>`).join("");
  document.querySelectorAll(".policy-item").forEach((button) => button.addEventListener("click", () => {
    selected = Number(button.dataset.index); render();
  }));
  $("add-policy-empty").hidden = config.budgets.length > 0;
}

function renderEditor() {
  const policy = currentPolicy();
  const hasPolicy = Boolean(policy);
  form.hidden = !hasPolicy;
  $("empty-editor").hidden = hasPolicy;
  $("remove-policy").hidden = !hasPolicy;
  if (!hasPolicy) { $("editor-title").textContent = "Start a policy"; return; }
  $("editor-title").textContent = policyLabel(policy, selected);
  $("scope").value = policy.scope;
  $("scope-help").textContent = scopeMeta[policy.scope][1];
  ["name", "description"].forEach((key) => { $(key).value = policy[key] ?? ""; });
  $("amount").value = policy.amount ?? "";
  $("alerts").value = (policy.alerts || []).join(", ");
  renderIdentity(policy);
  renderOptions(policy);
}

function renderIdentity(policy) {
  const fields = $("identity-fields");
  const scope = policy.scope;
  const entries = {
    user: ["users", "Users", "GitHub logins, separated by commas", "octocat, monalisa"],
    cost_center: ["cost_center", "Cost center", "Existing cost center name", "engineering"],
    team: ["team", "Enterprise team", "Prefer the bare team slug", "platform-engineering"],
    organization: ["organization", "Organization", "GitHub organization login", "acme"],
  };
  if (!entries[scope]) { fields.innerHTML = ""; return; }
  const [key, label, hint, placeholder] = entries[scope];
  const value = key === "users" ? (policy[key] || []).join(", ") : policy[key] || "";
  fields.innerHTML = `<label class="wide-field">${label}<input id="${key}" data-key="${key}" placeholder="${placeholder}" value="${escapeAttr(value)}" autocomplete="off" /><span class="field-help">${hint}</span></label>`;
  fields.querySelector("input").addEventListener("input", syncForm);
}

function renderOptions(policy) {
  const scope = policy.scope;
  const supportsMetered = ["cost_center", "team", "organization"].includes(scope);
  const collectiveFixed = ["enterprise", "organization"].includes(scope);
  $("collective-options").hidden = !(supportsMetered || scope === "enterprise");
  $("metered_credits_only").parentElement.parentElement.hidden = !supportsMetered;
  $("metered_credits_only").checked = policy.metered_credits_only === true;
  const collective = collectiveFixed || policy.metered_credits_only === true;
  $("enforce-row").hidden = !collective;
  $("enforce").checked = policy.enforce !== false;
  $("shared-cost-center-row").hidden = scope !== "team";
  $("allow_shared_cost_center").checked = policy.allow_shared_cost_center === true;
}

function syncForm(event) {
  let policy = currentPolicy();
  if (!policy) return;
  const scope = $("scope").value;
  const scopeChanged = policy.scope !== scope;
  if (scopeChanged) {
    const retained = { name: policy.name, description: policy.description, amount: policy.amount, alerts: policy.alerts };
    policy = Object.assign(config.budgets[selected], { scope, amount: retained.amount ?? 0 });
    Object.keys(policy).forEach((key) => { if (!["scope", "amount", "name", "description", "alerts"].includes(key)) delete policy[key]; });
  }
  policy.name = $("name").value.trim() || undefined;
  policy.description = $("description").value.trim() || undefined;
  policy.amount = $("amount").value === "" ? undefined : Number($("amount").value);
  policy.alerts = commaList($("alerts").value);
  const identity = document.querySelector("#identity-fields input");
  if (identity) policy[identity.dataset.key] = identity.dataset.key === "users" ? commaList(identity.value) : identity.value.trim();
  if (["cost_center", "team", "organization"].includes(scope)) policy.metered_credits_only = $("metered_credits_only").checked;
  if (scope === "organization") policy.metered_credits_only = true;
  if (scope === "enterprise" || policy.metered_credits_only) policy.enforce = $("enforce").checked;
  else delete policy.enforce;
  if (scope === "team") policy.allow_shared_cost_center = $("allow_shared_cost_center").checked;
  else delete policy.allow_shared_cost_center;
  ["name", "description"].forEach((key) => { if (!policy[key]) delete policy[key]; });
  if (!policy.alerts?.length) delete policy.alerts;
  if (scopeChanged || event?.target?.id === "metered_credits_only") renderEditor();
  renderList();
  renderInsights();
  renderMap();
  $("yaml-preview").textContent = toYaml(config);
}

function renderInsights() {
  const errors = validate(config);
  const badge = $("health-badge");
  badge.textContent = errors.length ? `${errors.length} issue${errors.length === 1 ? "" : "s"}` : "Valid";
  badge.classList.toggle("error", Boolean(errors.length));
  $("validation-results").innerHTML = errors.length
    ? errors.map((error) => `<div class="validation-item">${escapeHtml(error)}</div>`).join("")
    : `<p class="valid-message">✓ This configuration follows the v3 config rules.</p>`;
  const collective = config.budgets.filter((p) => p.scope === "enterprise" || p.scope === "organization" || p.metered_credits_only).length;
  const caps = config.budgets.reduce((total, p) => total + (Number.isInteger(p.amount) ? p.amount : 0), 0);
  $("summary-stats").innerHTML = `<div class="stat"><strong>${config.budgets.length}</strong><span>policies</span></div><div class="stat"><strong>${collective}</strong><span>collective caps</span></div><div class="stat"><strong>$${caps.toLocaleString()}</strong><span>sum of caps</span></div><div class="stat"><strong>${new Set(config.budgets.map((p) => p.scope)).size}</strong><span>scope types</span></div>`;
}

function renderMap() {
  $("policy-map").innerHTML = config.budgets.length ? groupedScopes.map(([title, scopes]) => {
    const cards = config.budgets.filter((p) => scopes.includes(p.scope)).map((p, index) =>
      `<div class="map-card"><strong>${escapeHtml(policyLabel(p, index))}</strong><span>${escapeHtml(scopeMeta[p.scope][0])} · $${p.amount ?? "—"}</span></div>`).join("") || `<span class="muted">No policies here yet.</span>`;
    return `<div class="map-column"><h3>${title}</h3>${cards}</div>`;
  }).join("") : `<div class="map-placeholder">Your policy hierarchy will appear here as you add budgets.</div>`;
}

function validate(doc) {
  const errors = [];
  if (doc.version !== 3) errors.push("version must be 3.");
  if (!Array.isArray(doc.budgets)) return ["budgets must be a list."];
  const seen = { all_users: 0, enterprise: 0, cost: new Set(), org: new Set() };
  doc.budgets.forEach((p, index) => {
    const prefix = `Policy ${index + 1}`;
    if (!scopeMeta[p.scope]) errors.push(`${prefix}: choose a valid scope.`);
    if (!Number.isInteger(p.amount) || p.amount < 0) errors.push(`${prefix}: amount must be a whole USD value of 0 or more.`);
    if (p.scope === "user" && !p.users?.length) errors.push(`${prefix}: add at least one user login.`);
    if (p.scope === "cost_center" && !p.cost_center) errors.push(`${prefix}: enter an existing cost center.`);
    if (p.scope === "team" && !p.team) errors.push(`${prefix}: enter an enterprise team.`);
    if (p.scope === "organization" && !p.organization) errors.push(`${prefix}: enter an organization.`);
    if (p.scope === "all_users" && ++seen.all_users > 1) errors.push(`${prefix}: only one all-users policy is allowed.`);
    if (p.scope === "enterprise" && ++seen.enterprise > 1) errors.push(`${prefix}: only one enterprise policy is allowed.`);
    if (p.scope === "cost_center") {
      const key = `${p.cost_center}|${p.metered_credits_only === true}`;
      if (seen.cost.has(key)) errors.push(`${prefix}: this cost center already has a policy with the same cap type.`);
      seen.cost.add(key);
    }
    if (p.scope === "organization") {
      if (seen.org.has(p.organization)) errors.push(`${prefix}: this organization already has a policy.`);
      seen.org.add(p.organization);
    }
  });
  return errors;
}

function toYaml(doc) {
  const lines = ["version: 3"];
  if (!doc.budgets.length) return `${lines.join("\n")}\n`;
  lines.push("", "budgets:");
  doc.budgets.forEach((policy) => {
    const ordered = ["name", "description", "scope", "users", "cost_center", "team", "organization", "metered_credits_only", "amount", "enforce", "alerts", "allow_shared_cost_center"];
    ordered.filter((key) => policy[key] !== undefined && policy[key] !== "" && !(Array.isArray(policy[key]) && !policy[key].length)).forEach((key, i) => {
      lines.push(`  ${i ? " " : "- "}${key}: ${formatValue(policy[key])}`);
    });
  });
  return `${lines.join("\n")}\n`;
}

function formatValue(value) {
  if (Array.isArray(value)) return `[${value.map(formatValue).join(", ")}]`;
  if (typeof value === "string") return /^[A-Za-z0-9_.-]+$/.test(value) ? value : JSON.stringify(value);
  return String(value);
}
function commaList(value) { return value.split(",").map((item) => item.trim()).filter(Boolean); }
function escapeHtml(value) { return String(value).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;" })[c]); }
function escapeAttr(value) { return escapeHtml(value); }

// This intentionally supports the compact v3 YAML emitted by this editor, including
// comments, quoted strings, and inline arrays. Imported content is validated before use.
function parseYaml(text) {
  const doc = { budgets: [] }; let current;
  text.split(/\r?\n/).forEach((original, lineNumber) => {
    const line = original.replace(/\s+#.*$/, "").trimEnd();
    if (!line.trim()) return;
    if (/^version:\s*/.test(line)) { doc.version = scalar(line.split(/:\s*/, 2)[1]); return; }
    if (/^budgets:\s*$/.test(line)) return;
    const match = line.match(/^\s*(?:-\s+)?([A-Za-z_]+):\s*(.*)$/);
    if (!match) throw new Error(`Line ${lineNumber + 1} is not a supported v3 YAML field.`);
    const isStart = /^\s*-\s+/.test(line);
    if (isStart) { current = {}; doc.budgets.push(current); }
    if (!current) throw new Error(`Line ${lineNumber + 1} must appear under budgets.`);
    current[match[1]] = scalar(match[2]);
  });
  if (doc.version === undefined) throw new Error("The YAML must include version: 3.");
  return doc;
}
function scalar(value) {
  const v = value.trim();
  if (v === "true") return true; if (v === "false") return false;
  if (/^-?\d+$/.test(v)) return Number(v);
  if (v.startsWith("[") && v.endsWith("]")) return v.slice(1, -1).split(",").map((item) => scalar(item)).filter((item) => item !== "");
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) return v.slice(1, -1);
  return v;
}

document.querySelectorAll(".add-policy-trigger").forEach((button) => button.addEventListener("click", addPolicy));
$("add-policy").addEventListener("click", addPolicy);
$("add-policy-empty").addEventListener("click", addPolicy);
$("remove-policy").addEventListener("click", removePolicy);
form.addEventListener("input", syncForm);
form.addEventListener("change", syncForm);
$("new-config").addEventListener("click", () => { config = { version: 3, budgets: [] }; selected = -1; render(); });
$("copy-yaml").addEventListener("click", async () => {
  await navigator.clipboard.writeText(toYaml(config)); $("copy-yaml").textContent = "Copied!";
  setTimeout(() => { $("copy-yaml").textContent = "Copy YAML"; }, 1500);
});
$("download-config").addEventListener("click", () => {
  const url = URL.createObjectURL(new Blob([toYaml(config)], { type: "text/yaml" }));
  const link = Object.assign(document.createElement("a"), { href: url, download: "copilot-finops.yml" });
  link.click(); URL.revokeObjectURL(url);
});
$("config-file").addEventListener("change", async (event) => {
  const file = event.target.files[0]; if (!file) return;
  try { config = parseYaml(await file.text()); selected = config.budgets.length ? 0 : -1; render(); }
  catch (error) { window.alert(`Could not open this YAML file: ${error.message}`); }
  event.target.value = "";
});
render();

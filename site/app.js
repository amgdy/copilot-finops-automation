import { parseConfigYaml, serializeConfigYaml, validateStudioConfig } from "./config.js";
import { createCoverageTracker, renderCoverageHouse } from "./coverage.js";
import { createIcons, ArrowUpRight, BellRing, Building2, CircleAlert, Copy, FileCode2, House, Info, Layers3, Link2, Monitor, ShieldCheck, UserRound, UsersRound, Vault } from "lucide";

const scopeMeta = {
  all_users: ["All users", "A hard-stop per-user cap for every licensed user."],
  user: ["Specific users", "A hard-stop per-user cap for one or more GitHub logins."],
  cost_center: ["Cost center", "An existing cost center, either with per-user caps or one collective metered cap."],
  team: ["Enterprise team", "A team resolved through its cost center; it can be per-user or collective."],
  organization: ["Organization", "A direct collective metered cap for one organization."],
  enterprise: ["Enterprise", "One collective metered cap across the enterprise."],
};
let config = { version: 3, budgets: [] };
let selected = -1;

const $ = (id) => document.getElementById(id);
const form = $("policy-form");
const trackCoverage = createCoverageTracker();
const pendingCoverageMotion = new WeakMap();
let coverageObserver;

function policies() {
  return Array.isArray(config?.budgets) ? config.budgets : [];
}

function editablePolicy(policy) {
  return policy !== null && typeof policy === "object" && !Array.isArray(policy) && Boolean(scopeMeta[policy.scope]);
}

function policyLabel(policy, index) {
  if (policy === null || typeof policy !== "object" || Array.isArray(policy)) return `Policy ${index + 1}`;
  return policy.name || scopeMeta[policy.scope]?.[0] || `Policy ${index + 1}`;
}

function addPolicy() {
  if (!Array.isArray(config.budgets)) config.budgets = [];
  config.budgets.push({ scope: "all_users", amount: 0 });
  selected = config.budgets.length - 1;
  render();
}

function removePolicy() {
  policies().splice(selected, 1);
  selected = Math.min(selected, policies().length - 1);
  render();
}

function currentPolicy() { return policies()[selected]; }

function render() {
  renderList();
  renderEditor();
  renderInsights();
  renderMap();
  $("yaml-preview").textContent = serializeConfigYaml(config);
}

function renderList() {
  const items = policies();
  $("policy-count").textContent = `${items.length} ${items.length === 1 ? "policy" : "policies"}`;
  $("policy-list").innerHTML = items.map((p, index) => `
    <button class="policy-item ${index === selected ? "active" : ""}" data-index="${index}">
      <strong>${escapeHtml(policyLabel(p, index))}</strong><span>${escapeHtml(scopeMeta[p?.scope]?.[0] || "Invalid policy")} · $${Number.isInteger(p?.amount) ? p.amount : "—"}</span>
    </button>`).join("");
  document.querySelectorAll(".policy-item").forEach((button) => button.addEventListener("click", () => {
    selected = Number(button.dataset.index); render();
  }));
  $("add-policy-empty").hidden = items.length > 0;
}

function renderEditor() {
  const policy = currentPolicy();
  const hasPolicy = policy !== undefined;
  const canEdit = editablePolicy(policy);
  form.hidden = !canEdit;
  $("empty-editor").hidden = hasPolicy;
  $("invalid-editor").hidden = !hasPolicy || canEdit;
  $("remove-policy").hidden = !hasPolicy;
  if (!hasPolicy) { $("editor-title").textContent = "Start a policy"; return; }
  $("editor-title").textContent = policyLabel(policy, selected);
  if (!canEdit) return;
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
  if (!editablePolicy(policy)) return;
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
  $("yaml-preview").textContent = serializeConfigYaml(config);
}

function renderInsights() {
  const validation = validateStudioConfig(config);
  const errors = validation.errors.map((error) => error.path === "(root)" ? error.message : `${error.path}: ${error.message}`);
  const badge = $("health-badge");
  badge.textContent = errors.length ? `${errors.length} issue${errors.length === 1 ? "" : "s"}` : "Valid";
  badge.classList.toggle("error", Boolean(errors.length));
  $("validation-results").innerHTML = errors.length
    ? errors.map((error) => `<div class="validation-item">${escapeHtml(error)}</div>`).join("")
    : `<p class="valid-message">✓ This configuration follows the v3 config rules.</p>`;
  const items = policies();
  const validPolicies = items.filter(editablePolicy);
  const collective = validPolicies.filter((p) => p.scope === "enterprise" || p.scope === "organization" || p.metered_credits_only).length;
  const caps = validPolicies.reduce((total, p) => total + (Number.isInteger(p.amount) ? p.amount : 0), 0);
  $("summary-stats").innerHTML = `<div class="stat"><strong>${items.length}</strong><span>policies</span></div><div class="stat"><strong>${collective}</strong><span>collective caps</span></div><div class="stat"><strong>$${caps.toLocaleString()}</strong><span>sum of caps</span></div><div class="stat"><strong>${new Set(validPolicies.map((p) => p.scope)).size}</strong><span>scope types</span></div>`;
}

function renderMap() {
  const map = $("policy-map");
  const items = [...policies()];
  const { changed, changes } = trackCoverage(items);
  if (!changed) {
    map.querySelectorAll(".coverage-policy").forEach((button) => {
      button.setAttribute("aria-pressed", String(Number(button.dataset.policyIndex) === selected));
    });
    return;
  }
  coverageObserver?.disconnect();
  map.innerHTML = renderCoverageHouse(items, selected);
  createIcons({
    icons: { ArrowUpRight, BellRing, Building2, CircleAlert, Copy, FileCode2, House, Info, Layers3, Link2, Monitor, ShieldCheck, UserRound, UsersRound, Vault },
    attrs: { "aria-hidden": "true", focusable: "false" },
  });
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || !("IntersectionObserver" in window)) {
    items.forEach((policy) => { if (policy && typeof policy === "object") pendingCoverageMotion.delete(policy); });
    return;
  }
  changes.forEach((change, index) => {
    const policy = items[index];
    if (policy && typeof policy === "object" && pendingCoverageMotion.get(policy) !== "added") {
      pendingCoverageMotion.set(policy, change);
    }
  });
  const observer = new IntersectionObserver((entries) => {
    let order = 0;
    entries.forEach((entry) => {
      if (!entry.isIntersecting || !entry.target.isConnected) return;
      const policy = items[Number(entry.target.dataset.policyIndex)];
      const motion = pendingCoverageMotion.get(policy);
      if (motion) {
        entry.target.style.setProperty("--coverage-delay", `${motion === "added" ? Math.min(order++, 5) * 45 : 0}ms`);
        entry.target.classList.add(`coverage-${motion}`);
        pendingCoverageMotion.delete(policy);
      }
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.15 });
  coverageObserver = observer;
  map.querySelectorAll(".coverage-policy").forEach((button) => {
    if (pendingCoverageMotion.has(items[Number(button.dataset.policyIndex)])) observer.observe(button);
  });
}

function commaList(value) { return value.split(",").map((item) => item.trim()).filter(Boolean); }
function escapeHtml(value) { return String(value).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;" })[c]); }
function escapeAttr(value) { return escapeHtml(value); }

document.querySelectorAll(".add-policy-trigger").forEach((button) => button.addEventListener("click", addPolicy));
$("add-policy").addEventListener("click", addPolicy);
$("add-policy-empty").addEventListener("click", addPolicy);
$("remove-policy").addEventListener("click", removePolicy);
$("policy-map").addEventListener("click", (event) => {
  const button = event.target.closest("[data-policy-index]");
  if (!button) return;
  selected = Number(button.dataset.policyIndex);
  render();
  $("editor-title").focus({ preventScroll: true });
  $("editor-title").scrollIntoView({ block: "center", behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth" });
});
form.addEventListener("input", syncForm);
form.addEventListener("change", syncForm);
$("new-config").addEventListener("click", () => { config = { version: 3, budgets: [] }; selected = -1; render(); });
$("copy-yaml").addEventListener("click", async () => {
  await navigator.clipboard.writeText(serializeConfigYaml(config)); $("copy-yaml").textContent = "Copied!";
  setTimeout(() => { $("copy-yaml").textContent = "Copy YAML"; }, 1500);
});
$("copy-action").addEventListener("click", async () => {
  $("action-copy-status").textContent = "";
  try {
    await navigator.clipboard.writeText($("action-example").textContent);
    $("action-copy-status").textContent = "Workflow copied.";
  } catch {
    $("action-copy-status").textContent = "Could not copy the workflow. Clipboard access is unavailable.";
  }
});
$("download-config").addEventListener("click", () => {
  const url = URL.createObjectURL(new Blob([serializeConfigYaml(config)], { type: "text/yaml" }));
  const link = Object.assign(document.createElement("a"), { href: url, download: "copilot-finops.yml" });
  link.click(); URL.revokeObjectURL(url);
});
$("config-file").addEventListener("change", async (event) => {
  const file = event.target.files[0]; if (!file) return;
  try { config = parseConfigYaml(await file.text(), file.name); selected = policies().length ? 0 : -1; render(); }
  catch (error) { window.alert(`Could not open this YAML file: ${error.message}`); }
  event.target.value = "";
});
render();

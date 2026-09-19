const scopeLabels = {
  enterprise: "Enterprise cap",
  all_users: "All-user default",
  organization: "Organization cap",
  cost_center: "Cost center cap",
  team: "Team cap",
  user: "Individual cap",
};

export function createCoverageTracker() {
  let previous = new Map();
  let lastSignature = null;

  return (budgets) => {
    const items = Array.isArray(budgets) ? budgets : [];
    const signature = JSON.stringify(items);
    const next = new Map();
    const changes = new Map();
    items.forEach((policy, index) => {
      const value = JSON.stringify(policy);
      if (!previous.has(policy)) changes.set(index, "added");
      else if (previous.get(policy) !== value) changes.set(index, "updated");
      next.set(policy, value);
    });
    const changed = signature !== lastSignature;
    previous = next;
    lastSignature = signature;
    return { changed, changes };
  };
}

export function createCoverageModel(budgets) {
  const model = { enterprise: [], baseline: [], people: [], groups: [], unplaced: [] };
  const groups = new Map();

  if (!Array.isArray(budgets)) return model;
  budgets.forEach((budget, index) => {
    if (!budget || typeof budget !== "object" || !Object.hasOwn(scopeLabels, budget.scope)) {
      model.unplaced.push({ index, name: `Policy ${index + 1}` });
      return;
    }
    const collective = budget.scope === "enterprise" || budget.scope === "organization"
      || (["cost_center", "team"].includes(budget.scope) && budget.metered_credits_only === true);
    const policy = {
      index,
      scope: budget.scope,
      name: typeof budget.name === "string" && budget.name ? budget.name : scopeLabels[budget.scope],
      amount: Number.isInteger(budget.amount) && budget.amount >= 0 ? budget.amount : null,
      collective,
      enforced: !collective || budget.enforce !== false,
      shared: budget.scope === "team" && budget.allow_shared_cost_center === true,
      users: Array.isArray(budget.users) ? budget.users.filter((login) => typeof login === "string") : [],
    };

    if (budget.scope === "enterprise") model.enterprise.push(policy);
    else if (budget.scope === "all_users") model.baseline.push(policy);
    else if (budget.scope === "user") model.people.push(policy);
    else {
      const target = typeof budget[budget.scope] === "string" && budget[budget.scope]
        ? budget[budget.scope] : null;
      const key = JSON.stringify([budget.scope, target ?? index]);
      if (!groups.has(key)) {
        const group = { scope: budget.scope, target, policies: [] };
        groups.set(key, group);
        model.groups.push(group);
      }
      groups.get(key).policies.push(policy);
    }
  });

  return model;
}

const objects = {
  organization: { title: "Organizations", object: "Wing", icon: "building-2", detail: "Direct metered cap" },
  cost_center: { title: "Cost centers", object: "Vault", icon: "vault", detail: "Existing cost center" },
  team: { title: "Enterprise teams", object: "Workspace", icon: "users-round", detail: "Via its cost center" },
};

function escapeMarkup(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;",
  })[character]);
}

function icon(name) {
  return `<i data-lucide="${name}" aria-hidden="true"></i>`;
}

function policyControl(policy, selected) {
  const amount = policy.amount === null ? "Missing amount" : `$${policy.amount.toLocaleString("en-US")}`;
  const digits = policy.amount === null ? "" : policy.amount.toLocaleString("en-US");
  const amountClass = policy.amount === null ? " is-missing" : digits.length > 12 ? " is-long" : digits.length > 8 ? " is-wide" : "";
  const unit = policy.collective ? "collective" : "per user";
  const phase = policy.collective ? "Metered only" : "Pool + metered";
  const enforcement = policy.enforced ? "Hard stop" : "Alert only";
  const detail = `${amount} ${unit}. ${phase}. ${enforcement}.${policy.shared ? " Shared cost center allowed." : ""}`;
  return `<button type="button" class="coverage-policy ${policy.collective ? "is-collective" : "is-per-user"}"
    data-policy-index="${policy.index}" aria-pressed="${policy.index === selected}"
    aria-label="Edit ${escapeMarkup(policy.name)}: ${escapeMarkup(detail)}" title="${escapeMarkup(detail)}">
    <span class="coverage-policy-top"><span class="coverage-policy-name">${escapeMarkup(policy.name)}</span>${icon("arrow-up-right")}</span>
    <span class="coverage-policy-cap"><strong class="coverage-amount${amountClass}" style="--coverage-digits: ${digits.length + 2}">${policy.amount === null ? "Amount required" : `<span class="coverage-currency">$</span><span class="coverage-amount-value">${digits}</span>`}</strong><span class="coverage-cap-unit">USD <span>/ ${unit === "collective" ? "collective cap" : "user"}</span></span></span>
    <span class="coverage-policy-bottom"><span>${phase}</span><span class="coverage-enforcement ${policy.enforced ? "is-stop" : "is-alert"}">${icon(policy.enforced ? "shield-check" : "bell-ring")}${enforcement}</span></span>
    ${policy.shared ? `<span class="coverage-shared">${icon("link-2")}Shared cost center allowed</span>` : ""}
  </button>`;
}

function objectGraphic(scope) {
  return `<span class="coverage-object-art coverage-object-art--${scope}" aria-hidden="true">${icon(objects[scope].icon)}${scope === "team" ? `<span class="coverage-workbench"></span>` : ""}</span>`;
}

function groupLane(scope, model, selected) {
  const meta = objects[scope];
  const groups = model.groups.filter((group) => group.scope === scope);
  const content = groups.length ? groups.map((group) => `<div class="coverage-room coverage-room--${scope}">
    <div class="coverage-object-heading">${objectGraphic(scope)}<div>
      <span class="coverage-object-kind">${meta.object}</span>
      <h5>${escapeMarkup(group.target ?? "Missing identity")}</h5>
      <span class="coverage-caption">${meta.detail}</span>
    </div></div>
    <div class="coverage-controls">${group.policies.map((policy) => policyControl(policy, selected)).join("")}</div>
  </div>`).join("") : `<div class="coverage-room coverage-room--${scope} is-empty">
    <div class="coverage-object-heading">${objectGraphic(scope)}<div><span class="coverage-object-kind">${meta.object}</span><p>No ${scope.replace("_", " ")} budget</p></div></div>
  </div>`;

  return `<section class="coverage-lane coverage-lane--${scope}" aria-label="${meta.title}">
    <h4>${meta.title}<span title="${groups.length} configured ${meta.title.toLowerCase()}">${groups.length}</span></h4>${content}
  </section>`;
}

export function renderCoverageHouse(budgets, selected = -1) {
  const model = createCoverageModel(budgets);
  const enterprise = model.enterprise.length
    ? model.enterprise.map((policy) => policyControl(policy, selected)).join("")
    : `<p class="coverage-absent">${icon("shield-check")}No enterprise cap configured</p>`;
  const people = model.people.length ? model.people.map((policy) => `<div class="coverage-person-policy">
    <div class="coverage-desks">${policy.users.length ? policy.users.map((login) => `<div class="coverage-resident"><span class="coverage-desk" aria-hidden="true">${icon("user-round")}${icon("monitor")}</span><span>${escapeMarkup(login)}</span></div>`).join("") : `<span class="coverage-caption">Missing user logins</span>`}</div>
    ${policyControl(policy, selected)}
  </div>`).join("") : `<p class="coverage-absent">${icon("user-round")}No individual overrides</p>`;
  const baseline = model.baseline.length
    ? model.baseline.map((policy) => policyControl(policy, selected)).join("")
    : `<p class="coverage-absent">No all-user default configured</p>`;

  return `<div class="coverage-key" aria-label="Budget enforcement legend">
      <span>AI-credit caps <span class="coverage-caption">/ USD</span></span>
      <span>${icon("shield-check")}Hard stop</span><span>${icon("bell-ring")}Alert only</span>
    </div>
    <div class="coverage-house">
      <div class="coverage-roof" aria-hidden="true"><span></span></div>
      <div class="coverage-shell">
        <header class="coverage-attic">
          <div class="coverage-house-title">${icon("house")}<div><span class="coverage-object-kind">The house</span><h3>Enterprise</h3><p>Collective metered boundary</p></div></div>
          <div class="coverage-roof-controls">${enterprise}</div>
        </header>
        <div class="coverage-floor-label"><span>Group budgets</span><span title="Organization, cost center and team membership is resolved by GitHub. The config does not define parent-child relationships between these groups.">${icon("info")}Scopes may overlap</span></div>
        <div class="coverage-rooms">${["organization", "cost_center", "team"].map((scope) => groupLane(scope, model, selected)).join("")}</div>
        <section class="coverage-residents" aria-label="Specific user budgets">
          <div class="coverage-level-heading">${icon("user-round")}<div><span class="coverage-object-kind">Personal desks</span><h4>Specific users</h4><p>Individual overrides</p></div></div>
          <div class="coverage-people">${people}</div>
        </section>
        <section class="coverage-foundation" aria-label="All-user default budgets">
          <div class="coverage-level-heading">${icon("layers-3")}<div><span class="coverage-object-kind">The foundation</span><h4>All users</h4><p>Default cap for every licensed user</p></div></div>
          <div class="coverage-baseline">${baseline}</div>
        </section>
      </div>
      <div class="coverage-ground" aria-hidden="true"></div>
    </div>
    <div class="coverage-footnote">${icon("info")}Caps overlap; they are not added together. Individual budgets override the all-user and cost-center per-user defaults.</div>
    ${model.unplaced.length ? `<aside class="coverage-unplaced" aria-label="Policies with an invalid scope"><strong>${icon("circle-alert")}Unmapped policies</strong>${model.unplaced.map((policy) => `<button type="button" data-policy-index="${policy.index}" class="coverage-unplaced-policy">${escapeMarkup(policy.name)}${icon("arrow-up-right")}</button>`).join("")}</aside>` : ""}`;
}
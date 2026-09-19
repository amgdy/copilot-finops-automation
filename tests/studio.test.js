import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseConfigYaml, serializeConfigYaml, validateStudioConfig } from "../site/config.js";
import { createCoverageModel, createCoverageTracker, renderCoverageHouse } from "../site/coverage.js";

test("studio parses and validates the worked YAML example", () => {
  const raw = readFileSync(new URL("../config/copilot-finops.example.yml", import.meta.url), "utf8");
  const doc = parseConfigYaml(raw, "copilot-finops.example.yml");

  assert.equal(doc.version, 3);
  assert.equal(doc.budgets.length, 8);
  assert.equal(validateStudioConfig(doc).valid, true);
});

test("studio parser supports block lists, quoted values, and comments", () => {
  const doc = parseConfigYaml(`
# Standard YAML generated outside the studio.
version: 3
budgets:
  - scope: user
    users:
      - "octocat"
      - monalisa # inline comment
    amount: 25
`);

  assert.deepEqual(doc.budgets[0].users, ["octocat", "monalisa"]);
  assert.equal(validateStudioConfig(doc).valid, true);
});

test("studio validation reports schema-required budget fields", () => {
  const doc = parseConfigYaml(`
version: 3
budgets:
  - name: incomplete-team-budget
    scope: team
`);
  const result = validateStudioConfig(doc);

  assert.equal(result.valid, false);
  assert.ok(result.errors.some((error) => error.path === "budgets[0].amount" && /missing/.test(error.message)));
  assert.ok(result.errors.some((error) => error.path === "budgets[0].team" && /requires/.test(error.message)));
});

test("studio rejects a non-mapping YAML document", () => {
  assert.throws(() => parseConfigYaml("- one\n- two\n"), /must be a YAML mapping at the top level/);
});

test("studio serialization round-trips YAML-sensitive strings", () => {
  const doc = {
    version: 3,
    budgets: [{ scope: "user", users: ["octocat"], amount: 25, description: "FinOps: core #1" }],
  };

  assert.deepEqual(parseConfigYaml(serializeConfigYaml(doc)), doc);
});

test("coverage house places every example policy without inventing memberships", () => {
  const doc = parseConfigYaml(readFileSync(new URL("../config/copilot-finops.example.yml", import.meta.url), "utf8"));
  const before = structuredClone(doc);
  const model = createCoverageModel(doc.budgets);

  assert.equal(model.enterprise.length, 1);
  assert.equal(model.baseline.length, 1);
  assert.equal(model.people.length, 1);
  assert.deepEqual(model.people[0].users, ["octocat", "monalisa"]);
  assert.deepEqual(model.groups.map(({ scope, target, policies }) => [scope, target, policies.length]), [
    ["cost_center", "engineering", 2],
    ["team", "platform-engineering", 2],
    ["organization", "acme", 1],
  ]);
  const policies = [...model.enterprise, ...model.baseline, ...model.people, ...model.groups.flatMap((group) => group.policies)];
  assert.deepEqual(policies.map((policy) => policy.index).sort((left, right) => left - right), [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.equal(policies.filter((policy) => policy.collective).length, 4);
  assert.deepEqual(doc, before);
});

test("coverage house keeps same-named teams and cost centers separate", () => {
  const model = createCoverageModel([
    { scope: "team", team: "platform", amount: 25 },
    { scope: "cost_center", cost_center: "platform", amount: 500, metered_credits_only: true, enforce: false },
  ]);

  assert.equal(model.groups.length, 2);
  assert.equal(model.groups[0].policies[0].collective, false);
  assert.equal(model.groups[0].policies[0].enforced, true);
  assert.equal(model.groups[1].policies[0].collective, true);
  assert.equal(model.groups[1].policies[0].enforced, false);
});

test("coverage house tolerates incomplete and unrecognized policies", () => {
  assert.deepEqual(createCoverageModel(undefined), createCoverageModel([]));
  const model = createCoverageModel([null, { scope: "unknown" }, { scope: "team" }, { scope: "team" }]);

  assert.deepEqual(model.unplaced.map((policy) => policy.index), [0, 1]);
  assert.equal(model.groups.length, 2);
  assert.equal(model.groups[0].target, null);
  assert.equal(model.groups[0].policies[0].amount, null);
});

test("coverage house renders all eight example budgets as selectable controls", () => {
  const doc = parseConfigYaml(readFileSync(new URL("../config/copilot-finops.example.yml", import.meta.url), "utf8"));
  const html = renderCoverageHouse(doc.budgets, 5);

  const indices = [...html.matchAll(/data-policy-index="(\d+)"/g)].map((match) => Number(match[1]));
  assert.deepEqual(indices.sort((left, right) => left - right), [0, 1, 2, 3, 4, 5, 6, 7]);
  assert.match(html, /data-policy-index="5" aria-pressed="true"/);
  assert.match(html, /The foundation/);
  assert.match(html, /Scopes may overlap/);
  assert.match(html, /Shared cost center allowed/);
  assert.match(html, /\$5,000/);
});

test("coverage house escapes imported names and shows empty or invalid states", () => {
  const html = renderCoverageHouse([
    { scope: "team", team: '<img src=x onerror="alert(1)">', name: '<script>bad</script>', amount: 25 },
    { scope: "user", users: ["<octocat>"], amount: 20 },
    null,
  ]);

  assert.ok(!html.includes("<img"));
  assert.ok(!html.includes("<script>"));
  assert.match(html, /&lt;octocat&gt;/);
  assert.match(html, /Unmapped policies/);
  assert.match(html, /No enterprise cap configured/);
  assert.match(renderCoverageHouse([]), /No all-user default configured/);
});

test("coverage motion distinguishes additions and edits from selection-only renders", () => {
  const track = createCoverageTracker();
  const budgets = [{ scope: "enterprise", amount: 5000 }];

  assert.deepEqual([...track(budgets).changes], [[0, "added"]]);
  assert.deepEqual(track(budgets), { changed: false, changes: new Map() });
  budgets[0].amount = 5100;
  assert.deepEqual([...track(budgets).changes], [[0, "updated"]]);
  assert.deepEqual(track(budgets), { changed: false, changes: new Map() });
  budgets.push({ scope: "team", team: "platform", amount: 25 });
  assert.deepEqual([...track(budgets).changes], [[1, "added"]]);
  budgets[1].team = "engineering";
  assert.deepEqual([...track(budgets).changes], [[1, "updated"]]);
});

test("coverage motion does not reanimate surviving policies after removal", () => {
  const track = createCoverageTracker();
  const budgets = [{ scope: "all_users", amount: 30 }, { scope: "user", users: ["octocat"], amount: 75 }];
  track(budgets);
  budgets.splice(0, 1);

  assert.deepEqual(track(budgets), { changed: true, changes: new Map() });
  assert.deepEqual(track([]), { changed: true, changes: new Map() });
  assert.deepEqual(track(undefined), { changed: false, changes: new Map() });
});

test("coverage amounts retain exact digits, explicit units, and a missing-value state", () => {
  const html = renderCoverageHouse([
    { scope: "all_users", amount: 0 },
    { scope: "enterprise", amount: 1234567890123 },
    { scope: "user", users: ["octocat"] },
  ]);

  assert.match(html, /coverage-amount-value">0<\/span>/);
  assert.match(html, /coverage-amount is-long/);
  assert.match(html, /coverage-amount-value">1,234,567,890,123<\/span>/);
  assert.match(html, /USD <span>\/ collective cap<\/span>/);
  assert.match(html, /USD <span>\/ user<\/span>/);
  assert.match(html, /coverage-amount is-missing" style="--coverage-digits: 2">Amount required<\/strong>/);
});

test("studio workflow example is a manual dry run using the action contract", () => {
  const html = readFileSync(new URL("../site/index.html", import.meta.url), "utf8");
  const snippet = html.match(/<code id="action-example">([\s\S]*?)<\/code>/);
  assert.ok(snippet, "the workflow sample must be present");
  assert.ok(snippet.index > html.indexOf('id="yaml-preview"'), "the workflow must follow the YAML preview");
  const workflow = parseConfigYaml(snippet[1]);
  const action = parseConfigYaml(readFileSync(new URL("../action.yml", import.meta.url), "utf8"));

  assert.deepEqual(workflow.on, { workflow_dispatch: {} });
  assert.deepEqual(workflow.permissions, { contents: "read" });
  assert.equal(workflow.jobs.preview["runs-on"], "ubuntu-latest");
  const [checkout, preview] = workflow.jobs.preview.steps;
  assert.equal(checkout.uses, "actions/checkout@v7");
  assert.equal(preview.uses, "amgdy/copilot-finops-automation@v3");
  assert.equal(preview.with.operation, "apply");
  assert.equal(preview.with["config-file"], action.inputs["config-file"].default);
  assert.equal(preview.with["dry-run"], "true");
  assert.equal(preview.with.enterprise, "${{ vars.COPILOT_FINOPS_ENTERPRISE }}");
  assert.equal(preview.with.token, "${{ secrets.COPILOT_FINOPS_TOKEN }}");
  for (const input of Object.keys(preview.with)) {
    assert.ok(Object.hasOwn(action.inputs, input), `unknown action input: ${input}`);
  }
});

test("both preview headers label their destination files outside the copied YAML", () => {
  const html = readFileSync(new URL("../site/index.html", import.meta.url), "utf8");
  const configPath = html.match(/<code id="config-preview-path"[^>]*>([^<]+)<\/code>/)?.[1];
  const workflowPath = html.match(/<code id="workflow-preview-path"[^>]*>([^<]+)<\/code>/)?.[1];
  const snippet = html.match(/<code id="action-example">([\s\S]*?)<\/code>/)?.[1];
  const workflow = parseConfigYaml(snippet);

  assert.equal(configPath, workflow.jobs.preview.steps[1].with["config-file"]);
  assert.equal(workflowPath, ".github/workflows/copilot-finops.yml");
  assert.match(html, /class="code-preview" role="group" aria-labelledby="config-preview-path"/);
  assert.match(html, /class="code-preview" role="group" aria-labelledby="workflow-preview-path"/);
  assert.ok(!snippet.includes(workflowPath), "the workflow filename is not part of the copied code");
  assert.match(html, /<pre id="yaml-preview" aria-label="Generated YAML configuration"><\/pre>/);
});
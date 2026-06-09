# copilot-finops-automation

Simple GitHub Actions + GitHub CLI automation for GitHub Enterprise Copilot FinOps operations.

> Public repository note: keep this repository free of real enterprise slugs, team names, cost center names, user logins, generated reports, logs, and tokens. Put real values only in a private fork or private repository.

## What this repository does

- Sync GitHub team members (org teams **or** enterprise teams) into enterprise cost center membership mappings.
- Apply Copilot budget policies for enterprise, universal user default, cost center, and team-based budgets.
- Audit desired config versus current GitHub state and produce markdown reports.
- Support manual and scheduled workflows.
- Keep manual mutating runs in `dry_run=true` mode by default; scheduled runs reconcile reviewed file-based config.

All billing operations use GitHub's GA **Budget and usage management APIs** (enhanced billing). See [API reference](#api-reference-ga-enhanced-billing) below.

## How Copilot usage-based billing works

Copilot is billed on a usage-based model measured in **AI credits**:

- Every Copilot license includes an allotment of AI credits that are **pooled across the enterprise**.
- While the shared pool has credits, Copilot requests are served from the pool at no extra cost.
- Once the pool is exhausted, additional usage is **metered at $0.01 USD per AI credit**, subject to the budgets you configure (the "AI credit paid usage" policy must be enabled for metered usage to occur).
- Code completions and next edit suggestions are included in every plan and **do not consume AI credits**.

There are four budget controls, which work together (not as alternatives):

| Control | What it caps | When it's active | Hard stop? |
| --- | --- | --- | --- |
| Universal user-level budget | Each user's total AI-credit consumption | Always (pool + metered) | Always |
| Individual user-level budget | A specific user's total consumption (overrides universal) | Always (pool + metered) | Always |
| Cost center budget | A cost center's metered charges after pool exhaustion | Metered phase only | Only if "stop usage" enabled |
| Enterprise budget | Total enterprise metered charges after pool exhaustion | Metered phase only | Only if "stop usage" enabled |

> The enterprise budget is **not** a total monthly budget — it only caps metered charges after the pool is exhausted. Your maximum bill is license fees **plus** the enterprise budget.

See `docs/workflows.md` for the full level tree and billing-flow diagrams.

## Quick start

1. Fork this repository into a private repository, or use it as a template for your enterprise automation repository.
2. Create a token with the permissions in `docs/permissions.md`, then save it as the repository secret `COPILOT_FINOPS_TOKEN`.
3. Copy the example configs into the workflow default files:

   ```bash
   cp config/cost-center-members.example.yml config/cost-center-members.yml
   cp config/budget-policies.example.yml config/budget-policies.yml
   ```

4. Replace placeholder values with your enterprise slug, team slugs, cost center names, budget amounts, and alert recipients.
5. Validate config locally:

   ```bash
   scripts/validate-config.sh config/cost-center-members.yml teams
   scripts/validate-config.sh config/budget-policies.yml budgets
   ```

6. Run the audit workflow first, then run sync/apply manually with `dry_run=true`. Switch manual runs to `dry_run=false`, or enable schedules, only after the job summary looks right.

If you do not want to sync cost center members, keep `config/cost-center-members.yml` present with `mappings: []`. If you are not ready to apply budgets, keep `config/budget-policies.yml` present with `budget_policies: []`.

## Repository layout

```text
.github/workflows/
  audit-copilot-budget-state.yml
  sync-cost-center-members.yml
  apply-user-budgets.yml
.github/ISSUE_TEMPLATE/
  budget-policy-config-request.yml
  cost-center-members-config-request.yml
.github/skills/
  copilot-finops-config/
config/
  cost-center-members.yml
  budget-policies.yml
  cost-center-members.example.yml
  budget-policies.example.yml
scripts/
  resolve-budget-policies-config.sh
  resolve-cost-center-members-config.sh
  validate-config.sh
  sync-cost-center-members.sh
  apply-user-budgets.sh
  audit-copilot-budget-state.sh
docs/
  api-reference.md
  setup.md
  workflows.md
  permissions.md
  troubleshooting.md
  public-release.md
README.md
SECURITY.md
CONTRIBUTING.md
AGENTS.md
```

## Naming conventions

Consistent naming makes costs traceable across GitHub and Azure billing dashboards.

| Item | Pattern | Example |
| --- | --- | --- |
| Cost center (org team) | `cc-org-{org}-{team-slug}` | `cc-org-acme-platform-engineering` |
| Cost center (enterprise team) | `cc-ent-{enterprise}-{team-slug}` | `cc-ent-acme-ai-leads` |
| Enterprise budget | `budget-ent-{enterprise}-total` | `budget-ent-acme-total` |
| Universal user budget | `budget-universal-default` | `budget-universal-default` |
| Cost center budget | `budget-cc-{cost-center}` | `budget-cc-platform-engineering` |
| Team budget | `budget-team-org-{team-slug}` or `budget-team-ent-{team-slug}` | `budget-team-org-platform-engineering` |

Enterprise team mappings use the bare team slug in config (e.g., `my-team-name`).

## Config: cost-center-members

File: `config/cost-center-members.example.yml`

Each mapping syncs one team's members into one cost center. `source` accepts either an org team or an enterprise team:

```yaml
mappings:
  # Org team source
  - name: cc-org-your-org-platform-engineering
    source:
      org: your-org
      team_slug: platform-engineering
    target:
      cost_center: cc-org-your-org-platform-engineering
    sync:
      remove_extra_members: true

  # Enterprise team source
  - name: cc-ent-your-enterprise-ai-leads
    source:
      enterprise: your-enterprise
      team_slug: ai-leads
    target:
      cost_center: cc-ent-your-enterprise-ai-leads
    sync:
      remove_extra_members: true
```

`sync.remove_extra_members` (default `false`) and `sync.batch_size` (default `50`, max `50`) are optional — omit them to use the defaults.

## Config: budget-policies

File: `config/budget-policies.example.yml`

Four policy `type` values map onto GA budget scopes:

| Type | GA `budget_scope` | What it does |
| --- | --- | --- |
| `enterprise` | `enterprise` | Caps total enterprise metered (additional) spend after the shared pool is exhausted. |
| `universal` | `multi_user_customer` | Sets the default user-level budget for every licensed user (covers shared pool + additional usage). |
| `cost_center` | `cost_center` | Caps a single cost center's metered (additional) spend after the shared pool. Identify the cost center by name via `target.cost_center`. |
| `team` + `coverage: total_spend` | `user` (one per member) | Fetches team members and applies an individual user-level budget to each member, overriding the universal default. |
| `team` + `coverage: additional_spend` | `cost_center` | Applies one cost center budget for the team's collective metered spend. The apply script adds current team members to the cost center. |

Each policy's `budget` block maps directly onto the GA request body:

| Config field | GA field | Notes |
| --- | --- | --- |
| `budget.amount` | `budget_amount` | Whole USD. Required. |
| `budget.product_sku` | `budget_product_sku` | Optional, default `ai_credits` (Copilot metered usage). |
| `budget.prevent_further_usage` | `prevent_further_usage` | Optional, default `true`. Must be `true` for `universal`/`team` (user-level budgets always hard-stop). |
| `budget.alerting.will_alert` | `budget_alerting.will_alert` | Optional, default `false`. Enable threshold alerts. |
| `budget.alerting.alert_recipients` | `budget_alerting.alert_recipients` | Optional, default `[]`. Login names to notify. |

`budget_type` is derived from the product SKU, not the scope. The default Copilot SKU, `ai_credits`, uses `BundlePricing` at every scope, so you normally do not need to set `budget.type`. Only `budget.amount` is required; omit any other field to use its default.

```yaml
budget_policies:
  - name: budget-ent-your-enterprise-total
    type: enterprise
    budget:
      amount: 5000
      prevent_further_usage: true
      alerting: { will_alert: true, alert_recipients: [your-billing-admin] }

  - name: budget-universal-default
    type: universal
    budget:
      amount: 0
      prevent_further_usage: true

  - name: budget-cc-platform-engineering
    type: cost_center
    target:
      cost_center: cc-org-your-org-platform-engineering
    budget:
      amount: 50

  - name: budget-team-org-platform-engineering
    type: team
    source:
      org: your-org
      team_slug: platform-engineering
    budget:
      amount: 100
      prevent_further_usage: true
```

## Workflows

### Sync cost center members

Workflow: `.github/workflows/sync-cost-center-members.yml`

Triggers: manual + daily schedule at 03:17 UTC. Manual runs start in dry-run; scheduled runs use file-based config and run live.

Inputs:

- `enterprise_slug` (optional — overrides `enterprise_slug` in the config file)
- `cost_center_members_config_file` (default `config/cost-center-members.yml`)
- `cost_center_members_issue_number` (optional — issue created from the Cost center members config request form)
- `mapping_name` (optional — process one mapping only)
- `dry_run` (default `true`)

### Apply user budgets

Workflow: `.github/workflows/apply-user-budgets.yml`

Triggers: manual + daily schedule at 04:47 UTC. Manual runs start in dry-run; scheduled runs use file-based config and run live after the member sync schedule.

Inputs:

- `enterprise_slug` (optional — overrides `enterprise_slug` in the config file)
- `budget_policies_config_file` (default `config/budget-policies.yml`)
- `budget_policies_issue_number` (optional — issue created from the Budget policy config request form)
- `policy_name` (optional — process one policy only)
- `dry_run` (default `true`)

The issue-number input extracts config YAML from the matching issue form, validates it, runs the existing script, and comments the result back on the issue. Reviewed config files are still the recommended production path.

See [docs/workflows.md](docs/workflows.md) for the full issue-based config scenario, including the `Budget policy config request` and `Cost center members config request` issue forms.

### Audit Copilot budget state

Workflow: `.github/workflows/audit-copilot-budget-state.yml`

Triggers: manual + weekly schedule on Monday at 12:23 UTC.

Inputs:

- `enterprise_slug` (optional — overrides `enterprise_slug` in the config files)
- `cost_center_members_config_file` (default `config/cost-center-members.yml`)
- `budget_policies_config_file` (default `config/budget-policies.yml`)

Produces markdown files in `reports/` and uploads them as workflow artifacts.

## Token setup

1. Create a dedicated classic PAT: [Create `COPILOT_FINOPS_TOKEN`](https://github.com/settings/tokens/new?description=Copilot%20FinOps%20Automation&scopes=admin%3Aenterprise,read%3Aenterprise,read%3Aorg).
2. Add it as repository secret: `COPILOT_FINOPS_TOKEN`.
3. If your enterprise or organization enforces SAML SSO, authorize the token for SSO.
4. Workflows use this token when present, else fall back to `GITHUB_TOKEN` where possible.

See `docs/permissions.md` for required scopes.

## Public release checklist

Before making a fork, template, or upstream copy public, review `docs/public-release.md`. At minimum, verify that tracked files contain no real enterprise names, private team slugs, cost center names, user logins, audit reports, run logs, JSONL summaries, or tokens.

## API reference (GA enhanced billing)

These automations target GitHub's GA **Budget and usage management APIs**. See [docs/api-reference.md](docs/api-reference.md) for the full process and API call flow. All endpoints send the headers `Authorization: ******`, `Accept: application/vnd.github+json`, and `X-GitHub-Api-Version: 2026-03-10`.

### Budgets

```text
GET    /enterprises/{enterprise}/settings/billing/budgets
POST   /enterprises/{enterprise}/settings/billing/budgets
GET    /enterprises/{enterprise}/settings/billing/budgets/{budget_id}
PATCH  /enterprises/{enterprise}/settings/billing/budgets/{budget_id}
DELETE /enterprises/{enterprise}/settings/billing/budgets/{budget_id}
```

Create-budget request body (enterprise scope):

```json
{
  "budget_amount": 5000,
  "prevent_further_usage": true,
  "budget_scope": "enterprise",
  "budget_type": "BundlePricing",
  "budget_product_sku": "ai_credits",
  "budget_alerting": { "will_alert": true, "alert_recipients": ["your-billing-admin"] }
}
```

Create-budget request body (user scope):

```json
{
  "budget_amount": 50,
  "budget_scope": "user",
  "user": "octocat",
  "prevent_further_usage": true,
  "budget_product_sku": "ai_credits",
  "budget_type": "BundlePricing",
  "budget_alerting": { "will_alert": false, "alert_recipients": [] }
}
```

- `budget_scope`: one of `enterprise`, `organization`, `repository`, `cost_center`, `multi_user_customer`, `user`.
- `budget_type`: one of `BundlePricing`, `ProductPricing`, `SkuPricing`. AI-credit budgets use `BundlePricing` at every scope.
- For this Copilot AI-credit automation, the scripts default `budget_product_sku` to `ai_credits`. `user` / `multi_user_customer` scopes require `prevent_further_usage: true`.
- For `user` scope, set the `user` field to the target user's login.

### Cost centers

```text
GET    /enterprises/{enterprise}/settings/billing/cost-centers
POST   /enterprises/{enterprise}/settings/billing/cost-centers
GET    /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}
PATCH  /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}
DELETE /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}
POST   /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource
DELETE /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource
```

- Cost centers are addressed by their string **ID**, not their name. The sync script resolves a name to an ID via the list endpoint.
- Current members are read from the cost center's `resources[]` array (entries of type `user`).
- Add/remove members with the `/resource` endpoints using a `{"users": [...]}` body.

The default endpoints above are built in; you do not need to configure API endpoint templates.

## Budget reconciliation (idempotent apply)

GitHub budget records have **no name field** — they are identified by a server-generated `id` plus their natural scope key. The `name:` in the budget config is a local label (used in logs and the `--policy-name` filter); it is never sent to GitHub.

So `apply-user-budgets.sh` reconciles desired config against live state instead of blindly creating. On every run it lists all existing budgets once (paginated), then for each policy matches an existing budget by its **natural key**:

| Policy type | Natural key used to match |
| --- | --- |
| `enterprise` | `budget_scope=enterprise` + `budget_product_sku` |
| `universal` | `budget_scope=multi_user_customer` + `budget_product_sku` |
| `cost_center` | `budget_scope=cost_center` + `budget_product_sku` + `budget_entity_name` (cost center name or ID) |
| `team` + `coverage: total_spend` | `budget_scope=user` + `budget_product_sku` + `user` (login) |
| `team` + `coverage: additional_spend` | Same as `cost_center` |

It then decides per policy:

- **CREATE** (`POST .../budgets`) — no existing budget matches the key.
- **UPDATE** (`PATCH .../budgets/{id}`) — a match exists but `budget_amount`, `prevent_further_usage`, or `budget_alerting` differ. Only those mutable fields are sent; identity fields are immutable.
- **No change** — a match exists and all fields are already current (idempotent; safe for scheduled runs).

The apply flow never deletes budgets. Removing a budget is manual (`DELETE .../budgets/{id}`), so a leftover budget that is no longer in config is left untouched rather than auto-removed.

## Dry-run behavior

Manual mutating workflow runs default to `dry_run=true`. Logs show what would change — `Would CREATE`, `Would UPDATE (id=…)`, or `No change` — and no writes happen until `dry_run=false`.

Scheduled sync/apply runs use reviewed file-based config and force `dry_run=false`, so they reconcile live state once schedules are enabled. Keep schedules disabled until config and token setup are ready.

## Safety recommendations

- Protect `.github/workflows/**` and `config/**` with CODEOWNERS and required reviews.
- Enforce branch protections on `main`.
- Use audit workflow regularly before applying changes.
- See `docs/troubleshooting.md` for common validation, permission, and API errors.

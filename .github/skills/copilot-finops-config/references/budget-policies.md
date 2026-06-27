# AI-Credit Spend Policy Patterns (v2)

Spend policies live under `ai_credit_spend_policies:` in the merged v2 file `config/copilot-finops.yml`
(or `config/copilot-finops.local.yml`). A v2 file declares `version: 2`; both
`ai_credit_spend_policies` and `team_cost_center_mappings` are **optional** — include only what you
need.

Use only the fields needed for the desired behavior. v2 has no product SKU or budget type surface;
scripts default to `ai_credits` (BundlePricing). Each policy requires `scope` and `amount`.

> **Baseline requirement:** whenever `ai_credit_spend_policies` is non-empty, it must contain exactly
> one `scope: all_users` default (required). A `scope: enterprise` cap is optional but limited to one.
> So when you author any budgets, always include the all-users default, then layer `enterprise` (at
> most one) / `cost_center` / `team` / `organization` policies on top. An empty (or omitted) list is a
> valid no-op.

> **Authoritative shape:** the full field list, enums, and per-`scope` required/forbidden rules live
> in `schemas/v2/copilot-finops.schema.json` and `config/copilot-finops.example.yml`. This file shows
> idiomatic examples and when to use each — if it ever disagrees with the schema, the schema wins.

> Editing an existing v1 file (`config/budget-policies.yml`)? Use the v1 vocab (`budget_policies` /
> `type` / `coverage` / `source` / `target` / `budget.*`) and validate with `... budgets`. See the
> v1 → v2 map in `SKILL.md`.

## Empty / budgets-only Config

```yaml
version: 2
enterprise_slug: your-enterprise
ai_credit_spend_policies: []
```

## All-Users Default User Budget

Creates the default user-level budget for all licensed users.

Rules:

- Exactly one all-users budget — required and unique whenever any budget policy is defined.
- Always hard-stop (omit `stop_at_limit` or set it `true`).
- Covers shared pool + metered usage.

```yaml
ai_credit_spend_policies:
  - name: budget-all-users-default
    scope: all_users
    description: Default per-user AI-credit budget for all licensed users.
    amount: 50
```

## Enterprise Metered-Spend Cap

Caps total enterprise metered spend after the shared pool is exhausted. Optional, but limited to one
enterprise policy per config.

```yaml
ai_credit_spend_policies:
  - name: budget-ent-your-enterprise-total
    scope: enterprise
    description: Enterprise-wide cap on total Copilot metered AI-credit spend after the shared pool.
    amount: 500
```

For alert-only behavior, set `stop_at_limit: false`.

## User Budgets

The most direct targeted budget: cap specific users. `scope: user` creates one hard-stop user-level
budget for each login in `users`, written on the enterprise endpoint.

Rules:

- Requires `users` (a non-empty list of GitHub logins).
- Always hard-stop (omit `stop_at_limit` or set it `true`) — user-level budgets cannot alert-only.
- Forbids `teams`, `cost_center`, `credit_scope`, `organization`, `remove_extra_members`.
- If a `team`/`organization` `pool_then_metered` policy also budgets one of these logins, the last
  policy in the file wins (the collision is flagged in the run summary).

```yaml
ai_credit_spend_policies:
  - name: budget-user-power-users
    scope: user
    description: Individual cap for one or more high-usage users.
    users:
      - your-power-user
      - your-other-power-user
    amount: 75
```

## Cost Center Metered-Spend Cap

Caps a named cost center's metered spend after the shared pool.

```yaml
ai_credit_spend_policies:
  - name: budget-cc-platform-engineering
    scope: cost_center
    description: Metered AI-credit spend cap for the platform engineering cost center.
    cost_center: cc-org-your-org-platform-engineering
    amount: 200
    stop_at_limit: false
    alert_admins:
      - your-copilot-admin
```

## Team Budget: Pool Then Metered

Applies one user-level budget per current team member, covering the shared pool then metered usage.
Use when each team member should be capped individually. `teams` takes one or more slugs; their
members are unioned and deduped before the per-member budgets are created.

Rules:

- `credit_scope: pool_then_metered`
- Always hard-stop.
- Requires team membership read access.
- `organization:` selects org teams; omit it for enterprise teams.

Org team:

```yaml
ai_credit_spend_policies:
  - name: budget-team-org-platform-engineering
    scope: team
    organization: your-org
    teams:
      - platform-engineering
    credit_scope: pool_then_metered
    amount: 100
```

Enterprise teams (list more than one to union their members):

```yaml
ai_credit_spend_policies:
  - name: budget-team-ent-champions
    scope: team
    teams:
      - copilot-champions
      - copilot-early-adopters
    credit_scope: pool_then_metered
    amount: 150
```

## Team Budget: Metered Only

Creates or updates one cost center budget per listed team for that team's collective metered spend
after the shared pool, and populates each cost center with the team's current members.

Rules:

- `credit_scope: metered_only`
- `cost_center:` is optional and only allowed with a single team; if omitted (or when several teams
  are listed) the script derives and creates one cost center per team.
- `remove_extra_members: true` also prunes cost-center members who left the team (default additive).
- `stop_at_limit` is optional here.
- Membership note: the apply step populates each cost center with the team's current members at apply
  time. For ongoing membership you can instead assign the enterprise team to the cost center natively
  ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/)) so
  membership stays current automatically; if you do, skip the matching `team_cost_center_mappings`
  entry (the sync defers to a native assignment) and let this budget keep capping that cost center.

Explicit cost center (single team only):

```yaml
ai_credit_spend_policies:
  - name: budget-team-ent-ai-leads
    scope: team
    teams:
      - ai-leads
    credit_scope: metered_only
    cost_center: cc-ent-your-enterprise-ai-leads
    amount: 500
    stop_at_limit: false
```

Auto-created cost center with leaver pruning:

```yaml
ai_credit_spend_policies:
  - name: budget-team-org-ml-platform
    scope: team
    organization: your-org
    teams:
      - ml-platform
    credit_scope: metered_only
    amount: 300
    remove_extra_members: true
```

## Organization Budget

Caps an entire organization's spend. Dual-track like a team, but keyed on the org itself and written
on the org billing endpoint. Requires `organization:` and `credit_scope`; never uses a cost center.

- `credit_scope: pool_then_metered` -> one user budget per org member (always hard-stop).
- `credit_scope: metered_only` -> one org-scope budget for the org's collective metered spend.

Per-member (all org members get an individual budget):

```yaml
ai_credit_spend_policies:
  - name: budget-org-your-org-per-member
    scope: organization
    organization: your-org
    credit_scope: pool_then_metered
    amount: 80
```

One org-scope budget:

```yaml
ai_credit_spend_policies:
  - name: budget-org-your-org-total
    scope: organization
    organization: your-org
    credit_scope: metered_only
    amount: 4000
    stop_at_limit: false
```

> Conflict: if a login is also individually budgeted by a team pool_then_metered policy, the last
> policy in the file wins and the collision is flagged in the run summary (see `SKILL.md` → Conflicts).

## Alerts

Alerting is optional: list the admin logins to notify. A non-empty `alert_admins` enables alerting.

```yaml
alert_admins:
  - your-copilot-admin
```

## Validate and dry-run

See `./validation.md` for the full command matrix (v1/v2, dry-run, workflow inputs). Quick check after authoring:

```bash
scripts/validate-config.sh config/copilot-finops.yml all
```

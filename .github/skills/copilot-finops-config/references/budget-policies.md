# Budget Policies Config Patterns

Budget policies live under `budget_policies:` in `config/budget-policies.yml` or `config/budget-policies.local.yml`.

Use only fields needed for the desired behavior. The scripts default `budget.product_sku` to `ai_credits` and derive `budget_type`; do not add those fields for normal Copilot AI-credit config.

## Empty Config

```yaml
enterprise_slug: your-enterprise
budget_policies: []
```

## Universal Default User Budget

Creates the default user-level budget for all licensed users.

Rules:

- One universal AI-credit budget per natural key.
- Always hard-stop.
- Covers shared pool + metered usage.

```yaml
enterprise_slug: your-enterprise

budget_policies:
  - name: budget-universal-default
    type: universal
    description: Default per-user AI-credit budget for all licensed users.
    budget:
      amount: 50
      prevent_further_usage: true
```

## Enterprise Metered-Spend Cap

Caps total enterprise metered spend after the shared pool is exhausted.

```yaml
- name: budget-ent-your-enterprise-total
  type: enterprise
  description: Enterprise-wide cap on total Copilot metered AI-credit spend after the shared pool.
  budget:
    amount: 500
    prevent_further_usage: true
```

For alert-only behavior, set `prevent_further_usage: false`.

## Cost Center Metered-Spend Cap

Caps a cost center's metered spend after the shared pool.

```yaml
- name: budget-cc-platform-engineering
  type: cost_center
  description: Metered AI-credit spend cap for the platform engineering cost center.
  target:
    cost_center: cc-org-your-org-platform-engineering
  budget:
    amount: 200
    prevent_further_usage: false
    alerting:
      will_alert: true
      alert_recipients:
        - your-copilot-admin
```

## Team Budget: Total Spend

Applies one user-level budget per current team member. Use when the user wants each team member capped individually across shared pool + metered usage.

Rules:

- `coverage: total_spend`
- Always hard-stop.
- Requires team membership read access.
- Overwrites/updates individual user budgets for matching users.

Org team:

```yaml
- name: budget-team-org-platform-engineering
  type: team
  coverage: total_spend
  description: Per-member AI-credit cap for org team platform-engineering.
  source:
    org: your-org
    team_slug: platform-engineering
  budget:
    amount: 100
    prevent_further_usage: true
```

Enterprise team:

```yaml
- name: budget-team-ent-copilot-champions
  type: team
  coverage: total_spend
  description: Per-member AI-credit cap for enterprise team copilot-champions.
  source:
    enterprise: your-enterprise
    team_slug: copilot-champions
  budget:
    amount: 150
    prevent_further_usage: true
```

## Team Budget: Additional Spend

Creates or updates one cost center budget for the team's collective metered spend after the shared pool.

Rules:

- `coverage: additional_spend`
- `target.cost_center` is optional.
- If omitted, script derives and creates the cost center if needed.
- The apply script adds current team members to the cost center.
- Ongoing removals should use `cost-center-members.yml` sync mappings.

Explicit cost center:

```yaml
- name: budget-team-ent-ai-leads
  type: team
  coverage: additional_spend
  description: Collective metered AI-credit cap for enterprise team ai-leads.
  source:
    enterprise: your-enterprise
    team_slug: ai-leads
  target:
    cost_center: cc-ent-your-enterprise-ai-leads
  budget:
    amount: 500
    prevent_further_usage: false
```

Auto-created cost center:

```yaml
- name: budget-team-ent-data-science
  type: team
  coverage: additional_spend
  description: Collective metered AI-credit cap for enterprise team data-science.
  source:
    enterprise: your-enterprise
    team_slug: data-science
  budget:
    amount: 300
    prevent_further_usage: false
```

## Alerts

Alerting is optional.

```yaml
alerting:
  will_alert: true
  alert_recipients:
    - your-copilot-admin
```

## Validation

```bash
scripts/validate-config.sh config/budget-policies.yml budgets
```

Run locally with:

```bash
scripts/apply-user-budgets.sh --config-file config/budget-policies.yml --dry-run true
```

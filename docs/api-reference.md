# API Reference

This project uses GitHub's GA **Budget and usage management** APIs for enhanced billing. Normal users do not need to configure endpoint templates; the scripts build the endpoints below from the enterprise slug and resolved IDs.

All API calls are made with GitHub CLI (`gh api`) using the workflow token from `COPILOT_FINOPS_TOKEN` when present.

## Common Headers

```text
Authorization: Bearer <token>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

## Sync Cost Center Members

Script: `scripts/sync-cost-center-members.sh`

Process:

1. Validate `cost-center-members.yml`.
2. Resolve `enterprise_slug` from workflow input or config.
3. Fetch source team members.
4. Resolve `target.cost_center` display name to its active cost center ID.
5. Read current cost center user resources.
6. Compare source team users with current cost center users.
7. Add missing users.
8. Remove extra users only when `sync.remove_extra_members: true`.

Team member endpoints:

```text
GET /orgs/{org}/teams/{team_slug}/members?per_page=100
GET /enterprises/{enterprise}/teams/{team_slug}/memberships?per_page=100
```

Cost center endpoints:

```text
GET    /enterprises/{enterprise}/settings/billing/cost-centers
GET    /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}
POST   /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource
DELETE /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource
```

Add/remove body:

```json
{
  "users": ["octocat", "monalisa"]
}
```

Notes:

- Config uses cost center names for readability.
- The API mutates cost centers by cost center ID, so scripts resolve name to ID first.
- Archived/deleted cost centers are ignored during name resolution.
- `remove_extra_members: false` or omitted means additive sync only.

## Apply Budget Policies

Script: `scripts/apply-user-budgets.sh`

Process:

1. Validate `budget-policies.yml`.
2. Resolve `enterprise_slug` from workflow input or config.
3. List existing budgets once and cache them locally for reconciliation.
4. Process each policy, or one policy when `--policy-name` is used.
5. Match an existing budget by natural key.
6. Create the budget when no match exists.
7. Patch mutable fields when an existing budget differs.
8. Leave matching budgets unchanged.
9. Never delete budgets that are no longer in config.

Budget endpoints:

```text
GET   /enterprises/{enterprise}/settings/billing/budgets?per_page=10
POST  /enterprises/{enterprise}/settings/billing/budgets
PATCH /enterprises/{enterprise}/settings/billing/budgets/{budget_id}
```

The scripts do not call `DELETE` automatically. Manual cleanup can use:

```text
DELETE /enterprises/{enterprise}/settings/billing/budgets/{budget_id}
```

Create body examples:

```json
{
  "budget_scope": "enterprise",
  "budget_amount": 5000,
  "prevent_further_usage": true,
  "budget_product_sku": "ai_credits",
  "budget_type": "BundlePricing",
  "budget_alerting": {
    "will_alert": true,
    "alert_recipients": ["your-billing-admin"]
  }
}
```

```json
{
  "budget_scope": "user",
  "user": "octocat",
  "budget_amount": 50,
  "prevent_further_usage": true,
  "budget_product_sku": "ai_credits",
  "budget_type": "BundlePricing",
  "budget_alerting": {
    "will_alert": false,
    "alert_recipients": []
  }
}
```

Patch body:

```json
{
  "budget_amount": 100,
  "prevent_further_usage": true,
  "budget_alerting": {
    "will_alert": false,
    "alert_recipients": []
  }
}
```

Only mutable fields are patched. Identity fields such as scope, SKU, user, and cost center entity are not patched.

### Budget Natural Keys

| Policy type | Match key |
| --- | --- |
| `enterprise` | `budget_scope=enterprise` + SKU |
| `universal` | `budget_scope=multi_user_customer` + SKU |
| `cost_center` | `budget_scope=cost_center` + SKU + cost center name or ID |
| `team` + `coverage: total_spend` | `budget_scope=user` + SKU + login |
| `team` + `coverage: additional_spend` | Same as `cost_center` |

### Cost Centers During Budget Apply

Budget policies that target cost centers need cost center IDs. The apply script uses these endpoints when needed:

```text
GET  /enterprises/{enterprise}/settings/billing/cost-centers
GET  /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}
POST /enterprises/{enterprise}/settings/billing/cost-centers
POST /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}/resource
```

Create cost center body:

```json
{
  "name": "cc-ent-your-enterprise-data-science"
}
```

For `team` policies with `coverage: additional_spend`:

- If `target.cost_center` is set, the script resolves that name to an active cost center ID.
- If `target.cost_center` is omitted, the script derives a name and creates the cost center if needed.
- The script adds current team members to the cost center so the budget applies to the intended users.
- Ongoing removals are handled by the sync workflow when configured.

## Audit Copilot Budget State

Script: `scripts/audit-copilot-budget-state.sh`

Process:

1. Validate both config files.
2. Resolve `enterprise_slug` from workflow input, cost center config, or budget config.
3. Count source team members for cost center mappings.
4. Resolve and count current cost center user resources.
5. Summarize budget policies, scopes, SKUs, amounts, and hard-stop settings.
6. Write a Markdown report under `reports/`.

Audit uses read calls from the same endpoint groups listed above:

```text
GET /orgs/{org}/teams/{team_slug}/members?per_page=100
GET /enterprises/{enterprise}/teams/{team_slug}/memberships?per_page=100
GET /enterprises/{enterprise}/settings/billing/cost-centers
GET /enterprises/{enterprise}/settings/billing/cost-centers/{cost_center_id}
```

Audit reports can contain operational details such as team names, cost center names, user counts, policy names, SKUs, and budget amounts. Treat generated reports as sensitive operational data.

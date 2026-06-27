# API Reference

This project uses GitHub's GA **Budget and usage management** APIs for enhanced billing. Normal users do not need to configure endpoint templates; the scripts build the endpoints below from the enterprise slug and resolved IDs.

All API calls are made with GitHub CLI (`gh api`) using the workflow token from `COPILOT_FINOPS_TOKEN` when present.

> The API is the same across config versions; only the config vocabulary differs. The examples below
> use the v2 vocab (`scope`/`credit_scope`/`users`/`teams`/`organization`/`cost_center`/`amount`/`stop_at_limit`/`alert_admins`).
> The frozen v1 vocab maps onto the same endpoints and request fields — see
> [schemas/README.md](../schemas/README.md#v1-schemas-frozen) for the v1 ↔ v2 map.

## Common Headers

```text
Authorization: Bearer <token>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2026-03-10
```

## Sync Cost Center Members

Script: `scripts/sync-cost-center-members.sh`

Process:

1. Validate the config file.
2. Resolve `enterprise_slug` from workflow input or config.
3. For each mapping, decide whether to sync: by default the mapping is **skipped** (a `NOTE` is logged) and the script defers to native enterprise-team assignment. It proceeds only when `force_user_sync: true` on the mapping or `--force-user-sync true` is passed. The remaining steps run only for forced mappings.
4. Fetch source team members.
5. Resolve the `cost_center` name to its active cost center ID.
6. Read current cost center user resources.
7. Detect natively-assigned enterprise team resources on the cost center. If the mapping's own team is already assigned natively, skip the mapping (the native assignment keeps membership current); if a different team resource is present, warn.
8. Compare source team users with current cost center users.
9. Add missing users.
10. Remove extra users only when `remove_extra_members: true`.

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
- **Native enterprise team assignment is preferred and is the default.** GitHub supports adding an enterprise team directly as a cost center resource ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/), [docs](https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-costs-at-scale)), which keeps membership current automatically (including via SCIM/IdP sync). Because of this, the sync **skips every mapping by default**; opt into the legacy user-level sync per mapping with `force_user_sync: true` (or globally with `--force-user-sync true`). The REST resource endpoint does **not** yet expose a team write field — its body parameters are still `users`/`organizations`/`repositories` — so this user-level sync remains the automatable bridge. The scripts read team resources via `GET .../cost-centers/{cost_center_id}` (matching any `resources[].type` containing `team`, e.g. `Team`/`EnterpriseTeam`) and defer to a native assignment when present.

## Apply Budget Policies

Script: `scripts/apply-user-budgets.sh`

Process:

1. Validate the config file.
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

| Policy scope | Match key |
| --- | --- |
| `all_users` | `budget_scope=multi_user_customer` + SKU |
| `enterprise` | `budget_scope=enterprise` + SKU |
| `user` | `budget_scope=user` + SKU + login (one per login in `users`) |
| `cost_center` | `budget_scope=cost_center` + SKU + cost center name or ID |
| `team` + `credit_scope: pool_then_metered` | `budget_scope=user` + SKU + login (per member, unioned across `teams`) |
| `team` + `credit_scope: metered_only` | Same as `cost_center` (one per team in `teams`) |
| `organization` + `metered_only` | `budget_scope=organization` + SKU + org name (on the org endpoint) |
| `organization` + `pool_then_metered` | `budget_scope=user` + SKU + login (on the org endpoint) |

### Organization Budgets (v2 `scope: organization`)

A `scope: organization` policy is written on the organization billing endpoint, not the enterprise
one (its parent is the org). The org budgets API supports `organization`, `repository`,
`multi_user_customer`, and `user` scopes — `user`/`multi_user_customer` only with `ai_credits` or
`premium_requests`, which is what this automation uses — but **not** `cost_center`.

```text
GET    /organizations/{organization}/settings/billing/budgets
POST   /organizations/{organization}/settings/billing/budgets
GET    /organizations/{organization}/settings/billing/budgets/{budget_id}
PATCH  /organizations/{organization}/settings/billing/budgets/{budget_id}
DELETE /organizations/{organization}/settings/billing/budgets/{budget_id}
```

Org-scope create body (additional usage): `budget_scope: organization`, `budget_entity_name: <org>`.
Per-member create body (total usage): `budget_scope: user`, `user: <login>`. Org membership is read
from `GET /orgs/{org}/members`.

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

For `team` policies with `credit_scope: metered_only`:

- If `cost_center` is set, the script resolves that name to an active cost center ID.
- If `cost_center` is omitted, the script derives a name and creates the cost center if needed.
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

# Workflows

## `sync-cost-center-members.yml`

- Triggers: manual + daily schedule.
- Reads team membership and cost center members.
- Shows add/remove diff in dry-run mode (default).
- Applies changes only when `dry_run=false`.

## `apply-user-budgets.yml`

- Trigger: manual.
- Reads policies from config.
- Dry-run prints payloads.
- Non-dry-run requires `api.apply_budget_endpoint_template` in config.

## `audit-copilot-budget-state.yml`

- Triggers: manual + weekly schedule.
- Generates markdown audit reports under `reports/`.
- Uploads reports as workflow artifacts.

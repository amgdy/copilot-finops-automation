# Validation And Run Commands

Always validate generated config before suggesting workflow execution.

## Schema And Versioning

`scripts/validate-config.sh` validates the file in two layers: first against the versioned JSON
Schema under `schemas/v<N>/`, then with semantic re-checks. For **v2** the schema covers structure,
types, enums, typo protection, and the structural cross-field rules (per-scope required/forbidden
fields, `enterprise`/`organization` mutual exclusivity, `credit_scope` -> `stop_at_limit`); for **v1** the
schema is shape-only. The schema layer uses `check-jsonschema`; install it with
`pipx install check-jsonschema` (or `pip install check-jsonschema`) for the full local check. If it
is not installed the script warns and runs the bash re-checks only (so the structural rules are
still enforced); the workflows install it so CI always enforces the schema.

The config version is set by the top-level `version` field: **v2 requires `version: 2`** and is
validated with type `all`; v1 omits it (defaults to `1`) and uses `budgets` / `teams`. Only use a
version that has a matching `schemas/v<N>/` directory.

## Validate Config

v2 merged file (type `all`):

```bash
scripts/validate-config.sh config/copilot-finops.yml all
scripts/validate-config.sh config/copilot-finops.local.yml all
```

v1 split files:

```bash
scripts/validate-config.sh config/budget-policies.yml budgets
scripts/validate-config.sh config/cost-center-members.yml teams
```

## Dry-Run Locally

v2 merged file (apply and sync read the same file):

```bash
scripts/apply-user-budgets.sh --config-file config/copilot-finops.yml --dry-run true
scripts/sync-cost-center-members.sh --config-file config/copilot-finops.yml --dry-run true
```

The sync command above skips `team_cost_center_mappings` by default in favor of native enterprise-team
assignment. Add `--force-user-sync true` only when intentionally dry-running the deprecated user-level
bridge.

v1 split files:

```bash
scripts/apply-user-budgets.sh --config-file config/budget-policies.yml --dry-run true
scripts/sync-cost-center-members.sh --config-file config/cost-center-members.yml --dry-run true
```

## Workflow Inputs

For the **v2 merged file**, prefer the unified workflow `apply-copilot-finops.yml`: it resolves the
config once, then applies budgets and syncs members in parallel (each with its own detailed summary).

```text
config_file: merged v2 config (default config/copilot-finops.yml)
issue_number: testing only — resolve config from a Copilot FinOps config-request issue (label copilot-finops-config); do not use for production
dry_run: true before live apply/sync
force_user_sync: false by default; true runs the deprecated user-level member sync instead of default-skip
```

The unified workflow is file-based: the enterprise slug comes from the config, not an input. The
per-type workflows below remain for running budgets/members/audit separately; they default to
`config/copilot-finops.yml` and still accept a v1 split file via the legacy `*_config_file` input
(deprecated). They are file-based only — issue-based testing goes through the unified workflow above.

Budget apply workflow:

```text
config_file: optional unified config (e.g. config/copilot-finops.yml); overrides the legacy input
budget_policies_config_file: config/budget-policies.yml (legacy v1 default)
policy_name: optional single policy
enterprise_slug: optional override
dry_run: true before live apply
```

Cost center sync workflow:

```text
config_file: optional unified config (e.g. config/copilot-finops.yml); overrides the legacy input
cost_center_members_config_file: config/cost-center-members.yml (legacy v1 default)
mapping_name: optional single mapping
enterprise_slug: optional override
dry_run: true before live sync
force_user_sync: false by default; true runs the deprecated user-level member sync instead of default-skip
```

Audit workflow:

```text
config_file: optional unified config (e.g. config/copilot-finops.yml); overrides the legacy inputs
cost_center_members_config_file: config/cost-center-members.yml (legacy v1 default)
budget_policies_config_file: config/budget-policies.yml (legacy v1 default)
enterprise_slug: optional override
force_user_sync: false by default; true reports the deprecated user-level member sync as globally forced
```

## Scheduled Workflows

- `apply-copilot-finops.yml` (unified v2) runs daily at 04:37 UTC, resolves the merged file once, and applies budgets + syncs members in parallel (live).
- `sync-cost-center-members.yml` runs daily at 03:17 UTC, uses file-based config, and forces `dry_run=false`.
- `apply-user-budgets.yml` runs daily at 04:47 UTC after member sync, uses file-based config, and forces `dry_run=false`.
- `audit-copilot-budget-state.yml` runs weekly on Monday at 12:23 UTC.

## Local Config Safety

Files matching `config/*.local.yml` are ignored by git. Use them when values are private, experimental, or specific to a local operator.

Check ignore status:

```bash
git check-ignore -v config/copilot-finops.local.yml
git check-ignore -v config/budget-policies.local.yml
git check-ignore -v config/cost-center-members.local.yml
```

## Public Repo Safety

Never put tokens in config. Do not commit private enterprise slugs, team names, cost center names, user logins, reports, or workflow logs to public branches unless explicitly approved.

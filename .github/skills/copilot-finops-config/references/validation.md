# Validation And Run Commands

Always validate generated config before suggesting workflow execution.

## Validate Budget Policies

```bash
scripts/validate-config.sh config/budget-policies.yml budgets
```

Local/private:

```bash
scripts/validate-config.sh config/budget-policies.local.yml budgets
```

## Validate Cost Center Members

```bash
scripts/validate-config.sh config/cost-center-members.yml teams
```

Local/private:

```bash
scripts/validate-config.sh config/cost-center-members.local.yml teams
```

## Dry-Run Locally

Budget policies:

```bash
scripts/apply-user-budgets.sh \
  --config-file config/budget-policies.yml \
  --dry-run true
```

Cost center member sync:

```bash
scripts/sync-cost-center-members.sh \
  --config-file config/cost-center-members.yml \
  --dry-run true
```

## Workflow Inputs

Budget apply workflow:

```text
budget_policies_config_file: config/budget-policies.yml
budget_policies_issue_number: optional issue number
policy_name: optional single policy
enterprise_slug: optional override
dry_run: true before live apply
```

Cost center sync workflow:

```text
cost_center_members_config_file: config/cost-center-members.yml
cost_center_members_issue_number: optional issue number
mapping_name: optional single mapping
enterprise_slug: optional override
dry_run: true before live sync
```

Audit workflow:

```text
cost_center_members_config_file: config/cost-center-members.yml
budget_policies_config_file: config/budget-policies.yml
enterprise_slug: optional override
```

## Scheduled Workflows

- `sync-cost-center-members.yml` runs daily at 03:17 UTC, uses file-based config, and forces `dry_run=false`.
- `apply-user-budgets.yml` runs daily at 04:47 UTC after member sync, uses file-based config, and forces `dry_run=false`.
- `audit-copilot-budget-state.yml` runs weekly on Monday at 12:23 UTC.

## Local Config Safety

Files matching `config/*.local.yml` are ignored by git. Use them when values are private, experimental, or specific to a local operator.

Check ignore status:

```bash
git check-ignore -v config/budget-policies.local.yml
git check-ignore -v config/cost-center-members.local.yml
```

## Public Repo Safety

Never put tokens in config. Do not commit private enterprise slugs, team names, cost center names, user logins, reports, or workflow logs to public branches unless explicitly approved.

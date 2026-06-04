# copilot-finops-automation

Simple GitHub Actions + GitHub CLI automation for GitHub Enterprise Copilot FinOps operations.

## What this repository does

- Sync GitHub team members into enterprise cost center membership mappings.
- Apply Copilot budget policy definitions from YAML config (API scaffold).
- Audit desired config versus current GitHub state and produce markdown reports.
- Support manual and scheduled workflows.
- Keep mutating flows in `dry_run=true` mode by default.

## Repository layout

```text
.github/workflows/
  audit-copilot-budget-state.yml
  sync-cost-center-members.yml
  apply-user-budgets.yml
config/
  teams-to-cost-centers.example.yml
  user-budget-policies.example.yml
scripts/
  validate-config.sh
  sync-cost-center-members.sh
  apply-user-budgets.sh
  audit-copilot-budget-state.sh
docs/
  setup.md
  workflows.md
  permissions.md
README.md
SECURITY.md
```

## Workflows

### Sync cost center members

Workflow: `.github/workflows/sync-cost-center-members.yml`

Inputs:
- `enterprise_slug` (required)
- `config_file` (default `config/teams-to-cost-centers.example.yml`)
- `mapping_name` (optional)
- `dry_run` (default `true`)

### Apply user budgets

Workflow: `.github/workflows/apply-user-budgets.yml`

Inputs:
- `enterprise_slug` (required)
- `config_file` (default `config/user-budget-policies.example.yml`)
- `policy_name` (optional)
- `dry_run` (default `true`)

### Audit Copilot budget state

Workflow: `.github/workflows/audit-copilot-budget-state.yml`

Inputs:
- `enterprise_slug` (required)
- `teams_config_file`
- `budgets_config_file`

Produces markdown files in `reports/` and uploads them as workflow artifacts.

## Token setup

1. Create a personal access token with enterprise permissions needed for your billing/cost-center/Copilot policy operations.
2. Add it as repository secret: `COPILOT_FINOPS_TOKEN`.
3. Workflows use this token when present, else fallback to `GITHUB_TOKEN` where possible.

## Dry-run behavior

Mutating workflows default to `dry_run=true`. Logs explicitly show what would change and no updates are applied until `dry_run=false`.

## Limitations

Some Copilot/cost-center endpoints may not have first-class `gh` commands and can vary by API availability. Scripts use `gh api` with endpoint templates and provide actionable errors when endpoints return `404`/`422`.

## Safety recommendations

- Protect `.github/workflows/**` and `config/**` with CODEOWNERS and required reviews.
- Enforce branch protections on `main`.
- Use audit workflow regularly before applying changes.

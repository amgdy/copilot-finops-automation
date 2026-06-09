# Setup

## Prerequisites

- GitHub repository with Actions enabled.
- A token with enterprise/admin permissions needed for Copilot FinOps operations. Use [Create `COPILOT_FINOPS_TOKEN`](https://github.com/settings/tokens/new?description=Copilot%20FinOps%20Automation&scopes=admin%3Aenterprise,read%3Aenterprise,read%3Aorg) to create a classic PAT with the full-automation scopes preselected.
- `COPILOT_FINOPS_TOKEN` repository secret configured (recommended).
- Local validation tools when testing from your workstation: `gh`, `jq`, `yq`, and Bash 4+.

If `COPILOT_FINOPS_TOKEN` is not set, workflows fall back to `GITHUB_TOKEN` where access permits.

After creating the token, add it as the repository secret `COPILOT_FINOPS_TOKEN`. If your enterprise or organization enforces SAML SSO, authorize the token for SSO before running the workflows.

The GitHub Actions workflows run on `ubuntu-24.04`. That runner image already includes Bash 5.2, GitHub CLI, `jq`, and `yq`, so the workflows do not install them.

On macOS, the system `/bin/bash` is usually too old for scripts that use arrays and `mapfile`. Install a newer Bash, for example with Homebrew, and make sure it is on `PATH` before running scripts locally.

## Public repository hygiene

- Keep real enterprise slugs, team slugs, cost center names, user logins, and budget amounts out of public branches unless you have explicitly approved them for disclosure.
- Store tokens only as GitHub Actions secrets. Never put tokens in config files, logs, reports, or markdown docs.
- Generated `reports/`, `*.log`, and `*.jsonl` files are ignored and should not be published.
- Use a private fork or private repository for live enterprise configuration.
- Disable scheduled workflows until the repository has safe config and the right secret configured.

## Configure files

1. Copy and adapt:
   - `config/cost-center-members.example.yml` -> `config/cost-center-members.yml`
   - `config/budget-policies.example.yml` -> `config/budget-policies.yml`
2. For each mapping, set `source.org` (org team) **or** `source.enterprise` (enterprise team) plus `source.team_slug`.
3. Name cost centers following the convention: `cc-org-{org}-{team-slug}` or `cc-ent-{enterprise}-{team-slug}`. The sync workflow matches cost centers by name and resolves them to their GA cost center ID, so cost centers used by `teams-to-cost-centers` mappings must already exist.
4. For budget policies, set `budget.amount` (whole USD, required). `budget.prevent_further_usage` defaults to `true`; keep it `true` for `universal` and `team` with `coverage: total_spend`. `budget.product_sku` defaults to `ai_credits`, and `budget_type` is derived from the SKU, so neither normally needs to be set.
5. The GA enhanced-billing endpoints are built in; you do not need to configure API endpoint templates.
6. Commit config changes through pull requests.
7. Run the audit workflow first, then run mutating workflows with `dry_run=true` before switching to `dry_run=false`.

For `team` policies with `coverage: additional_spend`, `target.cost_center` is optional. When omitted, the apply script derives the conventional cost center name, creates it if missing, and adds the team's current members.

## Empty configs

Keep config files present even when you are not using a feature yet:

```yaml
enterprise_slug: your-enterprise
mappings: []
```

```yaml
enterprise_slug: your-enterprise
budget_policies: []
```

This lets validation, audit, and scheduled workflows exit cleanly instead of failing because a file is missing.

## Copilot-assisted config authoring

This repository includes a Copilot skill at `.github/skills/copilot-finops-config/`. Use it when asking Copilot to create, update, or review budget policy and cost center member sync configs. The skill is designed to ask the required questions, choose the right YAML pattern, and remind users to validate before running workflows.

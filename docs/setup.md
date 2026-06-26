# Setup

## Prerequisites

- GitHub repository with Actions enabled.
- A token with enterprise/admin permissions needed for Copilot FinOps operations. Use [Create `COPILOT_FINOPS_TOKEN`](https://github.com/settings/tokens/new?description=Copilot%20FinOps%20Automation&scopes=admin%3Aenterprise,read%3Aenterprise,read%3Aorg) to create a classic PAT with the full-automation scopes preselected.
- `COPILOT_FINOPS_TOKEN` repository secret configured (recommended).
- Local validation tools when testing from your workstation: `gh`, `jq`, `yq`, and Bash 4+.
- Optional but recommended for full local validation: `check-jsonschema` (`pipx install check-jsonschema`) for the JSON Schema layer, and the Red Hat **YAML** VS Code extension (`redhat.vscode-yaml`) for live in-editor validation, autocomplete, hover docs, documented defaults, and examples. The repository ships `.vscode/settings.json` and an extension recommendation that wire the schemas in automatically.

If `COPILOT_FINOPS_TOKEN` is not set, workflows fall back to `GITHUB_TOKEN` where access permits.

After creating the token, add it as the repository secret `COPILOT_FINOPS_TOKEN`. If your enterprise or organization enforces SAML SSO, authorize the token for SSO before running the workflows.

The GitHub Actions workflows run on `ubuntu-24.04`. That runner image already includes Bash 5.2, GitHub CLI, `jq`, and `yq`, so the workflows do not install them. Each workflow installs `check-jsonschema` for the JSON Schema validation step.

On macOS, the system `/bin/bash` is usually too old for scripts that use arrays and `mapfile`. Install a newer Bash, for example with Homebrew, and make sure it is on `PATH` before running scripts locally.

## Public repository hygiene

- Keep real enterprise slugs, team slugs, cost center names, user logins, and budget amounts out of public branches unless you have explicitly approved them for disclosure.
- Store tokens only as GitHub Actions secrets. Never put tokens in config files, logs, reports, or markdown docs.
- Generated `reports/`, `*.log`, and `*.jsonl` files are ignored and should not be published.
- Use a private fork or private repository for live enterprise configuration.
- Disable scheduled workflows until the repository has safe config and the right secret configured.

## Configure files

All configuration lives in the unified **v2** file `config/copilot-finops.yml` — the tracked default for every workflow. (The legacy v1 split files remain supported but deprecated; see [Legacy v1 config](#legacy-v1-config) below.) For the full field reference, see [the Copilot FinOps skill](../.github/skills/copilot-finops-config/SKILL.md) and [schemas/README.md](../schemas/README.md).

1. Copy the example into your working file: `config/copilot-finops.example.yml` -> `config/copilot-finops.yml`.
2. Set `version: 2` and `enterprise_slug`. Add `ai_credit_spend_policies` and/or `team_cost_center_mappings` (both optional — include only what you need).
3. For each budget policy, set `scope` and `amount` (whole USD). For `scope: user`, set `users:` (one or more logins to budget). For `scope: team` / `organization`, also set `credit_scope` (`pool_then_metered` or `metered_only`). For `scope: team`, set `teams:` (one or more slugs) and `organization:` for org teams or omit it for enterprise teams; for `scope: cost_center`, set `cost_center:`.
4. For each mapping, set `team` and `cost_center`; set `organization:` for an org team or omit it for an enterprise team. Name cost centers `cc-org-{org}-{team-slug}` or `cc-ent-{enterprise}-{team-slug}`. The sync workflow matches cost centers by name and resolves them to their GA cost center ID. **`team_cost_center_mappings` is deprecated** — prefer assigning the enterprise team directly to the cost center natively ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/), [docs](https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-costs-at-scale)); the mapping remains a supported bridge until the REST resource API exposes a team write field. **The sync now skips every mapping by default** and defers to native assignment — to run the legacy user-level sync, set `force_user_sync: true` on the mapping (or run the workflow with the `force_user_sync` input). `remove_extra_members` only applies when forced.
5. Do not set a product SKU or budget type — the scripts default to `ai_credits`. `stop_at_limit` defaults to `true` (and is forced `true` for `all_users` and per-member `pool_then_metered` budgets). The GA enhanced-billing endpoints are built in; you do not need to configure API endpoint templates.
6. The config `version` selects the schema under `schemas/v<N>/` that `scripts/validate-config.sh` and the editor validate against: the v2 merged file sets `version: 2` (validated with `all`); v1 files omit it (default `1`, validated with `budgets`/`teams`). See [schemas/README.md](../schemas/README.md).
7. Commit config changes through pull requests.
8. Run the audit workflow first, then run mutating workflows manually with `dry_run=true` before switching manual runs to `dry_run=false` or enabling schedules.

Scheduled sync/apply workflows run live from reviewed file-based config. Keep schedules disabled until the repository has safe config and the right secret configured.

For `scope: team` + `credit_scope: metered_only`, `cost_center:` is optional and only allowed with a single team. When omitted (or when several teams are listed), the apply script derives the conventional cost center name per team, creates it if missing, and adds that team's current members.

### Legacy v1 config

v1 uses two split files (`config/budget-policies.yml`, `config/cost-center-members.yml`) with the nested vocabulary (`type` / `coverage` / `source` / `target` / `budget.*`, and `mappings` / `sync`). They are frozen but still validated by `schemas/v1/` and run by the per-type workflows. See the v1 ↔ v2 map in [schemas/README.md](../schemas/README.md#v1-schemas-frozen).

## Naming conventions

Consistent names keep costs traceable across GitHub and Azure billing dashboards. A budget `name:` is a local label used in logs and the `--policy-name` filter (it is never sent to GitHub), so you are free to standardize it. Cost center names are resolved to their GA cost center ID at run time.

| Item | Pattern | Example |
| --- | --- | --- |
| Cost center (org team) | `cc-org-{org}-{team-slug}` | `cc-org-acme-platform-engineering` |
| Cost center (enterprise team) | `cc-ent-{enterprise}-{team-slug}` | `cc-ent-acme-ai-leads` |
| Enterprise budget | `budget-ent-{enterprise}-total` | `budget-ent-acme-total` |
| All-users default budget | `budget-all-users-default` | `budget-all-users-default` |
| Single-user budget | `budget-user-{login}` | `budget-user-octocat` |
| Cost center budget | `budget-cc-{cost-center}` | `budget-cc-platform-engineering` |
| Team budget | `budget-team-org-{team-slug}` or `budget-team-ent-{team-slug}` | `budget-team-org-platform-engineering` |
| Organization budget | `budget-org-{org}-total` or `budget-org-{org}-per-member` | `budget-org-acme-total` |

Enterprise team mappings use the bare team slug in config (e.g., `my-team-name`).

## Empty configs

Keep config present even when you are not using a feature yet. v2 merged file (both lists optional):

```yaml
version: 2
enterprise_slug: your-enterprise
```

v1 split files:

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

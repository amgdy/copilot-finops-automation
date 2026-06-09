# Agent Guidance

This repository automates GitHub Enterprise Copilot FinOps workflows. Treat changes as governance-sensitive because they can affect billing budgets, cost center membership, and workflow permissions.

## Core Principles

- Keep config-as-code as the primary production path.
- Keep issue-based config as an optional workflow input path for request/test scenarios or explicitly approved live runs.
- Keep manual mutating workflow runs dry-run by default; scheduled sync/apply runs live only from reviewed file-based config.
- Preserve local/private config safety: files matching `config/*.local.yml` must remain ignored.
- Do not commit tokens, generated reports, logs, JSONL summaries, private enterprise names, user logins, or private cost center data unless the user explicitly asks and confirms they are safe to publish.
- Do not use deprecated request-based Copilot billing terminology. Use AI-credit terminology.

## Requirement Changes Must Update The Skill

Whenever requirements change for any of these areas, update the Copilot skill in `.github/skills/copilot-finops-config/` in the same change:

- config file names or structure
- budget policy fields, defaults, or supported policy types
- cost center member sync fields or behavior
- workflow inputs or issue-form behavior
- issue labels or issue template fields
- validation commands or local run commands
- public/private data safety guidance
- billing terminology or API behavior

At minimum, check and update:

- `.github/skills/copilot-finops-config/SKILL.md`
- `.github/skills/copilot-finops-config/references/interview.md`
- `.github/skills/copilot-finops-config/references/budget-policies.md`
- `.github/skills/copilot-finops-config/references/cost-center-members.md`
- `.github/skills/copilot-finops-config/references/issue-config.md`
- `.github/skills/copilot-finops-config/references/validation.md`

## Config Rules

- `config/budget-policies.yml` is the default tracked budget policy config.
- `config/cost-center-members.yml` is the default tracked cost center member sync config.
- `config/budget-policies.example.yml` and `config/cost-center-members.example.yml` are public-safe examples and should stay approachable.
- `config/*.local.yml` is ignored and is the right place for private local test config.
- Do not add `api:` endpoint-template override examples to sample config files.
- Do not add `budget.product_sku` for normal Copilot AI-credit budgets; scripts default to `ai_credits`.
- Do not add `budget.type`; scripts derive it.

## Workflow Rules

- Keep workflow YAML thin. Put reusable shell logic under `scripts/`.
- Do not change script flags lightly; workflows should adapt to scripts, not the other way around, unless the user asks for a script interface change.
- `apply-user-budgets.yml` uses `budget_policies_config_file` and optional `budget_policies_issue_number`.
- `sync-cost-center-members.yml` uses `cost_center_members_config_file` and optional `cost_center_members_issue_number`.
- `audit-copilot-budget-state.yml` is file-based only.
- Issue-based config must require the correct label before processing:
  - `budget-policy-config`
  - `cost-center-members-config`

## Validation

Run focused validation after changes:

```bash
bash -n scripts/*.sh
yq eval '.' .github/workflows/*.yml >/dev/null
yq eval '.' .github/ISSUE_TEMPLATE/*.yml >/dev/null
scripts/validate-config.sh config/budget-policies.yml budgets
scripts/validate-config.sh config/cost-center-members.yml teams
scripts/validate-config.sh config/budget-policies.example.yml budgets
scripts/validate-config.sh config/cost-center-members.example.yml teams
git diff --check
```

If available, also run:

```bash
actionlint .github/workflows/*.yml
shellcheck scripts/*.sh
```

## Documentation Expectations

When changing behavior, update relevant docs:

- `README.md`
- `docs/workflows.md`
- `docs/setup.md`
- `docs/api-reference.md`
- `docs/troubleshooting.md`
- `docs/permissions.md` when permissions change
- `docs/public-release.md` when public-safety guidance changes

Keep docs and examples consistent with the skill.

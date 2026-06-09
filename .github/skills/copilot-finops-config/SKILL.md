---
name: copilot-finops-config
description: "Use when: creating, updating, reviewing, or validating Copilot FinOps config for budget-policies.yml, cost-center-members.yml, budget policy issue YAML, cost center member issue YAML, universal budgets, enterprise caps, cost center budgets, team budgets, AI credits, and GitHub Copilot cost center sync."
argument-hint: "Describe budgets, teams, cost centers, target file path, and whether this is local/private, issue YAML, or repo config."
---

# Copilot FinOps Config

Use this skill to help users create valid Copilot FinOps configuration for this repository.

The primary outputs are:

- `config/budget-policies.yml`
- `config/cost-center-members.yml`
- ignored local files such as `config/budget-policies.local.yml`
- issue-form YAML blocks for config request issues

## Core Rules

1. Ask clarifying questions before creating config unless the user already gave all required values.
2. Prefer config-as-code in reviewed files for production changes.
3. Use `.local.yml` files for private/local config that should not be committed.
4. Use issue-form YAML only for request/test scenarios or when the user explicitly asks for issue-based config.
5. Use AI-credit terminology only. Do not use deprecated request-based billing terms.
6. Do not include `budget.product_sku` for normal Copilot AI-credit budgets; scripts default it to `ai_credits`.
7. Do not include `budget.type`; scripts derive `BundlePricing` for `ai_credits`.
8. Do not include `api:` endpoint template overrides in generated config.
9. Keep universal and `team` with `coverage: total_spend` hard-stop: `prevent_further_usage: true`.
10. Validate generated files with `scripts/validate-config.sh`.
11. When repository requirements change, keep this skill and `AGENTS.md` in sync.

## Workflow

1. Determine the target output:
   - budget policies config
   - cost center members sync config
   - both configs
   - issue-form YAML block
2. Ask the necessary questions from `./references/interview.md`.
3. Choose the right patterns:
   - `./references/budget-policies.md`
   - `./references/cost-center-members.md`
   - `./references/issue-config.md`
4. Generate minimal YAML that only includes needed fields.
5. Validate with `./references/validation.md`.
6. Explain how to run the relevant workflow or script.

## Output Guidance

When writing files:

- Use `config/budget-policies.yml` and `config/cost-center-members.yml` for repo config.
- Use `config/budget-policies.local.yml` and `config/cost-center-members.local.yml` for private local config.
- Keep public starter configs generic: `your-enterprise`, `your-org`, `platform-engineering`.

When returning YAML for an issue form:

- Return only the complete YAML block the user can paste into the issue form field.
- Remind the user that issue-based config is visible to anyone with read access to the repository, the same as config files, so the enterprise, team, cost center, user, and budget data in it is not private.

## Validation Commands

```bash
scripts/validate-config.sh config/budget-policies.yml budgets
scripts/validate-config.sh config/cost-center-members.yml teams
```

For local/private files:

```bash
scripts/validate-config.sh config/budget-policies.local.yml budgets
scripts/validate-config.sh config/cost-center-members.local.yml teams
```

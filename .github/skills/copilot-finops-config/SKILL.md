---
name: copilot-finops-config
description: "Use when: creating, updating, reviewing, or validating Copilot FinOps config for copilot-finops.yml (v2 merged config), budget-policies.yml, cost-center-members.yml, Copilot FinOps config-request issue YAML, all-users budgets, enterprise caps, cost center budgets, team budgets, organization budgets, AI credits, and GitHub Copilot cost center sync."
argument-hint: "Describe budgets, teams, cost centers, target file path, and whether this is local/private, issue YAML, or repo config."
---

# Copilot FinOps Config

Use this skill to help users create valid Copilot FinOps configuration for this repository.

There are two config contracts. Prefer **v2** for new config.

- **v2 (recommended):** one merged file, `config/copilot-finops.yml`, declaring `version: 2`.
  `ai_credit_spend_policies` and `team_cost_center_mappings` are both optional — include only what
  you need. Validated with type `all`.
- **v1 (frozen, still supported):** the split files `config/budget-policies.yml` and
  `config/cost-center-members.yml`. Do not mix v1 and v2 vocabulary in one file.

The primary outputs are:

- `config/copilot-finops.yml` (v2 merged) and its ignored local form `config/copilot-finops.local.yml`
- the v1 split files when editing existing v1 config
- issue-form YAML blocks for config request issues

## v1 → v2 Vocabulary

| v1 | v2 |
| --- | --- |
| `budget_policies:` (list) | `ai_credit_spend_policies:` (optional) |
| `type` | `scope` |
| `type: universal` | `scope: all_users` |
| `coverage: total_spend` / `additional_spend` | `credit_scope: pool_then_metered` / `metered_only` |
| `source: {enterprise, team_slug}` | `teams:` (budgets) / `team:` (mappings); enterprise inferred |
| `source: {org, team_slug}` | `organization:` + `teams:` (budgets) / `team:` (mappings) |
| `target.cost_center` | `cost_center:` |
| `budget.amount` | `amount` |
| `budget.prevent_further_usage` | `stop_at_limit` |
| `budget.alerting.{will_alert, alert_recipients}` | `alert_admins` (non-empty enables alerting) |
| `sync.remove_extra_members` | `remove_extra_members` |
| `budget-policies.yml` + `cost-center-members.yml` | `config/copilot-finops.yml` |

In v2, `enterprise:` and `organization:` are mutually exclusive on one entry. On `scope: team`,
`organization:` marks an org team membership source; on `scope: organization` it names the org the
budget belongs to (and routes the budget to the org billing endpoint). `scope: organization` is
dual-track like team: `credit_scope: pool_then_metered` gives every org member an individual user budget,
`credit_scope: metered_only` is one org-scope budget.

## Conflicts (no duplicate budgets)

GitHub Enterprise does not allow two budgets for the same entity. If the same login would receive an
individual user budget from two or more policies (any mix of `scope: user` / `team` / `organization`
`pool_then_metered`), the apply engine flags a conflict, keeps only the **last** such policy in the file (last wins), skips
the earlier ones, and lists every collision in the run summary. When advising users, order policies
so the intended winner is last, or avoid overlapping membership.

## Source of Truth for Structure

The authoritative shape of a config — every field, every enum value, and which fields are required
or forbidden for each `scope` — lives in two files, not in this skill:

- **Schema:** `schemas/v2/copilot-finops.schema.json` (v2) / `schemas/v1/*.schema.json` (v1).
- **Worked example:** `config/copilot-finops.example.yml` (covers every scope, org/enterprise teams,
  both mapping modes).

The reference files below give idiomatic examples and the judgment the schema cannot express (which
scope to pick, strict vs additive sync, what to ask). When the schema/example and any prose disagree,
the schema and example win — author config to pass the schema, then confirm with the validator
(see `./references/validation.md`). Do not invent fields or relax a per-scope rule from memory.

## Core Rules

1. Ask clarifying questions before creating config unless the user already gave all required values.
2. Prefer config-as-code in reviewed files for production changes.
3. Use `.local.yml` files for private/local config that should not be committed.
4. Use issue-form YAML only for request/test scenarios or when the user explicitly asks for issue-based config.
5. Use AI-credit terminology only. Do not use deprecated request-based billing terms.
6. Do not include product SKU or budget type fields. v2 has no such surface; scripts default to `ai_credits` (BundlePricing).
7. Do not include `api:` endpoint template overrides in generated config.
8. Keep always-hard-stop budgets hard-stop: omit `stop_at_limit` or set it `true` for `scope: all_users`, `scope: user`, and for `scope: team`/`organization` + `credit_scope: pool_then_metered`.
9. Use `remove_extra_members` only on a `scope: team` + `credit_scope: metered_only` budget, or on a `team_cost_center_mappings` entry.
10. For v2, every file must set `version: 2`; `ai_credit_spend_policies` and `team_cost_center_mappings` are both optional (include only what you need).
11. When `ai_credit_spend_policies` is non-empty, include exactly one `scope: all_users` policy (required); a `scope: enterprise` policy is optional but limited to one. An empty/omitted list stays a valid no-op.
12. Validate generated files with `scripts/validate-config.sh`: v2 uses type `all`; v1 uses `budgets` / `teams`. It checks the versioned JSON Schema (`schemas/v2/` or `schemas/v1/`) then the semantic cross-field rules.
13. Only use a config version that has a matching `schemas/v<N>/` directory.
14. When repository requirements change, keep this skill and `AGENTS.md` in sync.
15. Prefer native enterprise-team assignment for cost-center membership. GitHub supports adding an enterprise team directly as a cost center resource ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/), [docs](https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-costs-at-scale)), which keeps membership current automatically (incl. SCIM/IdP). The sync now **skips every `team_cost_center_mappings` entry by default** and defers to native assignment; the legacy user-level sync runs only when a mapping sets `force_user_sync: true` (or the run passes `--force-user-sync true` / the `force_user_sync` workflow input). Recommend native assignment first; use `force_user_sync` only as a bridge when native assignment is not usable, and never force a mapping at a cost center that already has that team assigned natively (a forced run still skips it). The audit workflow has a matching `force_user_sync` input for accurate reporting of globally-forced sync runs, including frozen v1 configs. The v2 schema marks `team_cost_center_mappings` `deprecated: true` (soft annotation — still validates and runs). See `./references/cost-center-members.md`.

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
4. Generate minimal YAML that only includes needed fields, grounded in the schema and `config/copilot-finops.example.yml` (see Source of Truth above).
5. Validate with `./references/validation.md`.
6. Explain how to run the relevant workflow or script.

## Output Guidance

When writing files:

- Prefer the v2 merged file `config/copilot-finops.yml` (and `config/copilot-finops.local.yml` for private local config).
- When editing existing v1 config, use `config/budget-policies.yml` and `config/cost-center-members.yml` (and their `.local.yml` forms).
- Keep public starter configs generic: `your-enterprise`, `your-org`, `platform-engineering`.

When returning YAML for an issue form:

- There is one issue form, `Copilot FinOps config request` (label `copilot-finops-config`), consumed only by the unified `apply-copilot-finops.yml` workflow. Return a complete v2 document the user can paste into its `Copilot FinOps config YAML` field: set `version: 2` and populate whichever of `ai_credit_spend_policies` / `team_cost_center_mappings` the run should act on (the other may be omitted — the matching half is simply a no-op).
- Remind the user that issue-based config is visible to anyone with read access to the repository, the same as config files, so the enterprise, organization, team, cost center, user, and budget data in it is not private.
- Remind the user not to assign the issue to Copilot or other coding agents; it is structured workflow input, not an implementation task.

## Validation Commands

`scripts/validate-config.sh` first validates structure, types, enums, and the structural cross-field
rules against the versioned JSON Schema (using `check-jsonschema` when installed), then applies the
semantic re-checks. Install the validator with `pipx install check-jsonschema` for the full check
locally; the workflows install it automatically.

v2 (merged file, type `all`):

```bash
scripts/validate-config.sh config/copilot-finops.yml all
scripts/validate-config.sh config/copilot-finops.local.yml all
```

v1 (frozen split files):

```bash
scripts/validate-config.sh config/budget-policies.yml budgets
scripts/validate-config.sh config/cost-center-members.yml teams
```

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
- config schema files (`schemas/`) or the config `version` field
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

- `config/copilot-finops.yml` is the **default tracked config** (v2 merged budgets + member mappings) and the per-type workflow default since Phase 3. `config/copilot-finops.example.yml` is its public-safe example. A v2 file declares `version: 2`; `ai_credit_spend_policies` and `team_cost_center_mappings` are both optional (write only what you need).
- `config/budget-policies.yml` and `config/cost-center-members.yml` are the **deprecated** v1 split files. They are frozen but still validated (`schemas/v1/`) and still accepted by the per-type workflows' `*_config_file` inputs (which emit a deprecation notice). Migrate with `scripts/migrate-v1-to-v2.sh`. Do not remove them until the v1 sunset (see `docs/public-release.md`).
- `config/copilot-finops.example.yml` is the public-safe worked example (covers every scope, org/enterprise teams, and both mapping modes) and should stay approachable. The v1 `.example.yml` files have been removed; v1 is exercised via the tracked `config/budget-policies.yml` / `config/cost-center-members.yml` and the schema tests.
- v2 renames the vocab (`budget_policies` -> `ai_credit_spend_policies`, `type` -> `scope`, `type: universal` -> `scope: all_users`, `coverage` -> `credit_scope` with `total_spend`/`additional_spend` -> `pool_then_metered`/`metered_only`; flattened `amount`/`stop_at_limit`/`alert_admins`) and infers enterprise-vs-org from whether `organization:` is set. v1 stays frozen and fully supported; do not mix v1 and v2 vocab in one file. Phase 3 flipped the tracked defaults to the merged v2 file.
- `scope: organization` is dual-track like `team` (requires `organization` + `credit_scope`; forbids `teams`/`cost_center`/`enterprise`/`remove_extra_members`/`users`). `credit_scope: pool_then_metered` -> one user budget per org member (hard-stop); `credit_scope: metered_only` -> one org-scope budget. The entry's parent picks the write endpoint: an `organization:` parent (only `scope: organization`) writes on the org billing endpoint (`/organizations/{org}/settings/billing/budgets`); everything else uses the enterprise endpoint. Cost-center budgets always stay on the enterprise endpoint (the org budgets API has no `cost_center` scope).
- `scope: user` is the multi-user budget: requires `users` (a non-empty list of logins), produces one `budget_scope: user` budget per login on the enterprise endpoint, is always hard-stop (forced `stop_at_limit: true`), and forbids `teams`/`cost_center`/`credit_scope`/`organization`/`remove_extra_members`. Each login takes part in conflict detection, so a later team/org `pool_then_metered` policy on the same login wins (last-wins).
- `scope: team` takes a non-empty `teams` list and is applied to each listed team: `pool_then_metered` unions the teams' members (deduped) into per-member hard-stop user budgets; `metered_only` fans out one derived/auto-created cost-center budget per team. An explicit `cost_center:` is only allowed when exactly one team is listed (it is forbidden with multiple teams, in both the schema and `validate-config.sh`). v1 carries a single `source.team_slug`, which the scripts normalize to a one-element teams list.
- Budget conflicts: GHE forbids duplicate budgets per entity. The apply engine runs a read-only pre-flight that flags any login individually budgeted by 2+ policies (team/org `pool_then_metered`) as a conflict, keeps the LAST policy in config order (last wins), skips earlier ones, and renders a Conflicts section in the job summary (also flags user-vs-cost-center overlaps as informational). Keep this behavior when changing the apply engine.
- Native enterprise-team cost-center assignment: GitHub supports assigning an enterprise team directly as a cost center resource (GA 2026-06-25), which keeps membership current automatically (incl. SCIM/IdP). This is the preferred path; `team_cost_center_mappings` user-level sync is a bridge because the REST resource endpoint still only accepts `users`/`organizations`/`repositories` (no team write field). **Default-skip inversion:** `sync-cost-center-members.sh` now SKIPS every mapping by default (cheap NOTE, no API calls) and defers to native assignment; the legacy user-level sync runs only when a mapping sets `force_user_sync: true` OR the run passes `--force-user-sync true` (wired to the `force_user_sync` workflow input on both `sync-cost-center-members.yml` and `apply-copilot-finops.yml`, default false — so scheduled runs skip). `remove_extra_members` only applies when forced. The global flag also forces frozen v1 configs (which have no `force_user_sync` field). Even when forced, the sync/audit engines read the cost center's `resources[]` and treat any entry whose `type` contains `team` (e.g. `Team`/`EnterpriseTeam`) as a native assignment: a forced `sync-cost-center-members.sh` still SKIPS a mapping whose team is already natively assigned (NOTE) and WARNs on any other team resource; `audit-copilot-budget-state.sh` reports three states per mapping — native-assigned (sync skipped), effectively forced (per mapping or global; legacy sync), or neither (membership unmanaged, governance gap WARN). The audit workflow has a matching `force_user_sync` input that should be set when sync/apply uses the global force input, especially for frozen v1 configs. Keep this defer-to-native + default-skip behavior when changing either engine. The v2 schema adds `force_user_sync` (boolean, default false) to the `mapping` `$def` and marks `team_cost_center_mappings` and the `mapping` `$def` `deprecated: true` (soft annotation only — they still validate and run; do NOT remove the property while the REST API has no team write field).
- A non-empty `ai_credit_spend_policies` must contain exactly one `scope: all_users` policy (the required default); a `scope: enterprise` policy is optional but capped at one. An empty/omitted list stays a valid no-op. This is rule 10, enforced in BOTH the v2 schema (`contains` + `minContains`/`maxContains`, draft 2020-12) and re-checked in `scripts/validate-config.sh` (the `all` branch) for a friendly message. v1 is frozen and unaffected.
- `config/*.local.yml` is ignored and is the right place for private local test config (`config/copilot-finops.local.yml` for v2).
- Do not add `api:` endpoint-template override examples to sample config files.
- Do not add `budget.product_sku` for normal Copilot AI-credit budgets; scripts default to `ai_credits`. v2 has no SKU/budget-type surface at all.
- Do not add `budget.type`; scripts derive it.
- v1 config files may set an optional top-level `version: 1` (defaults to `1`); v2 files must set `version: 2`. Do not introduce a new version without adding a matching `schemas/v<N>/` directory.
- `schemas/v1/*.schema.json` is the frozen v1 contract. Do not edit it to change the contract; add a new `schemas/v<N>/` and route to it instead.
- `schemas/v2/copilot-finops.schema.json` is the v2 contract (JSON Schema draft 2020-12). Unlike v1 (shape-only), it also encodes the structural cross-field rules (per-`scope` required/forbidden fields, `enterprise`/`organization` mutual exclusivity, `credit_scope` -> `stop_at_limit`) and the budget-policy baseline cardinality (rule 10, via `contains` + `minContains`/`maxContains`); runtime/live rules and value defaulting stay in the scripts.
- Every schema change must be covered by the schema tests in `tests/`. `tests/run-schema-tests.sh` must stay green. See `## Schema Tests`.

## Schema Tests

The schemas have contract tests under `tests/`, organized as version-scoped case manifests (one file per schema per version, not one file per case):

- `tests/cases/v<N>/<schema>.yml` holds all cases for that schema at that version (e.g. `tests/cases/v1/budget-policies.yml`). Cases under `v1/` run against `schemas/v1/`, a future `v2/` against `schemas/v2/`.
- `tests/run-schema-tests.sh` meta-validates each `schemas/**/*.schema.json`, then validates every case's `config` against the matching schema.
- Each case has `name`, `valid` (`true` must pass, `false` must be rejected), optional `expect_error` (a substring that must appear in the validator output so a case cannot fail for the wrong reason), and `config` (the document to validate).

Whenever you add or change a config field, field constraint, enum, default, policy type, the `version` field, or a `schemas/v<N>/` schema, extend these tests in the same change:

1. Update the matching schema under `schemas/v<N>/`.
2. Append a valid case for the new shape to `tests/cases/v<N>/<schema>.yml`.
3. Append an invalid case (with `expect_error`) to the same file.
4. Run `tests/run-schema-tests.sh` and keep it passing.

When you add a new schema version, create `tests/cases/v<N>/` with a manifest per schema; the runner discovers it automatically.

Keep the schema/script boundary intact: the v2 schema enforces structure, the structural cross-field rules, and the rule-10 cardinality, but NOT the runtime/live rules (enterprise slug resolution, live cost center/team lookups) or value defaulting — those stay in `scripts/validate-config.sh` and the apply/sync scripts. The `schema-allows-runtime-only-rule` case guards that boundary (a config only a runtime rule rejects must still pass the schema).

## Workflow Rules

- Keep workflow YAML thin. Put reusable shell logic under `scripts/`.
- Do not change script flags lightly; workflows should adapt to scripts, not the other way around, unless the user asks for a script interface change.
- The per-type workflows (`apply-user-budgets.yml`, `sync-cost-center-members.yml`, `audit-copilot-budget-state.yml`) accept a unified `config_file` input (the v2 merged file). Precedence: `config_file` > the legacy per-type `*_config_file` input > the workflow default. Since Phase 3 the defaults point at `config/copilot-finops.yml`; the legacy `*_config_file` inputs still accept v1 split files (deprecated) and the resolve scripts emit a deprecation notice when a v1 file is resolved. The resolve scripts emit a `*_CONFIG_TYPE` (`all` for v2, `budgets`/`teams` for v1) that the validate step uses. The per-type workflows are file-based only (no issue-number input).
- `apply-copilot-finops.yml` is the unified v2 workflow: a `resolve` job resolves + validates the merged config once (via `scripts/resolve-copilot-finops-config.sh`), then `apply-budgets` and `sync-members` run in parallel against the resolved file (passed as a short-retention artifact). It requires `version: 2` (rejects v1) and is additive — the per-type workflows remain for v1. It is file-based (enterprise slug comes from the config); its only inputs are `config_file`, a testing-only `issue_number` (schedules never set it; the issue must carry the `copilot-finops-config` label), and `dry_run`. Each job writes its own detailed summary using the existing `apply-summary.jq` / `sync-summary.jq` renderers.
- `apply-user-budgets.yml` uses `budget_policies_config_file` (file-based only).
- `sync-cost-center-members.yml` uses `cost_center_members_config_file` (file-based only).
- `audit-copilot-budget-state.yml` is file-based only.
- Issue-based config is unified-only: there is one issue form (`Copilot FinOps config request`) with the single label `copilot-finops-config`, consumed only by `apply-copilot-finops.yml` via the testing-only `issue_number` input. The resolver requires that label and extracts the `Copilot FinOps config YAML` field (a complete v2 document; either list may be omitted).

## Validation

Run focused validation after changes:

```bash
bash -n scripts/*.sh
yq eval '.' .github/workflows/*.yml >/dev/null
yq eval '.' .github/ISSUE_TEMPLATE/*.yml >/dev/null
jq -e . schemas/v*/*.schema.json >/dev/null
tests/run-schema-tests.sh
scripts/validate-config.sh config/budget-policies.yml budgets
scripts/validate-config.sh config/cost-center-members.yml teams
scripts/validate-config.sh config/copilot-finops.example.yml all
[[ -f config/copilot-finops.yml ]] && scripts/validate-config.sh config/copilot-finops.yml all
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

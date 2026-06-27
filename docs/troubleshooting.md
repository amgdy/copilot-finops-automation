# Troubleshooting

## Config validation fails

Run the validator directly so the error points at the config file before any API call happens:

```bash
# v2 merged file
scripts/validate-config.sh config/copilot-finops.yml all
# v1 split files
scripts/validate-config.sh config/cost-center-members.yml teams
scripts/validate-config.sh config/budget-policies.yml budgets
```

Common causes (v2 vocab; v1 equivalents in parentheses):

- The file is missing `version: 2` (v2), or a v1 split file is blank / missing its top-level list.
- A `team` policy is missing its `teams` (v1 `source.team_slug`) or its `credit_scope` (v1 `coverage`); a `scope: organization` policy is missing `organization` or `credit_scope`.
- `enterprise` and `organization` are set on the same entry (they are mutually exclusive).
- `ai_credit_spend_policies` is non-empty but is missing its single required `all_users` policy, or defines more than one `all_users`, or more than one `enterprise` policy (enterprise is optional but capped at one).
- `amount` (v1 `budget.amount`) is missing or is not a whole number.
- A hard-stop-only budget is set to alert-only — `stop_at_limit: false` (v1 `prevent_further_usage: false`) on `all_users` (v1 `universal`) or per-member `pool_then_metered` (v1 `total_spend`) budgets.
- A field is set that the chosen `scope` forbids (e.g. `cost_center` on a `pool_then_metered` team budget).

## Schema validation fails

The validator checks each config against the JSON Schema under `schemas/v<N>/` before the semantic
checks. Schema errors look like `Additional properties are not allowed ('...' was unexpected)` or
`'...' is not one of [...]`.

- A field name is misspelled, or a field is nested at the wrong level (the schema rejects unknown keys).
- A value has the wrong type or is outside its range (e.g. `amount` below 0; in a v1 file, `sync.batch_size` outside 1-50).
- `version` points at a version with no `schemas/v<N>/` directory. Supported versions are listed in the error; use `version: 1` (or omit it) for v1, or `version: 2` for the merged file.
- v2 only: the schema also rejects structural cross-field violations — `False schema does not allow ...` for a field that is not allowed for the chosen `scope`, or `should not be valid under ...` when `enterprise` and `organization` are both set.
- The error mentions `check-jsonschema not found`: install it with `pipx install check-jsonschema` to run the schema layer locally (the workflows install it automatically).

## You are not using cost-center sync

Keep the config present with an empty list:

```yaml
version: 2
enterprise_slug: your-enterprise
team_cost_center_mappings: []
```

The sync workflow will validate the file, print that no mappings were found, and exit without changes.

## API returns 404

For these scripts, a 404 usually means one of these things:

- The enhanced billing API is not available for the enterprise.
- The token does not have enterprise billing or enterprise team read access.
- The enterprise slug, team slug, cost center name, or resolved cost center ID is wrong.
- A cost center exists but is archived/deleted; the scripts intentionally skip deleted cost centers.

Check `docs/permissions.md`, then rerun in `dry_run=true` where possible.

## Sync skipped: every mapping is skipped by default

If a sync run logs `NOTE: Skipping user-level membership sync for mapping '...'` for each mapping and makes no changes, this is the **new default**. Enterprise teams can now be assigned to cost centers natively ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/), [docs](https://docs.github.com/en/enterprise-cloud@latest/billing/tutorials/control-costs-at-scale)), so the sync defers to native assignment instead of writing individual user resources. Either:

- Assign the team to the cost center natively in **Enterprise → Settings → Billing → Cost centers** (recommended), or
- Set `force_user_sync: true` on the mapping (or run the workflow with the `force_user_sync` input / pass `--force-user-sync true`) to run the legacy user-level sync as a bridge.

The audit workflow flags a mapping that is neither assigned natively nor forced as **membership unmanaged**, so check the audit summary if you expected member changes. If your live sync uses the global `force_user_sync` workflow input (for example with frozen v1 config), run audit with `force_user_sync` too so the report reflects that global opt-in.

## Sync skipped: team is assigned natively

If a forced sync run logs `NOTE: Cost center '...' already has enterprise team '...' assigned natively` and skips a mapping, this is expected. The cost center already has that enterprise team assigned as a native resource ([changelog](https://github.blog/changelog/2026-06-25-assign-enterprise-teams-to-cost-centers/)), so GitHub keeps its membership current automatically and the user-level sync would only re-add the same members as redundant direct resources. Either:

- Remove the `team_cost_center_mappings` entry (or set `force_user_sync: false`) and rely on the native assignment (recommended), or
- Remove the native team assignment from the cost center if you specifically want script-managed user resources.

A `WARN` about a *different* natively-assigned team means the cost center mixes native team assignment with user-level sync; pick one approach per cost center.

## Team member counts are zero

- Use bare team slugs, for example `teams: [ai-leads]` (budgets) or `team: ai-leads` (mappings).
- Org teams need `organization:` set; enterprise teams omit it (the enterprise is inferred).
- Enterprise team reads need `read:enterprise` or equivalent enterprise teams read permission.
- Org team reads usually need `read:org`.

## Budgets are not deleted

This is expected. The apply script creates missing budgets and updates changed budgets, but it never deletes budgets that were removed from config. Delete old budgets manually after review.

## Issue-based config test fails

- Make sure the issue was created with the `Copilot FinOps config request` issue form and is run through the `Apply Copilot FinOps` workflow's `issue_number` input.
- Make sure the issue is open and has the `copilot-finops-config` label.
- Make sure the `Copilot FinOps config YAML` field contains a complete fenced YAML config.
- The pasted YAML must be a complete v2 document: `version: 2`, plus `enterprise_slug` unless you pass it another way. Populate `ai_credit_spend_policies` and/or `team_cost_center_mappings` (a list you omit is a no-op for that half of the run).
- Reviewed file-based config is the recommended production path, even though the workflow can use issue-based config as a source.
- Do not assign these issues to Copilot or other coding agents. They are workflow input records, not implementation tasks.

## Cost center budget does not affect expected users

Cost center budgets only apply to users who are members of that cost center. For `team` policies that cap metered usage only (`credit_scope: metered_only` in v2, `coverage: additional_spend` in v1), the apply script adds current team members to the cost center. Ongoing removals are handled by `sync-cost-center-members.yml` when you configure a mapping with `remove_extra_members: true`.

## Local scripts fail on macOS

The GitHub-hosted `ubuntu-24.04` runner already includes Bash 5.2, GitHub CLI, `jq`, and `yq`. If local scripts fail on macOS, install current local versions:

```bash
brew install gh jq yq bash
export PATH="/opt/homebrew/bin:$PATH"
```

Then rerun validation from the repository root.

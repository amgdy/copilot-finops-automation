# Troubleshooting

## Config validation fails

Run the validator directly so the error points at the config file before any API call happens:

```bash
scripts/validate-config.sh config/cost-center-members.yml teams
scripts/validate-config.sh config/budget-policies.yml budgets
```

Common causes:

- The file is blank or missing the top-level `mappings` / `budget_policies` key.
- A `team` source is missing `source.team_slug`.
- A team source has neither `source.org` nor `source.enterprise`.
- `budget.amount` is missing or is not a whole number.
- `budget.prevent_further_usage: false` is set on `universal` or `team` with `coverage: total_spend`.

## You are not using cost-center sync

Keep the teams config file present and empty:

```yaml
enterprise_slug: your-enterprise
mappings: []
```

The sync workflow will validate the file, print that no mappings were found, and exit without changes.

## API returns 404

For these scripts, a 404 usually means one of these things:

- The enhanced billing API is not available for the enterprise.
- The token does not have enterprise billing or enterprise team read access.
- The enterprise slug, team slug, cost center name, or resolved cost center ID is wrong.
- A cost center exists but is archived/deleted; the scripts intentionally skip deleted cost centers.

Check `docs/permissions.md`, then rerun in `dry_run=true` where possible.

## Team member counts are zero

- Enterprise teams use the bare team slug, for example `team_slug: ai-leads`.
- Org teams need `source.org`; enterprise teams need `source.enterprise`.
- Enterprise team reads need `read:enterprise` or equivalent enterprise teams read permission.
- Org team reads usually need `read:org`.

## Budgets are not deleted

This is expected. The apply script creates missing budgets and updates changed budgets, but it never deletes budgets that were removed from config. Delete old budgets manually after review.

## Issue-based config test fails

- Make sure the issue was created with the `Budget policy config request` issue form.
- For cost center member sync, use the `Cost center members config request` issue form.
- Make sure the issue is open and has the expected label: `budget-policy-config` or `cost-center-members-config`.
- Make sure the YAML field contains a complete fenced YAML config.
- The extracted YAML must include `enterprise_slug` and `budget_policies` unless you pass `enterprise_slug` as a workflow input.
- For cost center member sync, the extracted YAML must include `enterprise_slug` and `mappings` unless you pass `enterprise_slug` as a workflow input.
- Reviewed file-based config is the recommended production path, even though workflows can use issue-based config as a source.
- Do not assign these issues to Copilot or other coding agents. They are workflow input records, not implementation tasks.

## Cost center budget does not affect expected users

Cost center budgets only apply to users who are members of that cost center. For `team` policies with `coverage: additional_spend`, the apply script adds current team members to the cost center. Ongoing removals are handled by `sync-cost-center-members.yml` when you configure a mapping with `remove_extra_members: true`.

## Local scripts fail on macOS

The GitHub-hosted `ubuntu-24.04` runner already includes Bash 5.2, GitHub CLI, `jq`, and `yq`. If local scripts fail on macOS, install current local versions:

```bash
brew install gh jq yq bash
export PATH="/opt/homebrew/bin:$PATH"
```

Then rerun validation from the repository root.

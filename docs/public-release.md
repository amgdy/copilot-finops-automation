# Public Release Checklist

Use this checklist before publishing this repository, a fork, or a template copy.

## Remove private data

- Search tracked files for real enterprise slugs, organization names, team slugs, cost center names, user logins, alert recipients, and budget amounts.
- Replace live `config/budget-policies.yml` and `config/cost-center-members.yml` values with public-safe placeholders or empty lists.
- Remove generated audit reports, run logs, JSONL summary files, screenshots, and copied workflow output.
- Verify no token, API response, or authorization header was pasted into docs, examples, issues, or commit messages.

## Publish safe defaults

Keep default config files valid but harmless:

```yaml
enterprise_slug: your-enterprise
mappings: []
```

```yaml
enterprise_slug: your-enterprise
budget_policies: []
```

This lets scheduled workflows and validation steps fail less noisily while adopters are still configuring their private fork.

## Protect live deployments

- Use a private repository for live enterprise configuration whenever possible.
- Store `COPILOT_FINOPS_TOKEN` as a repository or organization secret, never in a file.
- Require reviews for `.github/workflows/**`, `config/**`, and scripts.
- Keep manual mutating workflows in `dry_run=true` until the audit and preview summaries are reviewed.
- Disable scheduled workflows in public demo repositories that are not connected to a real enterprise.

## Final checks

Run these before publishing:

```bash
scripts/validate-config.sh config/cost-center-members.yml teams
scripts/validate-config.sh config/budget-policies.yml budgets
git diff --check
```

If `shellcheck`, `actionlint`, and `yq` are available, also run:

```bash
shellcheck scripts/*.sh
actionlint .github/workflows/*.yml
yq eval '.' .github/workflows/*.yml >/dev/null
```

## Copilot Customizations

- Review `AGENTS.md` and `.github/skills/copilot-finops-config/` before publishing.
- Keep the skill public-safe: no private enterprise slugs, team names, cost center names, users, budgets, reports, or tokens.
- If config requirements changed, make sure the skill references and docs were updated in the same change.
